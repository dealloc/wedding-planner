defmodule WeddingPlannerWeb.UserAuthTest do
  @moduledoc """
  `AUTH-01`'s gate itself: the plug that guards protected routes (controller and the
  authenticated `live_session` alike), `return_to` capture/sanitisation, and the
  `on_mount` fallback. `test/wedding_planner_web/live/login_live_test.exs` and
  `test/wedding_planner_web/controllers/session_controller_test.exs` cover the rest of
  the login/sign-out round trip end to end; this file isolates the gate's own rules.

  `async: false` — see `WeddingPlanner.Accounts.SessionsTest`'s note on a pre-existing
  "database busy" flake under this repo's default test concurrency.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Repo
  alias WeddingPlannerWeb.UserAuth

  describe "protected routes" do
    test "an unauthenticated request to /home redirects to /login with return_to", %{
      conn: conn
    } do
      conn = get(conn, ~p"/home")

      assert redirected_to(conn) == "/login?return_to=%2Fhome"
    end

    test "an authenticated request to /home succeeds", %{conn: conn} do
      user = insert_user!("Wannes")
      conn = conn |> log_in_user(user) |> get(~p"/home")

      assert html_response(conn, 200) =~ "Wedding Planner"
    end

    test "an expired session is rejected, same as no session", %{conn: conn} do
      user = insert_user!("Wannes")
      expired_start = DateTime.add(DateTime.utc_now(), -31, :day)

      conn = conn |> log_in_user(user, nil, now: expired_start) |> get(~p"/home")

      assert redirected_to(conn) == "/login?return_to=%2Fhome"
    end
  end

  describe "the three public routes are reachable unauthenticated (AUTH-01)" do
    test "/login" do
      conn = build_conn()
      assert {:ok, _view, _html} = live(conn, ~p"/login")
    end

    test "/setup" do
      conn = build_conn()
      assert {:ok, _view, _html} = live(conn, ~p"/setup")
    end
  end

  describe "return_to" do
    test "a same-site path round-trips through the redirect to /login", %{conn: conn} do
      conn = get(conn, ~p"/home?filter=overdue")

      assert redirected_to(conn) == "/login?return_to=%2Fhome%3Ffilter%3Doverdue"
    end
  end

  describe "safe_return_to/1" do
    test "keeps a same-site relative path" do
      assert UserAuth.safe_return_to("/home") == "/home"
      assert UserAuth.safe_return_to("/home?tab=budget") == "/home?tab=budget"
    end

    test "rejects an absolute URL" do
      assert UserAuth.safe_return_to("https://evil.example/phish") == "/home"
      assert UserAuth.safe_return_to("http://evil.example") == "/home"
    end

    test "rejects a protocol-relative //host URL" do
      assert UserAuth.safe_return_to("//evil.example") == "/home"
    end

    test "rejects a path that doesn't start with /" do
      assert UserAuth.safe_return_to("evil.example") == "/home"
    end

    test "falls back to /home for nil or a non-binary" do
      assert UserAuth.safe_return_to(nil) == "/home"
      assert UserAuth.safe_return_to(123) == "/home"
    end
  end

  describe "on_mount :require_authenticated" do
    test "halts and redirects to /login without a session token" do
      assert {:halt, socket} =
               UserAuth.on_mount(:require_authenticated, %{}, %{}, %Phoenix.LiveView.Socket{})

      assert socket.redirected == {:redirect, %{status: 302, to: "/login"}}
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
