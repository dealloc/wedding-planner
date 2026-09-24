defmodule WeddingPlannerWeb.LayoutsTest do
  @moduledoc """
  The root layout and app shell: the app has no public surface and is not the Phoenix
  scaffold — the page `<title>` must not carry the generator's "· Phoenix Framework"
  suffix, and the header must not show the scaffold's Phoenix logo image (removed in
  favour of a plain text wordmark, per `.claude/design/ui-decisions.md` §2 — no logo
  asset is specified there).
  """
  use WeddingPlannerWeb.ConnCase, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Repo
  alias WeddingPlannerWeb.Layouts

  setup %{conn: conn} do
    user = insert_user!("Wannes")
    %{conn: log_in_user(conn, user)}
  end

  test "the page title carries a Wedding Planner suffix, not the Phoenix scaffold's", %{
    conn: conn
  } do
    conn = get(conn, ~p"/events")
    html = html_response(conn, 200)

    document = LazyHTML.from_document(html)
    title = document |> LazyHTML.query("title") |> LazyHTML.text()

    assert title =~ "Wedding Planner"
    refute title =~ "Phoenix"
  end

  test "the header has no Phoenix logo image, only the text wordmark", %{conn: conn} do
    conn = get(conn, ~p"/events")
    html = html_response(conn, 200)

    document = LazyHTML.from_document(html)

    assert document |> LazyHTML.query("header img") |> Enum.count() == 0
    assert document |> LazyHTML.query("header") |> LazyHTML.text() =~ "Wedding Planner"
  end

  describe "app/1 width option" do
    test "without width, #main-content is the default max-w-2xl column" do
      assigns = %{flash: %{}}

      html =
        rendered_to_string(~H"""
        <Layouts.app flash={@flash}>
          <p>content</p>
        </Layouts.app>
        """)

      document = LazyHTML.from_fragment(html)

      assert document |> LazyHTML.query("#main-content.max-w-2xl") |> Enum.any?()
      refute document |> LazyHTML.query("#main-content.max-w-6xl") |> Enum.any?()
    end

    test "with width=\"wide\", #main-content is the max-w-6xl column" do
      assigns = %{flash: %{}}

      html =
        rendered_to_string(~H"""
        <Layouts.app flash={@flash} width="wide">
          <p>content</p>
        </Layouts.app>
        """)

      document = LazyHTML.from_fragment(html)

      assert document |> LazyHTML.query("#main-content.max-w-6xl") |> Enum.any?()
      refute document |> LazyHTML.query("#main-content.max-w-2xl") |> Enum.any?()
    end
  end

  describe "two-tier navigation (DR-60, task 71)" do
    test "primary entries render as direct list items in the always-inline nav row", %{
      conn: conn
    } do
      conn = get(conn, ~p"/events")
      html = html_response(conn, 200)
      document = LazyHTML.from_document(html)

      for id <-
            ~w(nav-home nav-people nav-invitations nav-headcount nav-events nav-categories nav-invoices nav-tasks) do
        assert document |> LazyHTML.query("#nav-primary > li##{id}") |> Enum.any?(),
               "expected ##{id} directly under #nav-primary (the always-inline primary row)"
      end
    end

    # Secondary entries render twice, deliberately (see `layouts.ex`'s comment): once,
    # with the canonical `nav-<id>`/`sign-out` ids, in the < md flat panel list
    # (`#nav-secondary-mobile`) — never inline in the primary row — and again, by label
    # only (no id), inside the >= md "More" `<details>` (`#nav-secondary-desktop`). A
    # closed native `<details>` unconditionally suppresses its own children's paint in
    # current Chromium regardless of a child's own `display` override, so the < md
    # "always visible once the panel is open" copy cannot live inside it.
    test "secondary entries and sign out sit in the mobile panel's flat list, not inline in the primary row",
         %{conn: conn} do
      conn = get(conn, ~p"/events")
      html = html_response(conn, 200)
      document = LazyHTML.from_document(html)

      for id <- ~w(nav-activity nav-enrollment-links nav-devices nav-settings) do
        refute document |> LazyHTML.query("#nav-primary > li##{id}") |> Enum.any?(),
               "##{id} must not be a direct child of the primary row's <ul>"

        assert document |> LazyHTML.query("#nav-secondary-mobile > li##{id}") |> Enum.any?(),
               "expected ##{id} in the mobile panel's flat secondary list"
      end

      assert document |> LazyHTML.query("#nav-secondary-mobile #sign-out") |> Enum.any?()
      refute document |> LazyHTML.query("#nav-primary #sign-out") |> Enum.any?()
    end

    test "the >= md \"More\" disclosure also carries every secondary label and sign out", %{
      conn: conn
    } do
      conn = get(conn, ~p"/events")
      html = html_response(conn, 200)
      document = LazyHTML.from_document(html)

      desktop_text = document |> LazyHTML.query("#nav-secondary-desktop") |> LazyHTML.text()

      for label <- ["Activity", "Enrollment", "Devices", "Settings", "Sign out"] do
        assert desktop_text =~ label
      end
    end

    # Fail-proof (c): dropping the tier split (rendering every entry, including the
    # secondary ones, straight into the primary row's <ul>) makes this fail.
    test "fail-proof: every secondary id is reachable only through the mobile panel's flat list",
         %{
           conn: conn
         } do
      conn = get(conn, ~p"/events")
      html = html_response(conn, 200)
      document = LazyHTML.from_document(html)

      primary_row_ids =
        document
        |> LazyHTML.query("#nav-primary > li")
        |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))

      assert primary_row_ids ==
               ~w(nav-home nav-people nav-invitations nav-headcount nav-events nav-categories nav-invoices nav-tasks)
    end

    test "the mobile Menu toggle is a real button, keyboard-accessible, and starts closed", %{
      conn: conn
    } do
      conn = get(conn, ~p"/events")
      html = html_response(conn, 200)
      document = LazyHTML.from_document(html)

      toggle = document |> LazyHTML.query("button#menu-toggle")
      assert Enum.any?(toggle)
      assert LazyHTML.attribute(toggle, "type") == ["button"]
      assert LazyHTML.attribute(toggle, "aria-expanded") == ["false"]
      assert LazyHTML.attribute(toggle, "aria-controls") == ["main-nav"]

      [nav_class] = document |> LazyHTML.query("#main-nav") |> LazyHTML.attribute("class")
      assert "hidden" in String.split(nav_class)
    end

    test "the signed-out /login page still renders without breaking on the new nav markup" do
      conn = build_conn() |> get(~p"/login")
      html = html_response(conn, 200)

      document = LazyHTML.from_document(html)
      assert document |> LazyHTML.query("#main-nav") |> Enum.any?()
      refute document |> LazyHTML.query("#sign-out") |> Enum.any?()
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
