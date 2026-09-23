defmodule WeddingPlannerWeb.Live.SetupLive do
  @moduledoc """
  The one-time bootstrap setup screen (`AUTH-03`, `D-33`, normative example `A1`).

  Reachable only while zero users exist — `mount/3` re-checks
  `WeddingPlanner.Accounts.Setup.any_user?/0` on every mount (not a flag) and raises
  `WeddingPlannerWeb.NotFoundError` the moment that stops being true, so the route
  behaves as though it never existed once the first user is created, from anywhere.

  Three renderable states before that (`@state`):

    * `:unavailable` — no user exists, but no usable setup token is configured (unset, or
      shorter than `AUTH-03`'s 32-character minimum). A plain explanatory page; there is
      nothing to submit.
    * `:form` — a token is configured; the setup card (`.claude/design/ui-decisions.md`
      §3: a single card, no separate "now add a passkey" step).
    * `:ceremony` — the token was correct and the first user has already been created;
      waiting on the browser's passkey prompt (`WeddingPlannerWeb.Live.PasskeyCeremony`).
    * `:completed` — the passkey registered; nothing left to do on this screen (session/
      login is task 15, not this one).

  ## The provisional user (`DR-22`)

  The WebAuthn user handle is `users.id` (see `WeddingPlanner.Accounts.WebAuthn`), so the
  row must exist *before* `begin_registration/1` can run. Concretely: a correct token
  creates the user first via `WeddingPlanner.Accounts.Setup.create_first_user/1`, then
  starts the ceremony against it. If the ceremony does not end in a stored passkey, the
  user is deleted and the form is shown again — implemented as:

    * **cancel / client error / unsupported browser / a `finish_registration` failure**
      (all handled here, in this process, while it is still alive) — this LiveView
      deletes the user itself and tells the guard (see below) to stand down.
    * **this LiveView process dies first** (tab closed, navigated away, crashed) — a
      `WeddingPlanner.Accounts.SetupGuard`, started alongside the user and monitoring
      this process, deletes it instead. See that module's moduledoc for why a plain
      `terminate/2` callback here would not be reliable enough on its own.

  Nothing is written to the activity log (`AUTH-11`) until `finish_registration/4`
  actually returns `{:ok, passkey}` — logging any earlier would create a row referencing
  a user that might still be deleted, and `users`' foreign keys are `on_delete:
  :restrict`, which would then block that very delete.

  The setup token field is named `setup_token` so `config :phoenix, :filter_parameters`
  (which matches on substring, not exact key) redacts it from both Phoenix's and
  LiveView's request/event logs; the token is also never written back into the form
  after a failed attempt (`AUTH-03`), even though the display name and passkey name are
  kept so the user does not have to retype them.
  """
  use WeddingPlannerWeb, :live_view

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.Setup
  alias WeddingPlanner.Accounts.SetupGuard
  alias WeddingPlanner.Accounts.WebAuthn
  alias WeddingPlanner.Log
  alias WeddingPlanner.Repo
  alias WeddingPlannerWeb.Live.PasskeyCeremony
  alias WeddingPlannerWeb.NotFoundError

  @setup_fields %{setup_token: :string, display_name: :string, passkey_name: :string}

  @impl true
  def mount(_params, _session, socket) do
    if Setup.any_user?() do
      raise NotFoundError
    end

    state = if Setup.token_configured?(), do: :form, else: :unavailable

    socket =
      socket
      |> assign(:page_title, "Setup")
      |> assign(:state, state)
      |> assign(:display_name, nil)
      |> assign(:passkey_name, nil)
      |> assign(:user, nil)
      |> assign(:challenge, nil)
      |> assign(:setup_guard, nil)
      |> assign(:form, blank_form())

    {:ok, socket}
  end

  @impl true
  def handle_event("start_setup", %{"setup" => params}, socket) do
    if socket.assigns.state == :form do
      handle_submission(socket, params)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("passkey:registration-success", params, socket) do
    if socket.assigns.state == :ceremony do
      handle_registration(socket, params)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("passkey:cancelled", _params, socket) do
    if socket.assigns.state == :ceremony do
      {:noreply, abort_ceremony(socket, nil)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("passkey:error", %{"message" => message}, socket) do
    if socket.assigns.state == :ceremony do
      {:noreply, abort_ceremony(socket, message)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("passkey:unsupported", _params, socket) do
    # Fires once on every mount regardless of ceremony state, and again defensively if a
    # ceremony is somehow triggered afterwards (`PasskeyCeremony`'s contract) — safe to
    # handle unconditionally: `abort_ceremony/2` is a no-op delete when there is no
    # provisional user yet.
    {:noreply, abort_ceremony(socket, "This browser does not support passkeys.")}
  end

  defp handle_submission(socket, params) do
    changeset = params |> setup_changeset() |> Map.put(:action, :validate)

    cond do
      not changeset.valid? ->
        {:noreply, assign(socket, :form, to_setup_form(changeset))}

      not Setup.valid_token?(Ecto.Changeset.get_field(changeset, :setup_token)) ->
        changeset =
          changeset
          |> Ecto.Changeset.add_error(:setup_token, "is incorrect")
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :form, to_setup_form(changeset))}

      true ->
        start_ceremony(socket, changeset)
    end
  end

  defp start_ceremony(socket, changeset) do
    display_name = Ecto.Changeset.get_field(changeset, :display_name)
    passkey_name = Ecto.Changeset.get_field(changeset, :passkey_name)

    case Setup.create_first_user(%{"display_name" => display_name}) do
      {:ok, user} ->
        {challenge, options} = WebAuthn.begin_registration(user)
        {:ok, guard} = SetupGuard.start(owner: self(), user_id: user.id)

        socket =
          socket
          |> assign(:state, :ceremony)
          |> assign(:display_name, display_name)
          |> assign(:passkey_name, passkey_name)
          |> assign(:user, user)
          |> assign(:challenge, challenge)
          |> assign(:setup_guard, guard)
          |> push_event("passkey:create", options)

        {:noreply, socket}

      {:error, :already_exists} ->
        # Someone else's attempt won the race (DR-22) between our own mount and this
        # submit. Force a fresh mount rather than inventing a bespoke "already set up"
        # screen — it re-runs the same `any_user?/0` check as every other mount and
        # renders the same 404 anyone hitting `/setup` now would see.
        {:noreply, push_navigate(socket, to: ~p"/setup")}

      {:error, %Ecto.Changeset{}} ->
        # Unreachable in practice — `setup_changeset/1`'s own `display_name` bounds match
        # `User.changeset/2`'s exactly — but handled rather than crashing on a changeset
        # shaped for `User`, not the `:setup` form, which `to_setup_form/1` cannot reuse.
        socket =
          socket
          |> put_flash(
            :error,
            "Could not create the account. Please check the details and try again."
          )
          |> assign(
            :form,
            to_setup_form(setup_changeset(retry_params(display_name, passkey_name)))
          )

        {:noreply, socket}
    end
  end

  defp handle_registration(socket, params) do
    %{user: user, challenge: challenge, passkey_name: passkey_name, setup_guard: guard} =
      socket.assigns

    case WebAuthn.finish_registration(user, challenge, params, name: passkey_name) do
      {:ok, passkey} ->
        Log.entry(
          Scope.for_user(user),
          {:passkey, passkey.id},
          "#{user.display_name} registered passkey '#{passkey.name}'"
        )

        SetupGuard.disarm(guard)

        socket =
          socket
          |> assign(:state, :completed)
          |> assign(:challenge, nil)
          |> assign(:setup_guard, nil)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, abort_ceremony(socket, "Passkey registration failed. Please try again.")}
    end
  end

  # Ends an in-progress (or not-yet-started) ceremony: deletes the provisional user (if
  # any), tells the guard (if any) to stand down, and returns to a fresh `:form` — the
  # display name and passkey name are kept so they don't have to be retyped, the token
  # never is.
  defp abort_ceremony(socket, flash_message) do
    %{user: user, setup_guard: guard, display_name: display_name, passkey_name: passkey_name} =
      socket.assigns

    if user, do: Repo.delete(user)
    if guard, do: SetupGuard.disarm(guard)

    socket =
      socket
      |> assign(:state, :form)
      |> assign(:user, nil)
      |> assign(:challenge, nil)
      |> assign(:setup_guard, nil)
      |> assign(:form, to_setup_form(setup_changeset(retry_params(display_name, passkey_name))))

    if flash_message, do: put_flash(socket, :error, flash_message), else: socket
  end

  defp retry_params(display_name, passkey_name) do
    %{"display_name" => display_name, "passkey_name" => passkey_name}
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp blank_form, do: to_setup_form(setup_changeset(%{}))

  defp to_setup_form(changeset) do
    # `AUTH-03`: never echo the setup token back, successful attempt or not.
    changeset
    |> Ecto.Changeset.put_change(:setup_token, "")
    |> to_form(as: :setup)
  end

  defp setup_changeset(params) do
    {%{}, @setup_fields}
    |> Ecto.Changeset.cast(params, Map.keys(@setup_fields))
    |> Ecto.Changeset.validate_required(Map.keys(@setup_fields))
    |> Ecto.Changeset.validate_length(:display_name, min: 1, max: 100)
    |> Ecto.Changeset.validate_length(:passkey_name, min: 1, max: 100)
  end

  @impl true
  def render(%{state: :unavailable} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div
        id="setup-unavailable"
        class="mx-auto max-w-md rounded-field border border-line bg-surface-raised p-6 text-center"
      >
        <h1 class="text-lg font-semibold text-ink">Setup is not available</h1>
        <p class="mt-2 text-sm text-ink-soft">
          No users exist yet, but no setup token is configured. Ask whoever runs this
          server to set the <code class="text-ink">SETUP_TOKEN</code>
          environment variable and restart.
        </p>
      </div>
    </Layouts.app>
    """
  end

  def render(%{state: :form} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div
        id="setup-form-card"
        class="mx-auto max-w-md rounded-field border border-line bg-surface-raised p-6"
      >
        <h1 class="text-lg font-semibold text-ink">No users exist yet</h1>
        <p class="mt-1 text-sm text-ink-soft">
          Enter the setup token to create the first account and register its passkey.
        </p>

        <.form
          for={@form}
          id="setup-form"
          phx-submit="start_setup"
          class="mt-4 flex flex-col gap-4"
        >
          <.input
            field={@form[:setup_token]}
            type="password"
            label="Setup token"
            autocomplete="off"
            phx-debounce="blur"
          />
          <.input field={@form[:display_name]} type="text" label="Your name" />
          <.input
            field={@form[:passkey_name]}
            type="text"
            label="Passkey name"
            placeholder="e.g. Wannes' laptop"
          />

          <button
            type="submit"
            id="setup-submit"
            class="mt-2 inline-flex min-h-11 items-center justify-center rounded-field bg-accent px-4 text-sm font-semibold text-white shadow-sm transition-all duration-150 ease-out hover:opacity-90 active:scale-[0.98] cursor-pointer"
          >
            Create account
          </button>
        </.form>
      </div>

      <PasskeyCeremony.ceremony id="setup-passkey-ceremony" />
    </Layouts.app>
    """
  end

  def render(%{state: :ceremony} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div
        id="setup-ceremony-card"
        class="mx-auto max-w-md rounded-field border border-line bg-surface-raised p-6 text-center"
      >
        <h1 class="text-lg font-semibold text-ink">Follow your browser's prompt</h1>
        <p class="mt-2 text-sm text-ink-soft">
          Registering "{@passkey_name}" for {@display_name}&hellip;
        </p>
      </div>

      <PasskeyCeremony.ceremony id="setup-passkey-ceremony" />
    </Layouts.app>
    """
  end

  def render(%{state: :completed} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div
        id="setup-completed"
        class="mx-auto max-w-md rounded-field border border-line bg-surface-raised p-6 text-center"
      >
        <.icon name="hero-check-circle" class="mx-auto size-8 text-good" />
        <h1 class="mt-2 text-lg font-semibold text-ink">You're all set, {@display_name}</h1>
        <p class="mt-2 text-sm text-ink-soft">
          "{@passkey_name}" is registered.
        </p>
        <.link
          navigate={~p"/login"}
          id="setup-completed-sign-in"
          class="mt-4 inline-flex min-h-11 items-center justify-center rounded-field bg-accent px-4 text-sm font-semibold text-white shadow-sm transition-all duration-150 ease-out hover:opacity-90 active:scale-[0.98]"
        >
          Sign in
        </.link>
      </div>
    </Layouts.app>
    """
  end
end
