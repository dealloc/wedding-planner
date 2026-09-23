defmodule WeddingPlannerWeb.SessionControllerTest do
  @moduledoc """
  `WeddingPlannerWeb.SessionController` — the plain-`conn` bridge `LoginLive`'s hidden
  `phx-trigger-action` form posts to, and the counterpart sign-out action. `create/2`'s
  happy path (a real ceremony, end to end) is covered by `LoginLiveTest`; this file
  exercises the controller's own edges directly, plus sign-out's socket-disconnect
  behaviour.

  `async: false` — see `WeddingPlanner.Accounts.SessionsTest`'s note on a pre-existing
  "database busy" flake under this repo's default test concurrency.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  alias WeddingPlanner.Accounts.Sessions
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Repo
  alias WeddingPlannerWeb.UserAuth

  describe "create/2" do
    test "an unknown token is refused, no cookie is set", %{conn: conn} do
      bogus = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      conn = post(conn, ~p"/session", %{"token" => bogus, "return_to" => "/home"})

      assert redirected_to(conn) == "/login"
      refute get_session(conn, "user_session_token")
    end

    test "a missing token is refused", %{conn: conn} do
      conn = post(conn, ~p"/session", %{"return_to" => "/home"})

      assert redirected_to(conn) == "/login"
    end

    test "an external return_to is ignored even though the token is valid", %{conn: conn} do
      user = insert_user!("Wannes")
      {:ok, _session, token} = Sessions.create_session(user, nil)
      encoded = Base.url_encode64(token, padding: false)

      conn =
        post(conn, ~p"/session", %{
          "token" => encoded,
          "return_to" => "https://evil.example/steal"
        })

      assert redirected_to(conn) == "/home"
    end
  end

  describe "delete/2 (sign-out)" do
    test "clears the session so a follow-up request is redirected to login", %{conn: conn} do
      user = insert_user!("Wannes")
      conn = log_in_user(conn, user)

      conn = delete(conn, ~p"/session")
      assert redirected_to(conn) == "/login"

      conn = conn |> recycle() |> get(~p"/home")
      assert redirected_to(conn) == "/login?return_to=%2Fhome"
    end

    test "removes the underlying session row", %{conn: conn} do
      user = insert_user!("Wannes")
      {:ok, _session, token} = Sessions.create_session(user, nil)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session("user_session_token", token)
        |> delete(~p"/session")

      assert redirected_to(conn) == "/login"
      assert Sessions.fetch_by_token(token) == :error
    end

    test "broadcasts \"disconnect\" on the session's live_socket_id, so open LiveViews for it drop",
         %{conn: conn} do
      user = insert_user!("Wannes")
      conn = log_in_user(conn, user)
      live_socket_id = get_session(conn, "live_socket_id")
      assert live_socket_id

      # Phoenix's own socket transport is what actually disconnects a mounted LiveView
      # subscribed to its own `socket.id` on this broadcast (confirmed live end to end in
      # the manual browser run) — subscribing directly here, the way phx.gen.auth's own
      # generated test does, proves the *controller* sends the right broadcast without
      # depending on `Phoenix.LiveViewTest`'s internal channel wiring.
      Phoenix.PubSub.subscribe(WeddingPlanner.PubSub, live_socket_id)

      delete(conn, ~p"/session")

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^live_socket_id}
    end

    test "signing out is a harmless no-op when nothing was signed in", %{conn: conn} do
      conn = delete(conn, ~p"/session")
      assert redirected_to(conn) == "/login"
    end
  end

  describe "live_socket_id/1" do
    test "is derived from the token, not guessable from the user id", %{conn: _conn} do
      token = :crypto.strong_rand_bytes(32)
      id = UserAuth.live_socket_id(token)

      assert id == "user_sessions:" <> Base.url_encode64(token, padding: false)
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
