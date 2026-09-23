defmodule WeddingPlannerWeb.Live.PersonLiveTest do
  @moduledoc """
  `docs/modules/guests-and-events.md` `PER-01`, `PER-02`, `PER-10`–`PER-16`,
  `docs/04-cross-cutting.md` `XC-10`, `XC-11`, `XC-40`, `NFR-31` — the per-person detail
  page (task 27, `DR-26` Q9) and its +1 handling (task 37, `DR-32`/`DR-34`).
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Log.Query, as: LogQuery
  alias WeddingPlanner.Repo

  setup %{conn: conn} do
    user = insert_user!("Wannes")
    %{conn: log_in_user(conn, user), user: user, scope: Scope.for_user(user)}
  end

  describe "authentication" do
    test "an unauthenticated request redirects to /login", %{scope: scope} do
      {:ok, person} = Guests.create_person(scope, %{"first_name" => "Anna"})

      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, ~p"/people/#{person.id}")

      assert redirected_to(conn) =~ "/login"
    end
  end

  describe "edit" do
    setup %{scope: scope} do
      {:ok, person} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      %{person: person}
    end

    test "edits a field and shows it in the history", %{conn: conn, person: person} do
      {:ok, view, html} = live(conn, ~p"/people/#{person.id}")

      assert html =~ "Anna Peeters"
      assert has_element?(view, "#person-history", "added 'Anna Peeters'")

      view
      |> form("#person-form",
        person: %{
          "first_name" => "Anna",
          "last_name" => "Peeters",
          "want_tier" => "maybe",
          "certainty" => "likely",
          "age_category" => "adult"
        }
      )
      |> render_submit()

      assert Guests.get_person!(person.id).want_tier == :maybe
      assert has_element?(view, "#person-history", "changed the want tier")
    end

    test "the activity log's person link navigates here", %{conn: conn, person: person} do
      {:ok, activity_view, _html} = live(conn, ~p"/activity")

      assert has_element?(activity_view, "#activity-log", "Anna Peeters")

      {:ok, view, _html} =
        activity_view
        |> element("#activity-log a", "Anna Peeters")
        |> render_click()
        |> follow_redirect(conn)

      assert has_element?(view, "#person-form")
      assert has_element?(view, "h1", "Anna Peeters")
      _ = view
      _ = person
    end

    test "delete requires confirmation and removes the person", %{conn: conn, person: person} do
      {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")

      refute has_element?(view, "#person-delete-confirm")

      view |> element("#person-delete") |> render_click()
      assert has_element?(view, "#person-delete-confirm")
      assert Guests.get_person!(person.id)

      {:ok, index_view, _html} =
        view
        |> element("#person-delete-confirm-confirm")
        |> render_click()
        |> follow_redirect(conn, ~p"/people")

      assert index_view
      assert_raise Ecto.NoResultsError, fn -> Guests.get_person!(person.id) end
    end
  end

  describe "plus ones" do
    setup %{scope: scope} do
      {:ok, host} =
        Guests.create_person(scope, %{
          "first_name" => "Anna",
          "last_name" => "Peeters",
          "want_tier" => "maybe",
          "certainty" => "certain"
        })

      %{host: host}
    end

    test "a possible +1's page shows the host link, no editable want/certainty/group and the inherited values",
         %{conn: conn, scope: scope, host: host} do
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{plus_one_status: :possible})

      {:ok, view, html} = live(conn, ~p"/people/#{plus_one.id}")

      assert html =~ "+1 of Anna Peeters"
      assert has_element?(view, "#person-host-link", "Anna Peeters")

      refute has_element?(view, "#person-form-want")
      refute has_element?(view, "#person-form-certainty")
      refute has_element?(view, "#person-form-group")

      assert has_element?(view, "#person-inherited-want", "Maybe")
      assert has_element?(view, "#person-inherited-certainty", "Uncertain")
      assert has_element?(view, "#person-inherited-group", "No group")
    end

    test "a confirmed +1 inherits the host's own certainty (no possible cap)",
         %{conn: conn, scope: scope, host: host} do
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{plus_one_status: :confirmed})

      {:ok, view, _html} = live(conn, ~p"/people/#{plus_one.id}")

      assert has_element?(view, "#person-inherited-certainty", "Certain")
    end

    test "Confirm is a single click that writes exactly one activity entry",
         %{conn: conn, scope: scope, host: host} do
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{plus_one_status: :possible})
      before_count = length(LogQuery.for_entity(:person, plus_one.id))

      {:ok, view, _html} = live(conn, ~p"/people/#{plus_one.id}")
      assert has_element?(view, "#person-confirm-plus-one")

      view |> element("#person-confirm-plus-one") |> render_click()

      assert Guests.get_person!(plus_one.id).plus_one_status == :confirmed
      refute has_element?(view, "#person-confirm-plus-one")
      assert length(LogQuery.for_entity(:person, plus_one.id)) == before_count + 1
    end

    test "Name is a single submit that writes exactly one entry and updates the page title",
         %{conn: conn, scope: scope, host: host} do
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{plus_one_status: :confirmed})
      before_count = length(LogQuery.for_entity(:person, plus_one.id))

      {:ok, view, html} = live(conn, ~p"/people/#{plus_one.id}")
      assert html =~ "+1 of Anna Peeters"
      assert has_element?(view, "#person-name-form")

      view
      |> form("#person-name-form", person: %{"first_name" => "Tom", "last_name" => "Wils"})
      |> render_submit()

      assert has_element?(view, "h1", "Tom Wils")
      refute has_element?(view, "#person-name-form")
      assert Guests.get_person!(plus_one.id).first_name == "Tom"
      assert length(LogQuery.for_entity(:person, plus_one.id)) == before_count + 1
    end

    test "editing a +1's age saves, but a posted want_tier is refused",
         %{conn: conn, scope: scope, host: host} do
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{plus_one_status: :confirmed})

      {:ok, view, _html} = live(conn, ~p"/people/#{plus_one.id}")

      view
      |> form("#person-form", person: %{"age_category" => "child"})
      |> render_submit()

      assert Guests.get_person!(plus_one.id).age_category == :child

      # The rendered form never has a want_tier input for a +1 — simulate a crafted
      # param bypassing the UI to prove the context itself refuses it (`PER-15`).
      render_submit(view, "save", %{"person" => %{"want_tier" => "no"}})

      assert Guests.get_person!(plus_one.id).want_tier == host.want_tier
    end

    test "a host's page lists its +1s and can add one", %{conn: conn, scope: scope, host: host} do
      {:ok, existing} = Guests.add_plus_one(scope, host, %{plus_one_status: :possible})

      {:ok, view, _html} = live(conn, ~p"/people/#{host.id}")

      assert has_element?(view, "#person-plus-ones")
      assert has_element?(view, "#person-plus-one-#{existing.id}")

      view
      |> form("#person-add-plus-one-form",
        person: %{
          "first_name" => "Tom",
          "last_name" => "Wils",
          "plus_one_status" => "confirmed",
          "age_category" => "adult"
        }
      )
      |> render_submit()

      plus_ones = Guests.get_person!(host.id).plus_ones
      assert length(plus_ones) == 2

      new_plus_one = Enum.find(plus_ones, &(&1.first_name == "Tom"))
      assert new_plus_one
      assert has_element?(view, "#person-plus-one-#{new_plus_one.id}", "Tom Wils")
    end

    test "the host's delete confirmation names the +1", %{conn: conn, scope: scope, host: host} do
      {:ok, plus_one} =
        Guests.add_plus_one(scope, host, %{
          first_name: "Tom",
          last_name: "Wils",
          plus_one_status: :confirmed
        })

      {:ok, view, _html} = live(conn, ~p"/people/#{host.id}")

      view |> element("#person-delete") |> render_click()

      assert has_element?(view, "#person-delete-confirm-affected", "Tom Wils")
      _ = plus_one
    end

    test "renaming the host re-renders an unnamed +1's page title live",
         %{conn: conn, scope: scope, host: host} do
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{plus_one_status: :confirmed})

      {:ok, view, _html} = live(conn, ~p"/people/#{plus_one.id}")
      assert has_element?(view, "h1", "+1 of Anna Peeters")

      {:ok, _updated} = Guests.update_person(scope, host, %{"first_name" => "Annelies"})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "h1", "+1 of Annelies Peeters")
      assert has_element?(view, "#person-host-link", "Annelies Peeters")
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
