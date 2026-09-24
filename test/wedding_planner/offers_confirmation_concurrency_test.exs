defmodule WeddingPlanner.OffersConfirmationConcurrencyTest do
  @moduledoc """
  `DR-62`'s and `DR-66`'s concurrency guarantees for `WeddingPlanner.Offers.confirm_offer/2`
  and `set_planning_pick/2`, proven against real, independent database connections rather
  than the SQL sandbox's single serialized connection (which would make "one winner"
  trivially true). Same setup as `WeddingPlanner.InvitationsConcurrencyTest`: outside
  `DataCase`, sandbox mode flipped to `:auto`, two racers.

  Both functions re-read the offer inside their `WeddingPlanner.Log.action/3`, whose first
  statement is the summary insert — a write, so SQLite's one write lock is taken before
  anything is read:

    * two concurrent confirms of one offer: the second caller reads *confirmed* and returns
      `{:error, :already_confirmed}`; exactly one set of frozen rows and one summary exist;
    * two concurrent planning picks on different offers of one category: the second caller
      reads the first one's pick and **moves** it (both `{:ok, _}`, last writer wins), so
      the partial unique index `offers_one_planning_pick_per_category` is never violated
      and nothing raises to either caller. The index stays the backstop.

  **Warm-up.** `setup` runs the same code paths once, un-raced, in another category. The
  test VM loads modules lazily: without the warm-up, the racer holding the write lock can
  stop to load a module through the code server while the other racer sits in a dirty
  exqlite NIF busy-waiting for that lock, and the two only come apart when `busy_timeout`
  expires ("database is locked" / "Database busy", measured ~3 runs in 4 when this module's
  second test hit a not-yet-loaded path; 0 in 24 with the warm-up). That is a property of
  lazy code loading plus SQLite's busy wait, not of the confirmation logic under test.

  Fail-proof: removing the status re-read from `confirm_offer/2` makes the second racer
  insert a duplicate frozen row — the unique pair refuses it and the racer crashes, so the
  first test fails.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  # Excluded from the main run (test_helper.exs); `mix precommit` runs these alone.
  @moduletag :real_connection_race

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Offers.FrozenService
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Repo

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Repo.delete_all(Entry)
      Repo.delete_all(FrozenService)
      Repo.delete_all(Offer)
      Repo.delete_all(Service)
      Repo.delete_all(Category)
      Repo.delete_all(User)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    {:ok, user} = %User{} |> User.changeset(%{display_name: "Wannes"}) |> Repo.insert()
    scope = Scope.for_user(user)

    warm_up!(scope)

    category = category_with_services!(scope, "Venue")
    {:ok, venue_a} = Offers.create_offer(scope, category, %{"vendor_name" => "Venue A"})
    {:ok, venue_b} = Offers.create_offer(scope, category, %{"vendor_name" => "Venue B"})

    %{scope: scope, category: category, venue_a: venue_a, venue_b: venue_b}
  end

  defp category_with_services!(scope, name) do
    {:ok, category} = Categories.create_category(scope, %{"name" => name})

    for service_name <- ["Seating", "Sound"] do
      {:ok, _} =
        Categories.create_service(scope, category, %{
          "name" => service_name,
          "wanted_priority" => "nice_to_have"
        })
    end

    category
  end

  # See the moduledoc: every code path the racers take, once, before they race.
  defp warm_up!(scope) do
    category = category_with_services!(scope, "Warm-up")
    {:ok, first} = Offers.create_offer(scope, category, %{"vendor_name" => "Warm-up 1"})
    {:ok, second} = Offers.create_offer(scope, category, %{"vendor_name" => "Warm-up 2"})
    {:ok, _} = Offers.set_planning_pick(scope, first)
    {:ok, _} = Offers.set_planning_pick(scope, second)
    {:ok, _} = Offers.confirm_offer(scope, first)
    {:error, :already_confirmed} = Offers.confirm_offer(scope, first)
    :ok
  end

  defp race(funs) do
    parent = self()

    tasks =
      for fun <- funs do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> fun.()
          end
        end)
      end

    for %Task{pid: pid} <- tasks, do: assert_receive({:ready, ^pid})
    for %Task{pid: pid} <- tasks, do: send(pid, :go)
    Task.await_many(tasks, 10_000)
  end

  test "two racers confirming the same offer: exactly one wins, one set of frozen rows", %{
    scope: scope,
    venue_a: venue_a
  } do
    results = race(for _ <- 1..2, do: fn -> Offers.confirm_offer(scope, venue_a) end)

    assert Enum.count(results, &match?({:ok, %Offer{status: :confirmed}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :already_confirmed})) == 1
    assert Repo.aggregate(from(f in FrozenService, where: f.offer_id == ^venue_a.id), :count) == 2

    assert Repo.aggregate(
             from(e in Entry, where: e.description == "Wannes confirmed offer 'Venue A'"),
             :count
           ) == 1
  end

  test "two racers picking different offers of one category: both succeed, one pick survives", %{
    scope: scope,
    category: category,
    venue_a: venue_a,
    venue_b: venue_b
  } do
    results =
      race([
        fn -> Offers.set_planning_pick(scope, venue_a) end,
        fn -> Offers.set_planning_pick(scope, venue_b) end
      ])

    assert Enum.all?(results, &match?({:ok, %Offer{planning_pick: true}}, &1))

    picks =
      Repo.all(
        from(o in Offer, where: o.category_id == ^category.id and o.planning_pick, select: o.id)
      )

    assert [pick] = picks
    assert pick in [venue_a.id, venue_b.id]
  end
end
