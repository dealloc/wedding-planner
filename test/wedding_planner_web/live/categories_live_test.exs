defmodule WeddingPlannerWeb.Live.CategoriesLiveTest do
  @moduledoc """
  `docs/modules/offers-and-comparison.md` `CST-01`, `CST-05`; `DR-26` Q11, Q13, Q23
  (money input); `XC-01`, `XC-10`, `XC-40` — the categories list LiveView (task 29).
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Repo

  setup %{conn: conn} do
    user = insert_user!("Wannes")
    %{conn: log_in_user(conn, user), user: user, scope: Scope.for_user(user)}
  end

  describe "authentication" do
    test "an unauthenticated request redirects to /login" do
      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, ~p"/categories")

      assert redirected_to(conn) == "/login?return_to=%2Fcategories"
    end
  end

  describe "index" do
    test "shows an empty state when there are no categories yet", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/categories")

      assert html =~ "Categories"
      assert has_element?(view, "#categories-empty")
    end

    test "the nav's Categories entry sits right after Events", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/categories")

      {events_pos, _} = :binary.match(html, "nav-events")
      {categories_pos, _} = :binary.match(html, "nav-categories")
      assert events_pos < categories_pos

      # nothing else sits between them: the raw HTML's nav-events list item is
      # immediately followed by the nav-categories one, so no other `nav-*` id can
      # occur in that gap.
      between = binary_part(html, events_pos, categories_pos - events_pos)
      refute between =~ ~r/nav-(?!events)/
    end
  end

  describe "create (CST-01, DR-23, DR-18)" do
    test "creating with target \"2.500\" (nl-BE) shows € 2.500,00 on the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/categories/new")

      form =
        form(view, "#category-form", category: %{"name" => "Venue", "target_input" => "2.500"})

      {:ok, index_view, _html} = form |> render_submit() |> follow_redirect(conn)

      assert has_element?(index_view, "#categories", "€ 2.500,00")
    end

    test "target \"1500.50\" is refused with the comma-decimal message (DR-18 trap)", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/new")

      html =
        view
        |> form("#category-form", category: %{"name" => "Venue", "target_input" => "1500.50"})
        |> render_submit()

      assert html =~ "Use a comma for the decimal part"
      assert has_element?(view, "#category-form")
    end

    test "a blank target shows \"No target\"", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/categories/new")

      form = form(view, "#category-form", category: %{"name" => "Venue"})
      {:ok, index_view, _html} = form |> render_submit() |> follow_redirect(conn)

      assert has_element?(index_view, "#categories", "No target")
    end

    test "a blank name is rejected with an inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/categories/new")

      html =
        view
        |> form("#category-form", category: %{"name" => ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert has_element?(view, "#category-form")
    end
  end

  describe "edit" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      %{category: category}
    end

    test "updates the category and shows the change on the list", %{
      conn: conn,
      category: category
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}/edit")

      form =
        form(view, "#category-form",
          category: %{"name" => "Reception venue", "target_input" => "1000"}
        )

      {:ok, index_view, _html} = form |> render_submit() |> follow_redirect(conn)

      assert has_element?(index_view, "#categories", "Reception venue")
      assert has_element?(index_view, "#categories", "€ 1.000,00")
    end

    test "pre-fills the current target for editing", %{conn: conn, scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Catering"})
      {:ok, category} = Categories.update_category(scope, category, %{"target_input" => "1000"})

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}/edit")

      assert view
             |> element("#category-form-target")
             |> render() =~ "1.000,00"
    end

    test "shows this category's own activity history, updating live", %{
      conn: conn,
      category: category,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}/edit")

      assert has_element?(view, "#category-history", "created category 'Venue'")

      {:ok, _updated} = Categories.update_category(scope, category, %{"name" => "Reception"})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#category-history", "changed the name")
    end
  end

  describe "reordering (CST-01)" do
    setup %{scope: scope} do
      {:ok, a} = Categories.create_category(scope, %{"name" => "A"})
      {:ok, b} = Categories.create_category(scope, %{"name" => "B"})
      %{a: a, b: b}
    end

    test "moving a category up persists across a fresh mount", %{conn: conn, a: a, b: b} do
      {:ok, view, _html} = live(conn, ~p"/categories")

      view |> element("#category-#{b.id}-move-up") |> render_click()

      {b_pos, _} = :binary.match(render(view), "category-#{b.id}-name")
      {a_pos, _} = :binary.match(render(view), "category-#{a.id}-name")
      assert b_pos < a_pos

      {:ok, fresh_view, _html} = live(conn, ~p"/categories")
      html = render(fresh_view)
      {b_pos2, _} = :binary.match(html, "category-#{b.id}-name")
      {a_pos2, _} = :binary.match(html, "category-#{a.id}-name")
      assert b_pos2 < a_pos2
    end

    test "the first row's move-up control is disabled", %{conn: conn, a: a, b: b} do
      {:ok, view, _html} = live(conn, ~p"/categories")

      assert has_element?(view, "#category-#{a.id}-move-up[disabled]")
      refute has_element?(view, "#category-#{b.id}-move-up[disabled]")
    end

    test "the last row's move-down control is disabled", %{conn: conn, a: a, b: b} do
      {:ok, view, _html} = live(conn, ~p"/categories")

      assert has_element?(view, "#category-#{b.id}-move-down[disabled]")
      refute has_element?(view, "#category-#{a.id}-move-down[disabled]")
    end
  end

  describe "delete (DR-26 Q11, XC-40)" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, _s1} = Categories.create_service(scope, category, %{"name" => "Catering"})
      {:ok, _s2} = Categories.create_service(scope, category, %{"name" => "Sound"})
      %{category: category}
    end

    test "requires confirmation before deleting", %{conn: conn, category: category} do
      {:ok, view, _html} = live(conn, ~p"/categories")

      refute has_element?(view, "#category-#{category.id}-delete-confirm")

      view |> element("#category-#{category.id}-delete") |> render_click()
      assert has_element?(view, "#category-#{category.id}-delete-confirm")

      assert Categories.get_category!(category.id)
    end

    test "the confirmation lists the service count", %{conn: conn, category: category} do
      {:ok, view, _html} = live(conn, ~p"/categories")

      view |> element("#category-#{category.id}-delete") |> render_click()

      assert has_element?(
               view,
               "#category-#{category.id}-delete-confirm-affected",
               "2 services"
             )
    end

    test "cancelling leaves the category in place", %{conn: conn, category: category} do
      {:ok, view, _html} = live(conn, ~p"/categories")

      view |> element("#category-#{category.id}-delete") |> render_click()
      view |> element("#category-#{category.id}-delete-confirm-cancel") |> render_click()

      refute has_element?(view, "#category-#{category.id}-delete-confirm")
      assert has_element?(view, "#category-#{category.id}-name")
    end

    test "confirming removes the category and every one of its services", %{
      conn: conn,
      category: category
    } do
      services_before = Categories.list_services(category)
      assert length(services_before) == 2

      {:ok, view, _html} = live(conn, ~p"/categories")

      view |> element("#category-#{category.id}-delete") |> render_click()
      view |> element("#category-#{category.id}-delete-confirm-confirm") |> render_click()

      refute has_element?(view, "#category-#{category.id}-name")
      assert_raise Ecto.NoResultsError, fn -> Categories.get_category!(category.id) end

      for service <- services_before do
        assert_raise Ecto.NoResultsError, fn -> Categories.get_service!(service.id) end
      end
    end
  end

  describe "live updates (XC-01, XC-02)" do
    test "a second session sees a newly created category without a refresh", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      {:ok, view_a, _html} = live(conn, ~p"/categories")
      {:ok, view_b, _html} = live(log_in_user(build_conn(), user), ~p"/categories")

      refute render(view_a) =~ "Venue"
      refute render(view_b) =~ "Venue"

      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      _ = :sys.get_state(view_a.pid)
      _ = :sys.get_state(view_b.pid)

      assert has_element?(view_a, "#category-#{category.id}-name", "Venue")
      assert has_element?(view_b, "#category-#{category.id}-name", "Venue")
    end
  end

  describe "export link (XC-30, DR-87)" do
    test "the Export CSV link carries the viewer's tz and is a plain download, not a LiveView navigation (FP-94a, FP-94b)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/categories")

      assert has_element?(view, "#export-offers[download][href^='/exports/offers?tz=']")
      refute has_element?(view, "#export-offers[data-phx-link]")
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
