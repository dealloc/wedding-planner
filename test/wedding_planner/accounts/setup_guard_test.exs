defmodule WeddingPlanner.Accounts.SetupGuardTest do
  @moduledoc """
  `DR-22`: the guard that deletes a bootstrap setup's provisional user if its owning
  LiveView goes away before the ceremony completes. Unit-tested here against a plain
  spawned "owner" process standing in for the LiveView — the guard only needs a pid to
  monitor, watched via `Process.monitor/1`, not a LiveView specifically. The
  LiveView-process-killed scenario itself is covered end to end by
  `WeddingPlannerWeb.Live.SetupLiveTest`.

  `async: false` (via `DataCase`) puts the sandboxed connection in shared mode, so the
  separately-spawned owner and guard processes can use `Repo` without an explicit
  `Ecto.Adapters.SQL.Sandbox.allow/3` for each one.
  """
  use WeddingPlanner.DataCase, async: false

  import ExUnit.CaptureLog

  alias WeddingPlanner.Accounts.SetupGuard
  alias WeddingPlanner.Accounts.User

  setup do
    {:ok, user} = %User{} |> User.changeset(%{display_name: "Provisional"}) |> Repo.insert()
    %{user: user}
  end

  test "deletes the user once its owner exits without disarming", %{user: user} do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, guard} = SetupGuard.start(owner: owner, user_id: user.id)

    ref = Process.monitor(guard)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^ref, :process, ^guard, :normal}
    refute Repo.get(User, user.id)
  end

  test "does not delete the user once disarmed", %{user: user} do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, guard} = SetupGuard.start(owner: owner, user_id: user.id)

    assert :ok = SetupGuard.disarm(guard)
    assert Repo.get(User, user.id)

    # The (now-irrelevant) owner exiting afterwards changes nothing further.
    send(owner, :stop)
    assert Repo.get(User, user.id)
  end

  test "disarm/1 is safe to call again once the guard has already stopped", %{user: user} do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, guard} = SetupGuard.start(owner: owner, user_id: user.id)

    assert :ok = SetupGuard.disarm(guard)
    assert :ok = SetupGuard.disarm(guard)
    assert Repo.get(User, user.id)

    send(owner, :stop)
  end

  test "swallows a failure deleting an already-gone user instead of crashing", %{user: user} do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, guard} = SetupGuard.start(owner: owner, user_id: user.id)

    Repo.delete!(user)

    ref = Process.monitor(guard)

    log =
      capture_log(fn ->
        Process.exit(owner, :kill)
        assert_receive {:DOWN, ^ref, :process, ^guard, :normal}
      end)

    assert log =~ "could not delete provisional user"
  end

  test "a normal (non-abnormal) owner exit still triggers the delete", %{user: user} do
    owner = spawn(fn -> :ok end)
    Process.monitor(owner)
    assert_receive {:DOWN, _ref, :process, ^owner, :normal}

    {:ok, guard} = SetupGuard.start(owner: owner, user_id: user.id)

    # The owner is already dead by the time the guard starts monitoring it —
    # `Process.monitor/1` still delivers a `:DOWN` immediately in that case.
    ref = Process.monitor(guard)
    assert_receive {:DOWN, ^ref, :process, ^guard, :normal}
    refute Repo.get(User, user.id)
  end
end
