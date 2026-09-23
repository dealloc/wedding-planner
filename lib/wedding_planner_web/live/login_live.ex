defmodule WeddingPlannerWeb.Live.LoginLive do
  @moduledoc """
  The passkey login screen (`AUTH-01`, `AUTH-02`,
  `.claude/design/ui-decisions.md` §3: "One button, 'Sign in with passkey' — no password
  field, no username field. That absence *is* the screen; nothing else needed.").

  Usernameless: clicking the one button starts `WeddingPlanner.Accounts.WebAuthn`'s
  authentication ceremony with no `allowCredentials`, so the authenticator offers
  whatever passkeys it holds for this relying party and the server resolves the user from
  the returned `userHandle`.

  ## Establishing the session from a LiveView

  The whole ceremony runs here, in this process — the `%Wax.Challenge{}` lives in a
  socket assign and is discarded after one `finish_authentication/3` attempt, per
  `WebAuthn`'s moduledoc. On success this LiveView also creates the
  `WeddingPlanner.Accounts.UserSession` row directly (`Sessions.create_session/3`) — but a
  LiveView mounted over a socket has no `Plug.Conn` of its own, so it cannot
  `put_session/3` a real cookie.

  The bridge is the hidden `#login-session-form`: `phx-trigger-action` (Phoenix's
  documented mechanism for exactly this — "verify client-side over the socket, submit for
  real over HTTP once verified") submits it as a genuine browser POST to
  `WeddingPlannerWeb.SessionController.create/2` the moment `@trigger_submit` flips to
  `true`, carrying the already-created session's token (base64url, since a `<form>` field
  has to be text) and the sanitised `return_to`. That controller — which does have a
  `conn` — is what actually sets the cookie.

  ## `return_to`

  `WeddingPlannerWeb.UserAuth`'s plug is what captures `return_to` (it has a real
  `conn.request_path`; a LiveView `mount/3` does not — see that module's moduledoc), as a
  query parameter on the `/login` URL it redirects to. This LiveView only ever narrows
  that value further, through `UserAuth.safe_return_to/1` — both on the way in
  (`mount/3`) and again in `SessionController.create/2`, since a value that crossed the
  client boundary through the hidden form is not trusted just because this app rendered
  it.
  """
  use WeddingPlannerWeb, :live_view

  alias WeddingPlanner.Accounts.Setup
  alias WeddingPlanner.Accounts.Sessions
  alias WeddingPlanner.Accounts.WebAuthn
  alias WeddingPlannerWeb.Live.PasskeyCeremony
  alias WeddingPlannerWeb.UserAuth

  @impl true
  def mount(params, _session, socket) do
    if Setup.any_user?() do
      socket =
        socket
        |> assign(:page_title, "Sign in")
        |> assign(:state, :form)
        |> assign(:challenge, nil)
        |> assign(:return_to, UserAuth.safe_return_to(params["return_to"]))
        |> assign(:session_token, nil)
        |> assign(:trigger_submit, false)

      {:ok, socket}
    else
      # AUTH-03, normative example A1: no users exist, so no passkey can ever
      # authenticate here — only the setup flow is reachable.
      {:ok, redirect(socket, to: ~p"/setup")}
    end
  end

  @impl true
  def handle_event("start_login", _params, socket) do
    {challenge, options} = WebAuthn.begin_authentication()

    socket =
      socket
      |> assign(:state, :ceremony)
      |> assign(:challenge, challenge)
      |> push_event("passkey:get", options)

    {:noreply, socket}
  end

  @impl true
  def handle_event("passkey:authentication-success", params, socket) do
    if socket.assigns.state == :ceremony do
      finish_login(socket, params)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("passkey:cancelled", _params, socket) do
    if socket.assigns.state == :ceremony do
      {:noreply, reset(socket, nil)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("passkey:error", %{"message" => message}, socket) do
    if socket.assigns.state == :ceremony do
      {:noreply, reset(socket, message)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("passkey:unsupported", _params, socket) do
    # Per `PasskeyCeremony`'s contract this can fire on mount regardless of state, and
    # again defensively mid-ceremony — `reset/2` is safe either way.
    {:noreply, reset(socket, "This browser does not support passkeys.")}
  end

  defp finish_login(socket, params) do
    challenge = socket.assigns.challenge

    case WebAuthn.finish_authentication(challenge, params) do
      {:ok, %{user: user, passkey: passkey}} ->
        {:ok, _session, token} = Sessions.create_session(user, passkey)

        socket =
          socket
          # Moves state away from :ceremony so a replayed
          # "passkey:authentication-success" (the challenge's single-use guarantee) finds
          # no live ceremony to continue and is dropped by the `handle_event` guard below
          # — never reaches `finish_authentication/3` a second time with a discarded
          # (now `nil`) challenge.
          |> assign(:state, :redirecting)
          |> assign(:challenge, nil)
          |> assign(:session_token, Base.url_encode64(token, padding: false))
          |> assign(:trigger_submit, true)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, reset(socket, "Sign-in failed. Please try again.")}
    end
  end

  # Ends an in-progress (or not-yet-started) ceremony and returns to the idle `:form`
  # state. Unlike `SetupLive`, there is no provisional row to clean up — a failed
  # `finish_authentication/3` persists nothing.
  defp reset(socket, flash_message) do
    socket =
      socket
      |> assign(:state, :form)
      |> assign(:challenge, nil)

    if flash_message, do: put_flash(socket, :error, flash_message), else: socket
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div
        id="login-card"
        class="mx-auto max-w-md rounded-field border border-line bg-surface-raised p-6 text-center"
      >
        <h1 class="text-lg font-semibold text-ink">Sign in</h1>
        <p class="mt-2 text-sm text-ink-soft">
          <%= cond do %>
            <% @state == :ceremony -> %>
              Follow your browser's prompt&hellip;
            <% @state == :redirecting -> %>
              Signed in &mdash; taking you there&hellip;
            <% true -> %>
              No password, no username — just your passkey.
          <% end %>
        </p>

        <div :if={@state == :form} class="mt-4">
          <.button variant="primary" id="login-button" phx-click="start_login">
            Sign in with passkey
          </.button>
        </div>
      </div>

      <.form
        for={nil}
        id="login-session-form"
        action={~p"/session"}
        method="post"
        phx-trigger-action={@trigger_submit}
      >
        <input type="hidden" name="token" value={@session_token} />
        <input type="hidden" name="return_to" value={@return_to} />
      </.form>

      <PasskeyCeremony.ceremony id="login-passkey-ceremony" />
    </Layouts.app>
    """
  end
end
