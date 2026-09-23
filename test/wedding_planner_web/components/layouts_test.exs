defmodule WeddingPlannerWeb.LayoutsTest do
  @moduledoc """
  The root layout and app shell: the app has no public surface and is not the Phoenix
  scaffold — the page `<title>` must not carry the generator's "· Phoenix Framework"
  suffix, and the header must not show the scaffold's Phoenix logo image (removed in
  favour of a plain text wordmark, per `.claude/design/ui-decisions.md` §2 — no logo
  asset is specified there).
  """
  use WeddingPlannerWeb.ConnCase, async: true

  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Repo

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

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
