defmodule WeddingPlannerWeb.SessionController do
  @moduledoc """
  The only two things a plain controller needs to do for `AUTH-01`/`AUTH-10`: write the
  session cookie, and clear it.

  `create/2` is a bridge, not a login endpoint of its own. The actual WebAuthn ceremony
  runs inside `WeddingPlannerWeb.Live.LoginLive` (a LiveView, over a socket, no `conn`)
  and already creates the `WeddingPlanner.Accounts.UserSession` row by the time this
  action runs; `LoginLive`'s hidden `phx-trigger-action` form is what turns that into a
  real browser POST this controller can `put_session/3` from. `token` and `return_to` are
  re-validated here rather than trusted, even though this app rendered the form itself —
  see `WeddingPlannerWeb.UserAuth`'s moduledoc.
  """
  use WeddingPlannerWeb, :controller

  alias WeddingPlanner.Accounts.Sessions
  alias WeddingPlannerWeb.UserAuth

  def create(conn, params) do
    with token when is_binary(token) <- Map.get(params, "token"),
         {:ok, raw_token} <- Base.url_decode64(token, padding: false),
         {:ok, _session} <- Sessions.fetch_by_token(raw_token) do
      conn
      |> configure_session(renew: true)
      |> clear_session()
      |> put_session("user_session_token", raw_token)
      |> put_session("live_socket_id", UserAuth.live_socket_id(raw_token))
      |> redirect(to: UserAuth.safe_return_to(Map.get(params, "return_to")))
    else
      _ -> redirect(conn, to: ~p"/login")
    end
  end

  def delete(conn, _params) do
    if token = get_session(conn, "user_session_token") do
      Sessions.delete_session(token)
    end

    if live_socket_id = get_session(conn, "live_socket_id") do
      WeddingPlannerWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> redirect(to: ~p"/login")
  end
end
