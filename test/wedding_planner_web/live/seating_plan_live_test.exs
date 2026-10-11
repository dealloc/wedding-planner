defmodule WeddingPlannerWeb.Live.SeatingPlanLiveTest do
  @moduledoc """
  `/seating/plan` (`docs/modules/seating.md` SEAT-50..SEAT-54, SEAT-70, `XC-01`): the
  computed plan, read-only, computed asynchronously and never stored.
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Events
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Seating

  setup %{conn: conn} do
    user = %User{} |> User.changeset(%{display_name: "Wannes"}) |> Repo.insert!()
    scope = Scope.for_user(user)
    {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner", "couple_attends" => false})

    people =
      for name <- ~w(Ann Bob Cas Dirk Eva Fien) do
        {:ok, person} = Guests.create_person(scope, %{"first_name" => name})
        {:ok, _} = Invitations.set_invitation_status(scope, person, dinner, :accepted)
        person
      end

    {:ok, uni} = Seating.create_circle(scope, %{"name" => "Uni", "cohesion" => "keep_together"})
    {:ok, work} = Seating.create_circle(scope, %{"name" => "Work", "cohesion" => "keep_together"})
    [ann, bob, cas, dirk, eva, fien] = people
    for p <- [ann, bob, cas], do: {:ok, _} = Seating.add_member(scope, uni, p)
    for p <- [dirk, eva, fien], do: {:ok, _} = Seating.add_member(scope, work, p)

    %{conn: log_in_user(conn, user), scope: scope, dinner: dinner, people: people}
  end

  defp table_of(view, table_id, person) do
    has_element?(view, "#plan-table-#{table_id}-person-#{person.id}")
  end

  defp round!(scope, event, attrs) do
    {:ok, table} =
      Seating.create_table(scope, event, Map.merge(%{"kind" => "type", "name" => "Round"}, attrs))

    table
  end

  test "an unauthenticated request redirects to /login" do
    conn = get(Phoenix.ConnTest.build_conn(), ~p"/seating/plan")
    assert redirected_to(conn) == "/login?return_to=%2Fseating%2Fplan"
  end

  test "without tables the plan says why it cannot be made", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/seating/plan")
    render_async(view)

    assert has_element?(view, "#plan[data-status=blocked]")
    assert has_element?(view, "#plan-problems #problem-no-tables")
  end

  test "the plan seats each circle at its own table (S1)", %{
    conn: conn,
    scope: scope,
    dinner: dinner,
    people: people
  } do
    round = round!(scope, dinner, %{"min_seats" => "3", "max_seats" => "3"})
    {:ok, view, _html} = live(conn, ~p"/seating/plan?event=#{dinner.id}")
    render_async(view)

    assert has_element?(view, "#plan[data-status=ok]")
    assert has_element?(view, "#plan-used", "Round ×2")

    [ann, bob, cas, dirk, eva, fien] = people
    {first, second} = {"type-#{round.id}-1", "type-#{round.id}-2"}
    table = if table_of(view, first, ann), do: first, else: second
    other = if table == first, do: second, else: first

    assert Enum.all?([ann, bob, cas], &table_of(view, table, &1))
    assert Enum.all?([dirk, eva, fien], &table_of(view, other, &1))
    assert has_element?(view, "#plan-table-#{table}-seats", "3 / 3")
    assert has_element?(view, "#plan-table-#{table}-person-#{ann.id}", "Here with:")
  end

  test "a fixed table seats exactly its pins, marked, and the types seat the rest (D-44)", %{
    conn: conn,
    scope: scope,
    dinner: dinner,
    people: [ann, bob | _]
  } do
    {:ok, head} =
      Seating.create_table(scope, dinner, %{
        "kind" => "fixed",
        "name" => "Head",
        "min_seats" => "2",
        "max_seats" => "6"
      })

    _ = round!(scope, dinner, %{"min_seats" => "4", "max_seats" => "4"})
    {:ok, _} = Seating.pin(scope, head, "person:#{ann.id}")
    {:ok, _} = Seating.pin(scope, head, "person:#{bob.id}")

    {:ok, view, _html} = live(conn, ~p"/seating/plan")
    render_async(view)

    assert has_element?(view, "#plan[data-status=ok]")
    assert has_element?(view, "#plan-table-fixed-#{head.id}", "Fixed")
    assert has_element?(view, "#plan-table-fixed-#{head.id}-seats", "2 / 6")

    assert has_element?(
             view,
             "#plan-table-fixed-#{head.id}-person-#{ann.id} [title='Pinned here']"
           )

    assert has_element?(view, "#plan-used", "Head, Round ×1")
  end

  test "a fixed table alone cannot seat guests nobody pinned", %{
    conn: conn,
    scope: scope,
    dinner: dinner
  } do
    {:ok, _} =
      Seating.create_table(scope, dinner, %{
        "kind" => "fixed",
        "name" => "Head",
        "min_seats" => "2",
        "max_seats" => "6"
      })

    {:ok, view, _html} = live(conn, ~p"/seating/plan")
    render_async(view)

    assert has_element?(view, "#plan[data-status=blocked]")
    assert has_element?(view, "#problem-no-table-types")
  end

  test "a plan that cannot be valid shows the best attempt, marked (S8)", %{
    conn: conn,
    scope: scope,
    dinner: dinner
  } do
    round = round!(scope, dinner, %{"name" => "Big", "min_seats" => "8", "max_seats" => "10"})

    {:ok, view, _html} = live(conn, ~p"/seating/plan")
    render_async(view)

    assert has_element?(view, "#plan[data-status=invalid]")
    assert has_element?(view, "#problem-below-type-#{round.id}-1", "Big 1 has 6 of at least 8")
  end

  test "updates live when the inputs change (XC-01, SEAT-50)", %{
    conn: conn,
    scope: scope,
    dinner: dinner,
    people: people
  } do
    round = round!(scope, dinner, %{"min_seats" => "1", "max_seats" => "6"})
    {:ok, view, _html} = live(conn, ~p"/seating/plan")
    render_async(view)

    assert has_element?(view, "#plan-used", "Round ×1")
    [ann, bob | _] = people

    {:ok, _} =
      Seating.create_rule(scope, %{
        "subject" => "person:#{ann.id}",
        "object" => "person:#{bob.id}",
        "relation" => "never_with"
      })

    render_async(view)

    # Everyone fits at one Round, but Ann and Bob may not share it: one more (SEAT-45).
    assert has_element?(view, "#plan-used", "Round ×2")
    together? = fn t -> table_of(view, t, ann) and table_of(view, t, bob) end
    refute together?.("type-#{round.id}-1") or together?.("type-#{round.id}-2")
  end

  test "switching the event re-computes; the link back keeps the scenario", %{
    conn: conn,
    scope: scope,
    dinner: dinner
  } do
    {:ok, party} = Events.create_event(scope, %{"name" => "Party", "couple_attends" => false})
    {:ok, view, _html} = live(conn, ~p"/seating/plan")
    render_async(view)

    view |> form("#plan-scenario-form", event_id: party.id) |> render_change()
    assert_patch(view)
    render_async(view)

    assert view |> element("#to-inputs") |> render() =~ "event=#{party.id}"
    refute view |> element("#to-inputs") |> render() =~ "event=#{dinner.id}"
  end
end
