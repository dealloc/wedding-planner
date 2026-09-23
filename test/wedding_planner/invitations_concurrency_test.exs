defmodule WeddingPlanner.InvitationsConcurrencyTest do
  @moduledoc """
  `DR-37`'s concurrency guarantee for a single invitation/opt-out cell, proven against
  real, independent database connections rather than the SQL sandbox's single
  serialized connection — the sandbox would make "only one winner" (or "both win, one
  row") trivially true no matter whether the writes are actually race-safe, since every
  query would funnel through one connection regardless. Mirrors
  `WeddingPlanner.Accounts.EnrollmentLinksConcurrencyTest`'s approach to the same class
  of race; see that module's moduledoc for why this runs outside `DataCase` with the
  sandbox mode flipped to `:auto`.

  Two racers, not more — see `WeddingPlanner.Accounts.EnrollmentLinksConcurrencyTest`'s
  own comment on racer count: this app has exactly two users, and more simultaneous real
  writers measurably raises the odds of a false failure from ordinary scheduler jitter
  crossing SQLite's `busy_timeout`, not evidence of a real race lost.

  Fail-proof: removing the `on_conflict: {:replace, ...}` upsert from
  `WeddingPlanner.Invitations`'s status write (falling back to a plain `Repo.insert/2`)
  makes "both racers set a brand-new cell" fail with a unique-constraint exception
  instead of `{:ok, _}` twice.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  # Excluded from the main run (test_helper.exs); `mix precommit` runs these alone.
  @moduletag :real_connection_race

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Invitations.PlusOneOptOut
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Repo

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    {:ok, user} = %User{} |> User.changeset(%{display_name: "Wannes"}) |> Repo.insert()

    {:ok, event} =
      %Event{name: "Dinner", sort_order: 0} |> Ecto.Changeset.change() |> Repo.insert()

    {:ok, host} =
      %Person{}
      |> Person.changeset(%{first_name: "Anna", last_name: "Peeters"})
      |> Repo.insert()

    {:ok, plus_one} =
      %Person{host_id: host.id, want_tier: host.want_tier, certainty: host.certainty}
      |> Person.plus_one_changeset(%{plus_one_status: :possible})
      |> Repo.insert()

    on_exit(fn ->
      Repo.delete_all(Entry)
      Repo.delete_all(PlusOneOptOut)
      Repo.delete_all(Invitation)
      # `persons.host_id` is a self-FK — the +1 row must go before the host row it
      # references, so a bare `Repo.delete_all(Person)` (order unspecified) can't be
      # trusted here.
      Repo.delete_all(from p in Person, where: not is_nil(p.host_id))
      Repo.delete_all(from p in Person, where: is_nil(p.host_id))
      Repo.delete_all(Event)
      Repo.delete_all(User)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    %{scope: Scope.for_user(user), host: host, plus_one: plus_one, event: event}
  end

  test "two racers setting the same brand-new invitation cell both succeed, one row survives",
       %{scope: scope, host: host, event: event} do
    racers = 2
    parent = self()

    tasks =
      for _ <- 1..racers do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> Invitations.set_invitation_status(scope, host, event, :accepted)
          end
        end)
      end

    for %Task{pid: pid} <- tasks, do: assert_receive({:ready, ^pid})
    for %Task{pid: pid} <- tasks, do: send(pid, :go)

    results = Task.await_many(tasks, 10_000)

    assert Enum.all?(results, &match?({:ok, %Invitation{status: :accepted}}, &1))
    assert Repo.aggregate(Invitation, :count) == 1

    assert %Invitation{status: :accepted} =
             Repo.get_by!(Invitation, person_id: host.id, event_id: event.id)
  end

  test "two racers opting the same +1 out of the same event both succeed, one row survives", %{
    scope: scope,
    plus_one: plus_one,
    event: event
  } do
    racers = 2
    parent = self()

    tasks =
      for _ <- 1..racers do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> Invitations.set_opt_out(scope, plus_one, event, true)
          end
        end)
      end

    for %Task{pid: pid} <- tasks, do: assert_receive({:ready, ^pid})
    for %Task{pid: pid} <- tasks, do: send(pid, :go)

    results = Task.await_many(tasks, 10_000)

    assert Enum.all?(results, &match?({:ok, %PlusOneOptOut{}}, &1))
    assert Repo.aggregate(PlusOneOptOut, :count) == 1

    assert %PlusOneOptOut{} =
             Repo.get_by!(PlusOneOptOut, person_id: plus_one.id, event_id: event.id)
  end
end
