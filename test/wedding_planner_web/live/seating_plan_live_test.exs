defmodule WeddingPlannerWeb.Live.SeatingPlanLiveTest do
  @moduledoc """
  `/seating/plan` (`docs/modules/seating.md` SEAT-50..SEAT-54, SEAT-70, `XC-01`): the
  computed plan, read-only, computed asynchronously and never stored. Also the corrections made from it
  (SEAT-44, SEAT-71): rules between two people, moving, freezing.
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Events
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Log.Entry
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

  describe "corrections are inputs (SEAT-71)" do
    setup %{scope: scope, dinner: dinner} do
      round = round!(scope, dinner, %{"min_seats" => "1", "max_seats" => "6", "limit" => "2"})
      %{round: round, plan_table: "type-#{round.id}-1"}
    end

    defp fixed!(scope, event, name) do
      {:ok, table} =
        Seating.create_table(scope, event, %{
          "kind" => "fixed",
          "name" => name,
          "min_seats" => "1",
          "max_seats" => "6"
        })

      table
    end

    defp open_plan(conn, dinner) do
      {:ok, view, _html} = live(conn, ~p"/seating/plan?event=#{dinner.id}")
      render_async(view)
      view
    end

    defp party_id(table_id, person), do: "#plan-table-#{table_id}-person-#{person.id}"

    defp select(view, table_id, person) do
      view |> element("#{party_id(table_id, person)}-select") |> render_click()
    end

    test "two selected people offer a rule, pre-filled; saving clears the selection",
         %{conn: conn, dinner: dinner, plan_table: t, people: [ann, _, _, dirk | _]} do
      view = open_plan(conn, dinner)

      select(view, t, ann)
      assert has_element?(view, "#plan-selection")
      refute has_element?(view, "#plan-rule-panel")

      select(view, t, dirk)
      assert has_element?(view, "#plan-rule-panel[data-mode=create]")
      assert has_element?(view, "#plan-rule-subject[value='person:#{ann.id}']")
      assert has_element?(view, "#plan-rule-object[value='person:#{dirk.id}']")

      view |> form("#plan-rule-form", rule: %{relation: "keep_apart"}) |> render_submit()

      assert has_element?(view, "#flash-info")
      refute has_element?(view, "#plan-rule-panel")
      refute has_element?(view, "#plan-selection")

      rule = Seating.get_rule_between("person:#{ann.id}", "person:#{dirk.id}")
      assert rule.relation == :keep_apart
      assert Repo.get_by(Entry, entity_type: "seating_rule", entity_id: rule.id)
    end

    test "an existing rule between them is edited, pre-filled with its relation",
         %{conn: conn, scope: scope, dinner: dinner, plan_table: t, people: [ann, _, _, dirk | _]} do
      {:ok, rule} =
        Seating.create_rule(scope, %{
          "subject" => "person:#{ann.id}",
          "object" => "person:#{dirk.id}",
          "relation" => "keep_apart"
        })

      view = open_plan(conn, dinner)
      select(view, t, dirk)
      select(view, t, ann)

      assert has_element?(view, "#plan-rule-panel[data-mode=edit]")
      assert has_element?(view, "#plan-rule-relation option[selected][value=keep_apart]")

      view
      |> form("#plan-rule-form", rule: %{relation: "never_with", reason: "they split up"})
      |> render_submit()

      assert Seating.get_rule!(rule.id).relation == :never_with
      assert Seating.get_rule!(rule.id).reason == "they split up"
      assert length(Seating.list_rules()) == 1
    end

    test "a rule without a relation shows the error and keeps the panel",
         %{conn: conn, dinner: dinner, plan_table: t, people: [ann, bob | _]} do
      view = open_plan(conn, dinner)
      select(view, t, ann)
      select(view, t, bob)

      view |> form("#plan-rule-form", rule: %{relation: ""}) |> render_submit()
      assert has_element?(view, "#plan-rule-panel")
      assert Seating.list_rules() == []
    end

    test "selecting a selected person again deselects them",
         %{conn: conn, dinner: dinner, plan_table: t, people: [ann | _]} do
      view = open_plan(conn, dinner)
      select(view, t, ann)
      select(view, t, ann)
      refute has_element?(view, "#plan-selection")
    end

    test "without a fixed table, moving says it needs one",
         %{conn: conn, dinner: dinner, plan_table: t, people: [ann | _]} do
      view = open_plan(conn, dinner)
      assert has_element?(view, "#{party_id(t, ann)}-move-hint")
      refute has_element?(view, "#{party_id(t, ann)}-move-form")
    end

    test "moving a person pins them to a fixed table; moving again changes the pin; unpin",
         %{conn: conn, scope: scope, dinner: dinner, plan_table: t, people: [ann | _]} do
      head = fixed!(scope, dinner, "Head")
      other = fixed!(scope, dinner, "Other")
      view = open_plan(conn, dinner)

      view |> form("#{party_id(t, ann)}-move-form", table_id: head.id) |> render_change()
      render_async(view)

      assert has_element?(view, "#flash-info")
      assert has_element?(view, "#{party_id("fixed-#{head.id}", ann)} [title='Pinned here']")
      assert [%{seating_table_id: id}] = Seating.list_pins(dinner.id)
      assert id == head.id

      view
      |> form("#{party_id("fixed-#{head.id}", ann)}-move-form", table_id: other.id)
      |> render_change()

      render_async(view)

      assert has_element?(view, party_id("fixed-#{other.id}", ann))
      refute has_element?(view, party_id("fixed-#{head.id}", ann))
      assert [%{seating_table_id: id}] = Seating.list_pins(dinner.id)
      assert id == other.id

      view |> element("#{party_id("fixed-#{other.id}", ann)}-unpin") |> render_click()
      render_async(view)

      assert Seating.list_pins(dinner.id) == []
      assert has_element?(view, party_id(t, ann))
    end

    test "freezing a fixed table pins who sits there; unfreeze removes every pin",
         %{conn: conn, scope: scope, dinner: dinner} do
      head = fixed!(scope, dinner, "Head")
      uni = Enum.find(Seating.list_circles(), &(&1.name == "Uni"))
      {:ok, _} = Seating.pin(scope, head, "circle:#{uni.id}")
      view = open_plan(conn, dinner)
      table = "fixed-#{head.id}"

      assert has_element?(view, "#freeze-#{table}")
      assert has_element?(view, "#unfreeze-#{table}")

      view |> element("#freeze-#{table}") |> render_click()
      render_async(view)

      # the circle's pin plus one per member
      assert length(Seating.list_pins(dinner.id)) == 4
      refute has_element?(view, "#freeze-#{table}")
      assert Repo.get_by(Entry, description: "Wannes froze 'Head' in 'Dinner'")

      view |> element("#unfreeze-#{table}") |> render_click()
      render_async(view)

      assert Seating.list_pins(dinner.id) == []
      assert Seating.get_table!(head.id)
      refute has_element?(view, "#unfreeze-#{table}")
      assert Repo.get_by(Entry, description: "Wannes unfroze 'Head' (4 pins removed)")
    end

    test "freezing a table of a type makes a fixed table, pins its people, takes from the limit",
         %{conn: conn, dinner: dinner, round: round, plan_table: t, people: people} do
      view = open_plan(conn, dinner)
      view |> element("#freeze-#{t}") |> render_click()
      render_async(view)

      assert [fixed] = dinner.id |> Seating.list_tables() |> Enum.filter(&(&1.kind == :fixed))
      assert fixed.name == "Round 1"
      assert Seating.get_table!(round.id).limit == 1
      assert length(Seating.list_pins(dinner.id)) == 6
      assert Repo.get_by(Entry, description: "Wannes froze 'Round 1' in 'Dinner'")

      assert has_element?(view, "#plan[data-status=ok]")
      assert Enum.all?(people, &has_element?(view, party_id("fixed-#{fixed.id}", &1)))
      assert has_element?(view, "#unfreeze-fixed-#{fixed.id}")
    end

    test "nothing to freeze is offered on a plan that cannot be made",
         %{conn: conn, scope: scope, dinner: dinner, round: round, people: [ann, bob | _]} do
      {:ok, _} =
        Seating.update_table(scope, round, %{
          "min_seats" => "5",
          "max_seats" => "5",
          "limit" => "1"
        })

      {:ok, _} =
        Seating.create_rule(scope, %{
          "subject" => "person:#{ann.id}",
          "object" => "person:#{bob.id}",
          "relation" => "never_with"
        })

      view = open_plan(conn, dinner)
      refute has_element?(view, "#plan[data-status=ok]")
      refute has_element?(view, "[id^=freeze-]")
    end
  end
end
