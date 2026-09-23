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

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
