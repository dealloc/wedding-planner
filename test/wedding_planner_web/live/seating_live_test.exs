defmodule WeddingPlannerWeb.Live.SeatingLiveTest do
  @moduledoc """
  `/seating`, slice 1 (`docs/modules/seating.md` SEAT-02, SEAT-20..SEAT-35,
  SEAT-60..SEAT-62, `XC-01`, `XC-40`): circles, members, rules and the health panel.
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
      for {first, last} <- [{"Jan", "Peeters"}, {"Mia", "Peeters"}, {"Tom", "Wils"}] do
        {:ok, person} = Guests.create_person(scope, %{"first_name" => first, "last_name" => last})
        {:ok, _} = Invitations.set_invitation_status(scope, person, dinner, :accepted)
        person
      end

    [jan, mia, tom] = people
    %{conn: log_in_user(conn, user), scope: scope, dinner: dinner, jan: jan, mia: mia, tom: tom}
  end

  test "an unauthenticated request redirects to /login" do
    conn = get(Phoenix.ConnTest.build_conn(), ~p"/seating")
    assert redirected_to(conn) == "/login?return_to=%2Fseating"
  end

  test "the nav has a Seating entry; empty states show", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/seating")

    assert has_element?(view, "#nav-seating a", "Seating")
    refute has_element?(view, "#circles-empty")
    assert has_element?(view, "#rules-empty")
  end

  describe "circles" do
    test "add a circle, add a person and a whole group, remove a member", %{
      conn: conn,
      scope: scope,
      jan: jan,
      mia: mia
    } do
      {:ok, family} = Guests.create_group(scope, %{"name" => "Family Peeters"})
      {:ok, _} = Guests.update_person(scope, jan, %{"group_id" => family.id})
      {:ok, _} = Guests.update_person(scope, mia, %{"group_id" => family.id})
      {:ok, view, _html} = live(conn, ~p"/seating")

      view
      |> form("#circle-form", circle: %{name: "Uni friends", cohesion: "keep_together"})
      |> render_submit()

      [circle] =
        Enum.reject(Seating.list_circles(), &WeddingPlanner.Seating.Circle.wedding_party?/1)

      assert has_element?(view, "#circle-#{circle.id}-name", "Uni friends")
      assert has_element?(view, "#circle-#{circle.id}-cohesion[data-cohesion=keep_together]")

      view
      |> form("#circle-#{circle.id}-add-member", member: "group:#{family.id}")
      |> render_change()

      assert has_element?(view, "#circle-#{circle.id}-member-#{jan.id}")
      assert has_element?(view, "#circle-#{circle.id}-member-#{mia.id}")

      view |> element("#circle-#{circle.id}-member-#{mia.id}-remove") |> render_click()
      refute has_element?(view, "#circle-#{circle.id}-member-#{mia.id}")
    end

    test "a duplicate name shows inline", %{conn: conn, scope: scope} do
      {:ok, _} = Seating.create_circle(scope, %{"name" => "Work", "cohesion" => "like_together"})
      {:ok, view, _html} = live(conn, ~p"/seating")

      html = view |> form("#circle-form", circle: %{name: "Work"}) |> render_submit()
      assert html =~ "another circle already has this name"
    end

    test "edit and delete with confirmation naming its rules (XC-40)", %{
      conn: conn,
      scope: scope,
      jan: jan
    } do
      {:ok, circle} =
        Seating.create_circle(scope, %{"name" => "Work", "cohesion" => "like_together"})

      {:ok, _} =
        Seating.create_rule(scope, %{
          "subject" => "circle:#{circle.id}",
          "object" => "person:#{jan.id}",
          "relation" => "keep_apart"
        })

      {:ok, view, _html} = live(conn, ~p"/seating")

      view |> element("#circle-#{circle.id}-edit") |> render_click()

      view
      |> form("#circle-#{circle.id}-edit-form",
        edit_circle: %{name: "Office", cohesion: "know_each_other"}
      )
      |> render_submit()

      assert has_element?(view, "#circle-#{circle.id}-name", "Office")

      view |> element("#circle-#{circle.id}-delete") |> render_click()

      assert has_element?(
               view,
               "#circle-#{circle.id}-delete-confirm-affected",
               "Also deletes 1 seating rule"
             )

      view |> element("#circle-#{circle.id}-delete-confirm button", "Delete") |> render_click()
      refute has_element?(view, "#circle-#{circle.id}")
      assert has_element?(view, "#rules-empty")
    end
  end

  describe "rules" do
    test "add, edit and delete a rule", %{conn: conn, jan: jan, mia: mia} do
      {:ok, view, _html} = live(conn, ~p"/seating")

      view
      |> form("#rule-form",
        rule: %{
          subject: "person:#{jan.id}",
          relation: "never_with",
          object: "person:#{mia.id}",
          reason: "divorce"
        }
      )
      |> render_submit()

      [rule] = Seating.list_rules()
      assert has_element?(view, "#rule-#{rule.id}-relation[data-relation=never_with]")
      assert has_element?(view, "#rule-#{rule.id}-reason", "divorce")

      view |> element("#rule-#{rule.id}-edit") |> render_click()
      view |> form("#rule-form", rule: %{relation: "keep_apart"}) |> render_submit()
      assert has_element?(view, "#rule-#{rule.id}-relation[data-relation=keep_apart]")

      view |> element("#rule-#{rule.id}-delete") |> render_click()
      view |> element("#rule-#{rule.id}-delete-confirm button", "Delete") |> render_click()
      assert has_element?(view, "#rules-empty")
    end

    test "the reverse of an existing rule is refused inline", %{
      conn: conn,
      scope: scope,
      jan: jan,
      mia: mia
    } do
      {:ok, _} =
        Seating.create_rule(scope, %{
          "subject" => "person:#{jan.id}",
          "object" => "person:#{mia.id}",
          "relation" => "seat_with"
        })

      {:ok, view, _html} = live(conn, ~p"/seating")

      html =
        view
        |> form("#rule-form",
          rule: %{subject: "person:#{mia.id}", relation: "keep_apart", object: "person:#{jan.id}"}
        )
        |> render_submit()

      assert html =~ "there is already a rule between these two"
    end
  end

  describe "tables (SEAT-40, D-42)" do
    test "add a table type and a fixed table, edit one, delete one", %{conn: conn, dinner: dinner} do
      {:ok, view, _html} = live(conn, ~p"/seating")

      assert has_element?(view, "#tables-empty")
      assert has_element?(view, "#health-blocking #problem-no-tables")

      view
      |> form("#table-form", table: %{kind: "type", name: "Round", min_seats: 2, max_seats: 4})
      |> render_submit()

      [round] = Seating.list_tables(dinner.id)
      assert has_element?(view, "#table-#{round.id}[data-kind=type]")
      assert has_element?(view, "#table-#{round.id}-seats", "2–4 seats · as many as needed")
      assert has_element?(view, "#health-available", "As needed")
      refute has_element?(view, "#problem-no-tables")

      view |> form("#table-form", table: %{kind: "fixed"}) |> render_change()
      refute has_element?(view, "#table-form-limit")

      view
      |> form("#table-form", table: %{kind: "fixed", name: "Head", min_seats: 2, max_seats: 6})
      |> render_submit()

      head = Enum.find(Seating.list_tables(dinner.id), &(&1.name == "Head"))
      assert has_element?(view, "#table-#{head.id}[data-kind=fixed]")

      view |> element("#table-#{round.id}-edit") |> render_click()

      view
      |> form("#table-#{round.id}-edit-form", edit_table: %{limit: 2})
      |> render_submit()

      assert has_element?(view, "#table-#{round.id}-seats", "2–4 seats · at most 2")
      assert has_element?(view, "#health-available", "14")

      view |> element("#table-#{head.id}-delete") |> render_click()
      view |> element("#table-#{head.id}-delete-confirm button", "Delete") |> render_click()
      refute has_element?(view, "#table-#{head.id}")
    end

    test "too many people for limited tables is blocking (S7)", %{
      conn: conn,
      scope: scope,
      dinner: dinner
    } do
      {:ok, _} =
        Seating.create_table(scope, dinner, %{
          "name" => "Small",
          "min_seats" => "1",
          "max_seats" => "2",
          "limit" => "1"
        })

      {:ok, view, _html} = live(conn, ~p"/seating")

      assert has_element?(view, "#problem-too-many-seats", "3 seats needed, 2 available")
    end

    test "an invalid table shows its errors inline", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/seating")

      html =
        view
        |> form("#table-form", table: %{name: "Round", min_seats: 6, max_seats: 4})
        |> render_submit()

      assert html =~ "must be at least the minimum"
    end

    test "links to the plan, keeping the scenario", %{conn: conn, dinner: dinner} do
      {:ok, view, _html} = live(conn, ~p"/seating")

      assert view |> element("#to-plan") |> render() =~ "/seating/plan?event=#{dinner.id}"
    end
  end

  describe "the wedding party and pins (SEAT-24, SEAT-42)" do
    test "the wedding party is built in: the couple and witnesses are locked in, it can't be deleted",
         %{conn: conn, scope: scope, jan: jan} do
      # A witness is a witness of a user with a passkey (`Users.assignable?/1`, PER-20).
      %WeddingPlanner.Accounts.Passkey{user_id: scope.user.id, sign_count: 0}
      |> WeddingPlanner.Accounts.Passkey.registration_changeset(%{
        credential_id: :crypto.strong_rand_bytes(16),
        public_key: :crypto.strong_rand_bytes(16),
        name: "Laptop",
        registered_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

      {:ok, _} = Guests.set_witness(scope, jan, scope.user.id)
      party = Enum.find(Seating.list_circles(), &WeddingPlanner.Seating.Circle.wedding_party?/1)
      {:ok, view, _html} = live(conn, ~p"/seating")

      assert has_element?(view, "#circle-#{party.id}-built-in")
      assert has_element?(view, "#circle-#{party.id}-derived-couple")
      assert has_element?(view, "#circle-#{party.id}-derived-person-#{jan.id}", "Jan Peeters")
      refute has_element?(view, "#circle-#{party.id}-delete")
    end

    test "seat the wedding party at a fixed table, then unpin it", %{
      conn: conn,
      scope: scope,
      dinner: dinner
    } do
      {:ok, head} =
        Seating.create_table(scope, dinner, %{
          "kind" => "fixed",
          "name" => "Head",
          "min_seats" => "1",
          "max_seats" => "6"
        })

      party = Enum.find(Seating.list_circles(), &WeddingPlanner.Seating.Circle.wedding_party?/1)
      {:ok, view, _html} = live(conn, ~p"/seating")

      view |> form("#table-#{head.id}-pin-form", side: "circle:#{party.id}") |> render_change()

      [pin] = Seating.list_pins(dinner.id)
      assert has_element?(view, "#pin-#{pin.id}", "Wedding party")

      view |> element("#pin-#{pin.id}-remove") |> render_click()
      refute has_element?(view, "#pin-#{pin.id}")
    end

    test "a pin for someone not coming is listed as inactive (SEAT-43)",
         %{conn: conn, scope: scope, dinner: dinner} do
      {:ok, head} =
        Seating.create_table(scope, dinner, %{
          "kind" => "fixed",
          "name" => "Head",
          "min_seats" => "1",
          "max_seats" => "6"
        })

      {:ok, oma} = Guests.create_person(scope, %{"first_name" => "Oma"})
      {:ok, pin} = Seating.pin(scope, head, "person:#{oma.id}")
      {:ok, view, _html} = live(conn, ~p"/seating")

      assert has_element?(view, "#health-inactive-pins #inactive-pin-#{pin.id}", "Oma → Head")
    end

    test "pinning beyond a fixed table's maximum is blocking", %{
      conn: conn,
      scope: scope,
      dinner: dinner
    } do
      {:ok, head} =
        Seating.create_table(scope, dinner, %{
          "kind" => "fixed",
          "name" => "Head",
          "min_seats" => "1",
          "max_seats" => "1"
        })

      {:ok, _} = Seating.pin(scope, head, "couple")
      {:ok, _} = Events.update_event(scope, dinner, %{"couple_attends" => true})
      {:ok, view, _html} = live(conn, ~p"/seating")

      assert has_element?(view, "#problem-pinned-above-#{head.id}", "2 pinned to Head")
    end
  end

  describe "health panel" do
    test "counts seats under the preset and lists loose ends (SEAT-62, S10)", %{
      conn: conn,
      tom: tom
    } do
      {:ok, view, _html} = live(conn, ~p"/seating")

      assert has_element?(view, "#health-seats", "3")
      assert has_element?(view, "#health-loose-ends #loose-person-#{tom.id}")

      view |> element("#fine-anywhere-#{tom.id}") |> render_click()
      refute has_element?(view, "#loose-person-#{tom.id}")
      assert has_element?(view, "#fine-anywhere-person-#{tom.id}")

      view |> element("#fine-anywhere-#{tom.id}-undo") |> render_click()
      assert has_element?(view, "#loose-person-#{tom.id}")
    end

    test "a blocking chain is shown and its rules flagged (S4)", %{
      conn: conn,
      scope: scope,
      jan: jan,
      mia: mia,
      tom: tom
    } do
      rule = fn a, b, relation ->
        {:ok, rule} =
          Seating.create_rule(scope, %{
            "subject" => "person:#{a.id}",
            "object" => "person:#{b.id}",
            "relation" => relation
          })

        rule
      end

      _ = rule.(jan, mia, "always_with")
      _ = rule.(mia, tom, "always_with")
      never = rule.(jan, tom, "never_with")

      {:ok, view, _html} = live(conn, ~p"/seating")

      assert has_element?(
               view,
               "#health-blocking #blocking-#{never.id}",
               "Jan Peeters → Mia Peeters → Tom Wils"
             )

      assert has_element?(view, "#rule-#{never.id}-flag")
    end

    test "the couple is seated for an event whose couple attends (SEAT-03)", %{
      conn: conn,
      scope: scope,
      dinner: dinner
    } do
      {:ok, view, _html} = live(conn, ~p"/seating")
      assert has_element?(view, "#health-seats", "3")

      {:ok, _} = Events.update_event(scope, dinner, %{"couple_attends" => true})
      assert has_element?(view, "#health-seats", "5")
    end

    test "switching event and preset re-evaluates; nothing is stored", %{conn: conn, scope: scope} do
      {:ok, party} = Events.create_event(scope, %{"name" => "Party", "couple_attends" => false})
      {:ok, view, _html} = live(conn, ~p"/seating")

      view |> form("#scenario-form", event_id: party.id) |> render_change()
      assert has_element?(view, "#health-seats", "0")
    end

    test "updates live when another session changes the guest list (XC-01)", %{
      conn: conn,
      scope: scope,
      dinner: dinner
    } do
      {:ok, view, _html} = live(conn, ~p"/seating")

      {:ok, anna} = Guests.create_person(scope, %{"first_name" => "Anna"})
      {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :accepted)

      assert has_element?(view, "#health-seats", "4")
    end
  end

  test "with no events the panel says to add one", %{conn: conn, scope: scope, dinner: dinner} do
    {:ok, _} = Events.delete_event(scope, dinner)
    {:ok, view, _html} = live(conn, ~p"/seating")

    assert has_element?(view, "#health-no-events")
  end
end
