defmodule WeddingPlannerWeb.Live.PersonLiveTest do
  @moduledoc """
  `docs/modules/guests-and-events.md` `PER-01`, `PER-02`, `docs/04-cross-cutting.md`
  `XC-10`, `XC-11`, `XC-40`, `NFR-31` — the per-person detail page (task 27, `DR-26` Q9).
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Guests
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

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
