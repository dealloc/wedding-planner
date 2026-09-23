defmodule WeddingPlannerWeb.UserAuth do
  @moduledoc """
  `AUTH-01`'s gate: resolves the session cookie into a `WeddingPlanner.Accounts.Scope`,
  guards protected routes, and carries a same-site `return_to` back through login.

  Two layers, per the pattern `Phoenix.LiveView.on_mount/1`'s own docs recommend for a
  `live_session` that needs real authentication (not just an assign):

    * `require_authenticated_user/2` — a conn plug, `pipe_through`'d in front of both
      plain controller routes and the authenticated `live_session`. It is what actually
      captures `return_to`: it has a real `conn.request_path`, which a LiveView `mount/3`
      does not (see `WeddingPlannerWeb.Live.LoginLive`'s moduledoc). It runs on every
      *disconnected* HTTP mount, i.e. the first load of any protected page.
    * `on_mount({__MODULE__, :require_authenticated}, ...)` — defense in depth for the
      cases the plug can't reach: a live navigation between routes in the same
      `live_session`, or the socket reconnecting after the session has since expired.
      Same-origin, so `assign_new/3` picks up the scope the plug already computed for the
      very first mount instead of re-querying (see `mount_current_scope/2`).

  `safe_return_to/1` is the single point that decides whether a `return_to` is safe to
  redirect to — same-site relative paths only, never `//host` or an absolute URL. Both
  the plug (building the redirect-to-login target) and `WeddingPlannerWeb.SessionController`
  (building the redirect-after-login target) go through it, since a `return_to` that
  crossed the client boundary — even inside our own rendered HTML, per `LoginLive`'s
  hidden bridge form — is not trusted just because we rendered it.
  """

  use WeddingPlannerWeb, :verified_routes

  import Plug.Conn

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.Sessions

  @session_token_key "user_session_token"

  ## Plug

  @doc false
  def init(action), do: action

  @doc false
  def call(conn, :require_authenticated_user), do: require_authenticated_user(conn, [])

  @doc """
  Plug for routes that require an authenticated user (`AUTH-01`). Resolves the session
  cookie, extending its sliding window on success (`AUTH-10`). On failure, redirects to
  `/login` with `return_to` set to the request currently being made, so a successful
  login lands back here.
  """
  def require_authenticated_user(conn, _opts) do
    conn = assign_current_scope(conn)

    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> Phoenix.Controller.redirect(to: login_path(conn))
      |> halt()
    end
  end

  defp assign_current_scope(conn) do
    user =
      case get_session(conn, @session_token_key) do
        token when is_binary(token) ->
          case Sessions.fetch_by_token(token) do
            {:ok, session} -> session.user
            :error -> nil
          end

        _ ->
          nil
      end

    assign(conn, :current_scope, Scope.for_user(user))
  end

  defp login_path(conn) do
    return_to = conn.request_path <> query_suffix(conn.query_string)
    ~p"/login?#{[return_to: return_to]}"
  end

  defp query_suffix(""), do: ""
  defp query_suffix(query_string), do: "?" <> query_string

  ## on_mount

  @doc """
  `on_mount` hook for the authenticated `live_session` — see the moduledoc for why this
  exists alongside, not instead of, the plug.
  """
  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      user =
        case session[@session_token_key] do
          token when is_binary(token) ->
            case Sessions.fetch_by_token(token) do
              {:ok, user_session} -> user_session.user
              :error -> nil
            end

          _ ->
            nil
        end

      Scope.for_user(user)
    end)
  end

  ## return_to

  @doc """
  Restricts a candidate `return_to` to a same-site relative path — never an absolute URL
  or a protocol-relative `//host` one (an open-redirect vector), falling back to `/home`
  for anything else, including a missing value.
  """
  @spec safe_return_to(term()) :: String.t()
  def safe_return_to(path) when is_binary(path) do
    uri = URI.parse(path)

    if is_nil(uri.scheme) and is_nil(uri.host) and String.starts_with?(path, "/") and
         not String.starts_with?(path, "//") do
      path
    else
      ~p"/home"
    end
  end

  def safe_return_to(_), do: ~p"/home"

  ## live_socket_id

  @doc """
  The PubSub topic a session's live sockets are subscribed to (via the `"live_socket_id"`
  session key `Phoenix.LiveView.Socket` reads automatically), so sign-out can disconnect
  them with `Endpoint.broadcast(live_socket_id, "disconnect", %{})`.
  """
  @spec live_socket_id(binary()) :: String.t()
  def live_socket_id(token) when is_binary(token) do
    "user_sessions:" <> Base.url_encode64(token, padding: false)
  end
end
