defmodule WeddingPlanner.Accounts.SetupConcurrencyTest do
  @moduledoc """
  `DR-22`'s race guard (`WeddingPlanner.Accounts.Setup.create_first_user/1`), proven
  against real, independent database connections rather than the SQL sandbox's single
  serialized connection — the sandbox would make "only one winner" trivially true no
  matter whether `create_first_user/1` is actually atomic, since every query funnels
  through one connection regardless.

  Runs in ExUnit's *sync* phase (`async: false`, and deliberately not using `DataCase`,
  which would check out its own sandboxed connection): `ExUnit.Runner.async_loop/4`
  drains the entire async batch and waits for it to finish before a single sync module
  is started, so flipping the repo's sandbox mode to `:auto` here — required so the
  racing tasks below get real, independent pool connections instead of one shared
  sandboxed one — cannot race any other test in the suite.

  Known residual flake: two real racers can very rarely exceed SQLite's `busy_timeout`
  under scheduler jitter; `exqlite` turns a failed `BEGIN IMMEDIATE` into a disconnect, so
  the loser's `Repo.transaction` raises and the test fails outright — a false failure, not
  an atomicity bug. Measured at ~1 full-suite run in 35 (2026-09-23); revisit if it grows.
  """
  use ExUnit.Case, async: false

  # Excluded from the main run (test_helper.exs); `mix precommit` runs these alone.
  @moduletag :real_connection_race

  alias WeddingPlanner.Accounts.Setup
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Repo

  @valid_token String.duplicate("a", 32)

  setup do
    previous_token = Application.get_env(:wedding_planner, :setup_token)
    Application.put_env(:wedding_planner, :setup_token, @valid_token)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Repo.delete_all(User)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

      case previous_token do
        nil -> Application.delete_env(:wedding_planner, :setup_token)
        value -> Application.put_env(:wedding_planner, :setup_token, value)
      end
    end)

    :ok
  end

  test "a second concurrent attempt cannot create a second user" do
    # DR-22's own race is exactly two tabs, so two racers is both the truest reproduction
    # of the scenario and — empirically — the largest count that reliably stays inside
    # `busy_timeout`: the busy loser here blocks at `BEGIN IMMEDIATE` for as long as the
    # winner's whole transaction takes, not just the query it's racing to run, and piling
    # on more real, simultaneously-competing writers than that (this test used to race 8)
    # measurably raises the odds that a loser's wait crosses `busy_timeout` under nothing
    # more than ordinary scheduler jitter — a false failure, not evidence of a real race
    # lost. The `:ready`/`:go` handshake below still forces genuine overlap between them.
    racers = 2
    parent = self()

    tasks =
      for i <- 1..racers do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> Setup.create_first_user(%{"display_name" => "Racer #{i}"})
          end
        end)
      end

    # Line every racer up before releasing them together, to maximize the chance any two
    # of them genuinely overlap rather than happening to run one after another.
    for %Task{pid: pid} <- tasks, do: assert_receive({:ready, ^pid})
    for %Task{pid: pid} <- tasks, do: send(pid, :go)

    results = Task.await_many(tasks, 10_000)

    assert Enum.count(results, &match?({:ok, %User{}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :already_exists}, &1)) == racers - 1
    assert Repo.aggregate(User, :count) == 1
  end
end
