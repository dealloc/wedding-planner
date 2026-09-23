defmodule WeddingPlanner.Accounts.PasskeysConcurrencyTest do
  @moduledoc """
  `AUTH-08`'s last-passkey guard (`WeddingPlanner.Accounts.Passkeys.revoke/2`), proven
  against real, independent database connections rather than the SQL sandbox's single
  serialized connection — the sandbox would make "at most one winner" trivially true no
  matter whether `revoke/2` is actually atomic, since every query would funnel through
  one connection regardless. Mirrors
  `WeddingPlanner.Accounts.EnrollmentLinksConcurrencyTest`'s approach to the same class
  of race (`AUTH-06`'s single-use guarantee); see that module's moduledoc for why this
  runs outside `DataCase` with the sandbox mode flipped to `:auto`.

  The scenario this proves: a user has exactly two passkeys, opens two tabs, and racing
  from each tries to revoke the *other* of the two at the same moment ("two tabs
  revoking each other's last-two passkeys concurrently must not leave zero"). Exactly
  one `revoke/2` must succeed; the other must be refused with `{:error, :last_passkey}`;
  and the user must be left with exactly one passkey, never zero.

  Known residual flake: two real racers can very rarely exceed SQLite's `busy_timeout`
  under scheduler jitter; `exqlite` turns a failed `BEGIN IMMEDIATE` into a disconnect, so
  the loser's `Repo.transaction` raises and the test fails outright — a false failure, not
  an atomicity bug. Measured at ~1 full-suite run in 35 (2026-09-23); revisit if it grows.
  """
  use ExUnit.Case, async: false

  # Excluded from the main run (test_helper.exs); `mix precommit` runs these alone.
  @moduletag :real_connection_race

  import Ecto.Query, only: [from: 2]

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.Passkeys
  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Repo

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    {:ok, user} = %User{} |> User.changeset(%{display_name: "Wannes"}) |> Repo.insert()
    passkey_a = insert_passkey!(user, "Phone A")
    passkey_b = insert_passkey!(user, "Phone B")

    on_exit(fn ->
      Repo.delete_all(Entry)
      Repo.delete_all(Passkey)
      Repo.delete_all(User)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    %{user: user, scope: Scope.for_user(user), passkey_a: passkey_a, passkey_b: passkey_b}
  end

  test "exactly one of two concurrent revokes on the last two passkeys succeeds, never leaving zero",
       %{user: user, scope: scope, passkey_a: passkey_a, passkey_b: passkey_b} do
    parent = self()

    tasks =
      for pk <- [passkey_a, passkey_b] do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> Passkeys.revoke(scope, pk)
          end
        end)
      end

    for %Task{pid: pid} <- tasks, do: assert_receive({:ready, ^pid})
    for %Task{pid: pid} <- tasks, do: send(pid, :go)

    results = Task.await_many(tasks, 10_000)

    successes = Enum.count(results, &match?({:ok, _}, &1))
    refusals = Enum.count(results, &(&1 == {:error, :last_passkey}))

    assert successes == 1
    assert refusals == 1

    remaining = Repo.all(from(p in Passkey, where: p.user_id == ^user.id))
    assert length(remaining) == 1
  end

  defp insert_passkey!(user, name) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Passkey{user_id: user.id, sign_count: 0}
    |> Passkey.registration_changeset(%{
      credential_id: :crypto.strong_rand_bytes(16),
      public_key: Passkey.encode_cose_key(%{1 => 2, 3 => -7, -1 => 1, -2 => <<1, 2, 3>>}),
      name: name,
      registered_at: now
    })
    |> Repo.insert!()
  end
end
