defmodule WeddingPlannerWeb.ActivityComponentsTest do
  @moduledoc """
  `WeddingPlannerWeb.ActivityComponents.entity_history/1` — the reusable per-entity
  activity history (task 20). Exercised through the exact "host LiveView pattern" the
  component's own moduledoc documents, via `Phoenix.LiveViewTest.live_isolated/3` (no
  router entry needed for a component test), so a passing test here proves the
  documented pattern actually works end to end, not just that the component renders
  given a hand-built assign.
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log
  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.Repo

  alias WeddingPlannerWeb.ActivityHistoryHostLiveTestSupport, as: HostLive

  setup do
    wannes = insert_user!("Wannes")
    %{wannes: wannes, scope: Scope.for_user(wannes)}
  end

  test "renders only the given entity's entries, including bulk children (XC-12)", %{
    scope: scope
  } do
    {:ok, standalone} = Log.entry(scope, {:person, 1}, "Standalone entry for person 1")

    {:ok, :done} =
      Log.action(scope, "Bulk action", fn ->
        {:ok, _} = Log.entry(scope, {:person, 1}, "Bulk child for person 1")
        {:ok, _} = Log.entry(scope, {:person, 2}, "Bulk child for person 2")
        :done
      end)

    [child_for_1] =
      Query.for_entity(:person, 1) |> Enum.reject(&(&1.id == standalone.id))

    {:ok, view, _html} = live_isolated(build_conn(), HostLive, session: %{"id" => 1})

    assert has_element?(view, "#person-history-entry-#{standalone.id}", "Standalone entry")

    assert has_element?(
             view,
             "#person-history-entry-#{child_for_1.id}",
             "Bulk child for person 1"
           )

    refute has_element?(view, "#person-history", "Bulk child for person 2")
  end

  test "shows the empty state when the entity has no history yet", %{scope: scope} do
    # Some other entity's entry exists, but person 7 has none.
    {:ok, _} = Log.entry(scope, {:person, 1}, "Not person 7's entry")

    {:ok, view, _html} = live_isolated(build_conn(), HostLive, session: %{"id" => 7})

    assert has_element?(view, "#person-history-empty")
  end

  test "a live-broadcast entry for this entity is prepended without a refresh (XC-01)", %{
    scope: scope
  } do
    {:ok, view, _html} = live_isolated(build_conn(), HostLive, session: %{"id" => 3})

    {:ok, entry} = Log.entry(scope, {:person, 3}, "Live entry for person 3")
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#person-history-entry-#{entry.id}", "Live entry for person 3")
  end

  test "a live-broadcast entry for a different entity is ignored", %{scope: scope} do
    {:ok, view, _html} = live_isolated(build_conn(), HostLive, session: %{"id" => 3})

    {:ok, entry} = Log.entry(scope, {:person, 4}, "Not person 3's entry")
    _ = :sys.get_state(view.pid)

    refute has_element?(view, "#person-history-entry-#{entry.id}")
    assert has_element?(view, "#person-history-empty")
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
