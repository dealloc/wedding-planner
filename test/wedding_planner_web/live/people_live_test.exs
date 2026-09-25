defmodule WeddingPlannerWeb.Live.PeopleLiveTest do
  @moduledoc """
  `docs/modules/guests-and-events.md` `PER-01` through `PER-07`, `docs/04-cross-cutting.md`
  `XC-01`, `XC-10` through `XC-13`, `XC-40` — the people-management LiveView (task 27),
  on top of task 26's `WeddingPlanner.Guests` context.
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
    test "an unauthenticated request redirects to /login" do
      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, ~p"/people")

      assert redirected_to(conn) == "/login?return_to=%2Fpeople"
    end
  end

  describe "nav" do
    test "the nav has a People entry right after Home", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/people")

      html = render(view)
      {home_pos, _} = :binary.match(html, "id=\"nav-home\"")
      {people_pos, _} = :binary.match(html, "id=\"nav-people\"")
      {events_pos, _} = :binary.match(html, "id=\"nav-events\"")

      assert home_pos < people_pos
      assert people_pos < events_pos
      assert has_element?(view, "#nav-people a", "People")
    end
  end

  describe "empty state" do
    test "shows an empty state when there are no people yet", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/people")

      assert html =~ "People"
      assert has_element?(view, "#people-empty")
      assert has_element?(view, "#people-count", "0 of 0 shown")
    end
  end

  describe "paste a list (DR-26 Q5, Q6, PER-04)" do
    test "6 lines including 'Bo' and 'Van Damme, Jan' preview and add correctly", %{
      conn: conn,
      scope: scope
    } do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      {:ok, view, _html} = live(conn, ~p"/people")

      view |> element("#people-paste-toggle") |> render_click()

      text = "Anna Peeters\nBert Aerts\nVan Damme, Jan\nBo\nEva de Smet\nSven Nys"

      view
      |> form("#paste-form", %{text: text})
      |> render_change()

      assert has_element?(view, "#paste-preview-count", "Add 6 people")

      view
      |> form("#paste-form", %{
        text: text,
        group_id: to_string(group.id),
        age_category: "adult",
        want_tier: "maybe",
        certainty: "certain"
      })
      |> render_submit()

      assert has_element?(view, "#people-count", "6 of 6 shown")

      persons = Guests.list_persons(%{})
      assert length(persons) == 6
      assert Enum.all?(persons, &(&1.group_id == group.id))
      assert Enum.all?(persons, &(&1.want_tier == :maybe))
      assert Enum.all?(persons, &(&1.certainty == :certain))

      jan = Enum.find(persons, &(&1.last_name == "Van Damme"))
      assert jan.first_name == "Jan"

      bo = Enum.find(persons, &(&1.first_name == "Bo"))
      assert bo.last_name == nil

      {:ok, activity_view, _html} = live(conn, ~p"/activity")
      assert has_element?(activity_view, "#activity-log", "added 6 people")
    end
  end

  describe "quick-add (DR-26 Q6, PER-02)" do
    test "keeps group/age/want/certainty sticky after submit, clears only the names", %{
      conn: conn,
      scope: scope
    } do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Friends"})

      {:ok, view, _html} = live(conn, ~p"/people")

      view
      |> form("#quick-add-form",
        quick_add: %{
          "first_name" => "Anna",
          "last_name" => "Peeters",
          "group_id" => to_string(group.id),
          "age_category" => "adult",
          "want_tier" => "maybe",
          "certainty" => "uncertain"
        }
      )
      |> render_submit()

      assert [anna] = Guests.list_persons(%{})
      assert anna.first_name == "Anna"
      assert anna.group_id == group.id

      refute has_element?(view, "#quick-add-first-name[value='Anna']")
      assert has_element?(view, "#quick-add-group option[value='#{group.id}'][selected]")
      assert has_element?(view, "#quick-add-want option[value='maybe'][selected]")
      assert has_element?(view, "#quick-add-certainty option[value='uncertain'][selected]")

      view
      |> form("#quick-add-form", quick_add: %{"first_name" => "Bert", "last_name" => ""})
      |> render_submit()

      persons = Guests.list_persons(%{})
      assert length(persons) == 2
      bert = Enum.find(persons, &(&1.first_name == "Bert"))
      assert bert.group_id == group.id
      assert bert.want_tier == :maybe
      assert bert.certainty == :uncertain
    end

    test "adding with both names blank shows the PER-02 error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/people")

      html =
        view
        |> form("#quick-add-form", quick_add: %{"first_name" => "", "last_name" => ""})
        |> render_submit()

      assert html =~ "must provide a first or last name"
      assert Guests.list_persons(%{}) == []
    end
  end

  describe "inline edit (XC-10)" do
    setup %{scope: scope} do
      {:ok, person} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      %{person: person}
    end

    test "committing a first-name edit on blur updates the person with one log entry", %{
      conn: conn,
      person: person
    } do
      {:ok, view, _html} = live(conn, ~p"/people")

      view
      |> element("#person-#{person.id}-first-name")
      |> render_blur(%{value: "Annelies"})

      updated = Guests.get_person!(person.id)
      assert updated.first_name == "Annelies"

      {:ok, activity_view, _html} = live(conn, ~p"/activity")
      html = render(activity_view)

      assert (html |> String.split("changed the first name") |> length()) - 1 == 1
    end
  end

  describe "flat view sorting and filtering (PER-05)" do
    setup %{scope: scope} do
      {:ok, family} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      {:ok, anna} =
        Guests.create_person(scope, %{
          "first_name" => "Anna",
          "last_name" => "Peeters",
          "age_category" => "adult",
          "want_tier" => "yes",
          "certainty" => "certain",
          "group_id" => family.id
        })

      {:ok, bo} =
        Guests.create_person(scope, %{
          "first_name" => "Bo",
          "age_category" => "child",
          "want_tier" => "maybe",
          "certainty" => "uncertain"
        })

      %{family: family, anna: anna, bo: bo}
    end

    test "sorts by last name by default", %{conn: conn, anna: anna, bo: bo} do
      {:ok, _view, html} = live(conn, ~p"/people")

      {anna_pos, _} = :binary.match(html, "person-#{anna.id}-first-name")
      {bo_pos, _} = :binary.match(html, "person-#{bo.id}-first-name")

      # "Bo" (first-name-only, sorts under B) comes before "Anna Peeters" (sorts under P).
      assert bo_pos < anna_pos
    end

    test "each filter narrows the list", %{conn: conn, family: family, anna: anna, bo: bo} do
      {:ok, view, _html} = live(conn, ~p"/people?group=#{family.id}")
      assert has_element?(view, "#person-#{anna.id}-first-name")
      refute has_element?(view, "#person-#{bo.id}-first-name")

      {:ok, view, _html} = live(conn, ~p"/people?age=child")
      refute has_element?(view, "#person-#{anna.id}-first-name")
      assert has_element?(view, "#person-#{bo.id}-first-name")

      {:ok, view, _html} = live(conn, ~p"/people?want=maybe")
      refute has_element?(view, "#person-#{anna.id}-first-name")
      assert has_element?(view, "#person-#{bo.id}-first-name")

      {:ok, view, _html} = live(conn, ~p"/people?certainty=certain")
      assert has_element?(view, "#person-#{anna.id}-first-name")
      refute has_element?(view, "#person-#{bo.id}-first-name")

      {:ok, view, _html} = live(conn, ~p"/people?q=Anna")
      assert has_element?(view, "#person-#{anna.id}-first-name")
      refute has_element?(view, "#person-#{bo.id}-first-name")
    end

    test "'Clear filters' is shown only when a filter is active", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/people")
      refute has_element?(view, "#people-clear-filters")

      {:ok, view, _html} = live(conn, ~p"/people?q=Anna")
      assert has_element?(view, "#people-clear-filters")
    end
  end

  describe "grouped view (PER-05, PER-04, PER-07)" do
    setup %{scope: scope} do
      {:ok, family} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      {:ok, anna} =
        Guests.create_person(scope, %{"first_name" => "Anna", "group_id" => family.id})

      {:ok, bert} =
        Guests.create_person(scope, %{"first_name" => "Bert", "group_id" => family.id})

      {:ok, bo} = Guests.create_person(scope, %{"first_name" => "Bo"})

      %{family: family, anna: anna, bert: bert, bo: bo}
    end

    test "lists groups and Ungrouped", %{conn: conn, family: family} do
      {:ok, view, _html} = live(conn, ~p"/people?view=grouped")

      assert has_element?(view, "#group-#{family.id}-name[value='Family Peeters']")
      assert has_element?(view, "#group-ungrouped", "Ungrouped")
    end

    test "select-all-in-group + bulk want tier writes a summary naming the group", %{
      conn: conn,
      family: family,
      anna: anna,
      bert: bert
    } do
      {:ok, view, _html} = live(conn, ~p"/people?view=grouped")

      view |> element("#group-#{family.id}-select-all") |> render_click()
      assert has_element?(view, "#people-selected-count", "2 selected")

      view |> element("#people-bulk-want-maybe") |> render_click()

      assert Guests.get_person!(anna.id).want_tier == :maybe
      assert Guests.get_person!(bert.id).want_tier == :maybe

      {:ok, activity_view, _html} = live(conn, ~p"/activity")
      assert has_element?(activity_view, "#activity-log", "Family Peeters")
    end

    test "deleting a group shows the member count and ungroups members with data intact", %{
      conn: conn,
      family: family,
      anna: anna,
      bert: bert
    } do
      {:ok, view, _html} = live(conn, ~p"/people?view=grouped")

      view |> element("#group-#{family.id}-delete") |> render_click()
      assert has_element?(view, "#group-#{family.id}-delete-confirm", "2 people become ungrouped")

      view |> element("#group-#{family.id}-delete-confirm-confirm") |> render_click()

      refute has_element?(view, "#group-#{family.id}")

      updated_anna = Guests.get_person!(anna.id)
      updated_bert = Guests.get_person!(bert.id)
      assert updated_anna.group_id == nil
      assert updated_bert.group_id == nil
      assert updated_anna.first_name == "Anna"
      assert updated_bert.first_name == "Bert"
    end
  end

  describe "bulk delete (PER-07)" do
    setup %{scope: scope} do
      {:ok, anna} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, bo} = Guests.create_person(scope, %{"first_name" => "Bo"})
      %{anna: anna, bo: bo}
    end

    test "names the selected people in the confirmation and deletes only them", %{
      conn: conn,
      anna: anna,
      bo: bo
    } do
      {:ok, view, _html} = live(conn, ~p"/people")

      view |> element("#person-#{anna.id}-select") |> render_click()
      view |> element("#people-bulk-delete") |> render_click()

      assert has_element?(view, "#people-bulk-delete-confirm", "Anna Peeters")

      view |> element("#people-bulk-delete-confirm-confirm") |> render_click()

      assert_raise Ecto.NoResultsError, fn -> Guests.get_person!(anna.id) end
      assert Guests.get_person!(bo.id)
    end
  end

  describe "single delete (XC-40)" do
    setup %{scope: scope} do
      {:ok, person} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      %{person: person}
    end

    test "shows the confirmation bar under the row, not inside the icon column", %{
      conn: conn,
      person: person
    } do
      {:ok, view, _html} = live(conn, ~p"/people")

      refute has_element?(view, "#person-#{person.id}-delete-confirm")

      view |> element("#person-#{person.id}-delete") |> render_click()

      assert has_element?(view, "#person-#{person.id}-delete-confirm")
      assert Guests.get_person!(person.id)

      view |> element("#person-#{person.id}-delete-confirm-confirm") |> render_click()
      assert_raise Ecto.NoResultsError, fn -> Guests.get_person!(person.id) end
    end
  end

  describe "live updates (XC-01, DR-21)" do
    test "a change made by another process appears silently, with no changed indicator", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, ~p"/people")
      refute render(view) =~ "Ceremony Guest"

      {:ok, person} = Guests.create_person(scope, %{"first_name" => "Ceremony Guest"})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert has_element?(view, "#person-#{person.id}-first-name")
      refute html =~ "updated"
      refute html =~ "changed"
    end
  end

  describe "What if… entry points (task 89, DR-82)" do
    test "the toolbar link navigates to /what-if with no params", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/people")
      assert has_element?(view, "#people-what-if")

      {:ok, what_if_view, _html} =
        view
        |> element("#people-what-if")
        |> render_click()
        |> follow_redirect(conn, ~p"/what-if")

      assert has_element?(what_if_view, "#what-if-header")
    end

    test "the bulk bar's link carries the selection, a selected +1 contributing its host",
         %{conn: conn, scope: scope} do
      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, _plus_one} = Guests.add_plus_one(scope, host, %{"plus_one_status" => "confirmed"})

      {:ok, view, _html} = live(conn, ~p"/people")

      view |> element("#person-#{host.id}-select") |> render_click()
      assert has_element?(view, "#people-bulk-what-if")

      {:ok, what_if_view, _html} =
        view |> element("#people-bulk-what-if") |> render_click() |> follow_redirect(conn)

      assert has_element?(what_if_view, "#what-if-person-#{host.id}")
    end
  end

  describe "export link (XC-30, DR-87)" do
    test "the Export CSV link carries the viewer's tz and is a plain download, not a LiveView navigation (FP-94a, FP-94b)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/people")

      assert has_element?(view, "#export-persons[download][href^='/exports/persons?tz=']")
      refute has_element?(view, "#export-persons[data-phx-link]")
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
