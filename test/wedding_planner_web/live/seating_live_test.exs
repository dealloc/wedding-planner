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
    assert has_element?(view, "#circles-empty")
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

      [circle] = Seating.list_circles()
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
