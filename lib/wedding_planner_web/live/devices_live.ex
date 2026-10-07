defmodule WeddingPlannerWeb.Live.DevicesLive do
  @moduledoc """
  The `/devices` screen (task 17; `docs/modules/authentication.md` `AUTH-08`, `AUTH-11`;
  `.claude/design/ui-decisions.md` §3, point 3): each user sees and manages **their
  own** registered passkeys — user-editable name, registration date and last-used date
  — and can revoke any of them except their last one.

  ## Scoping (`AUTH-08`: "their own passkeys only")

  Every read and write here goes through `WeddingPlanner.Accounts.Passkeys`, scoped to
  `@current_scope.user` throughout: `list_for_user/1` only ever lists this user's own
  rows, and `get_own/2` — the one lookup a client-supplied id goes through before any
  mutation — returns `nil` for an id that exists but belongs to someone else, exactly as
  if it did not exist. A crafted event carrying another user's passkey id therefore does
  nothing, silently, the same as one carrying a nonexistent id.

  ## The last-passkey guard (`AUTH-08`)

  `@passkey_count` (a plain assign, not derived from the stream — streams don't support
  counting, `AGENTS.md`) drives the revoke control's `disabled` state and its inline
  explanation. The same guard is enforced again, atomically, by
  `WeddingPlanner.Accounts.Passkeys.revoke/2` itself (see that module's moduledoc), so a
  client that bypasses the disabled attribute — a crafted `revoke_confirmed` event — is
  still refused server-side.

  ## Renaming (`AUTH-08` "user-editable name")

  Each row owns its own tiny form (`@forms`, `%{passkey_id => Phoenix.HTML.Form.t()}`,
  every one built with `to_form/2` — never a raw map or changeset directly in the
  template, per `AGENTS.md`), saved when the field loses focus or on Enter
  (`phx-debounce="blur"` + `phx-submit`) — never per keystroke, which wrote one activity
  entry per character typed. No confirmation (renaming isn't destructive). Kept as a parallel assign
  alongside the `:passkeys` stream, the same pattern
  `WeddingPlannerWeb.Live.ActivityLogLive` uses for `@children`/`@children_counts`,
  since a stream item alone can't carry a field's validation errors.

  ## Revocation (`XC-40`, `DR-24`)

  Revoking asks for confirmation via
  `WeddingPlannerWeb.CoreComponents.destructive_confirm/1` (task 5) — the only
  confirmation chrome this screen has; renaming needs none. On confirm,
  `WeddingPlanner.Accounts.Passkeys.revoke/2` deletes every session opened by that
  passkey and returns their raw tokens (`DR-24`); this LiveView is the "web layer" that
  then disconnects each one's live sockets with the same
  `Endpoint.broadcast(live_socket_id, "disconnect", %{})` pattern
  `WeddingPlannerWeb.SessionController.delete/2` already uses for an ordinary sign-out —
  including, if the revoked passkey opened *this* very session, this socket itself.
  There is no special case for that: the broadcast doesn't know or care whether the
  topic it's disconnecting is its own. When it is, this LiveView is torn down by the
  same mechanism as any other disconnected session, and the client's automatic
  reconnect-then-reload hits `WeddingPlannerWeb.UserAuth`'s plug with no valid session
  cookie left, which redirects to `/login` — the same clean landing every other
  disconnected session already gets. No crash, and deliberately no special-cased flash:
  there is nowhere left in this process to render one by the time the redirect happens.
  """
  use WeddingPlannerWeb, :live_view

  on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

  alias WeddingPlanner.Accounts.Passkeys
  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.Users
  alias WeddingPlannerWeb.Endpoint
  alias WeddingPlannerWeb.Format
  alias WeddingPlannerWeb.UserAuth

  @impl true
  def mount(_params, _session, socket) do
    %{current_scope: scope} = socket.assigns
    passkeys = Passkeys.list_for_user(scope.user)

    socket =
      socket
      |> assign(:page_title, "Devices")
      |> assign(:passkey_count, length(passkeys))
      |> assign(:confirming_id, nil)
      |> assign(:name_form, to_form(%{"display_name" => scope.user.display_name}, as: :user))
      |> assign(:forms, build_forms(passkeys))
      |> stream(:passkeys, passkeys)

    {:ok, socket}
  end

  # AUTH-12: the user's own display name, saved explicitly (submit), never per keystroke.
  @impl true
  def handle_event("rename_self", %{"user" => %{"display_name" => name}}, socket) do
    case Users.rename_self(socket.assigns.current_scope, name) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_scope, Scope.for_user(user))
         |> assign(:name_form, to_form(%{"display_name" => user.display_name}, as: :user))
         |> put_flash(:info, "Name updated.")}

      {:error, changeset} ->
        errors = for {_field, {message, _}} <- changeset.errors, do: message

        {:noreply,
         assign(
           socket,
           :name_form,
           to_form(%{"display_name" => name},
             as: :user,
             errors: [display_name: {hd(errors), []}],
             action: :validate
           )
         )}
    end
  end

  def handle_event("rename", %{"passkey_id" => id_str, "passkey" => %{"name" => name}}, socket) do
    %{current_scope: scope} = socket.assigns
    id = String.to_integer(id_str)

    case Passkeys.get_own(scope.user, id) do
      nil ->
        {:noreply, socket}

      passkey ->
        case Passkeys.rename(scope, passkey, %{"name" => name}) do
          {:ok, renamed} ->
            socket =
              socket
              |> stream_insert(:passkeys, renamed)
              |> put_form(renamed.id, to_form(%{"name" => renamed.name}, as: :passkey))

            {:noreply, socket}

          {:error, changeset} ->
            socket =
              socket
              |> put_form(passkey.id, to_form(changeset, as: :passkey))
              # AGENTS.md: an assign that changes content *inside* a streamed item (here,
              # the row's own inline error) must be accompanied by re-inserting that
              # item, or the client never sees the patch — `@forms` lives outside the
              # `:passkeys` stream.
              |> stream_insert(:passkeys, passkey)

            {:noreply, socket}
        end
    end
  end

  @impl true
  def handle_event("confirm_revoke", %{"id" => id_str}, socket) do
    %{current_scope: scope} = socket.assigns
    id = String.to_integer(id_str)

    socket =
      socket
      |> assign(:confirming_id, id)
      |> stream_insert_passkey(scope, id)

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_revoke", _params, socket) do
    %{current_scope: scope, confirming_id: previous_id} = socket.assigns

    socket =
      socket
      |> assign(:confirming_id, nil)
      |> stream_insert_passkey(scope, previous_id)

    {:noreply, socket}
  end

  @impl true
  def handle_event("revoke_confirmed", %{"id" => id_str}, socket) do
    %{current_scope: scope} = socket.assigns
    id = String.to_integer(id_str)

    case Passkeys.get_own(scope.user, id) do
      nil ->
        {:noreply, assign(socket, :confirming_id, nil)}

      passkey ->
        case Passkeys.revoke(scope, passkey) do
          {:ok, %{passkey: revoked, session_tokens: tokens}} ->
            Enum.each(tokens, &disconnect_live_sockets/1)

            # A full reset, not a targeted `stream_delete/3`: `@passkey_count` is read by
            # *every* row (it drives each one's disabled state), so the surviving rows
            # need re-streaming too, not just the one that's gone — this dataset is a
            # single user's own passkeys, always small, so refetching is cheap (the same
            # reasoning `WeddingPlannerWeb.Live.EventsLive` documents for its own
            # small-dataset re-streams).
            remaining = Passkeys.list_for_user(scope.user)

            socket =
              socket
              |> assign(:confirming_id, nil)
              |> assign(:passkey_count, length(remaining))
              |> update(:forms, &Map.delete(&1, revoked.id))
              |> stream(:passkeys, remaining, reset: true)

            {:noreply, socket}

          {:error, :last_passkey} ->
            socket =
              socket
              |> assign(:confirming_id, nil)
              # Same "re-stream on assign change" requirement: this row's confirm panel
              # must disappear even though the passkey itself is untouched.
              |> stream_insert(:passkeys, passkey)
              |> put_flash(:error, "You can't revoke your last passkey.")

            {:noreply, socket}
        end
    end
  end

  defp disconnect_live_sockets(token) do
    Endpoint.broadcast(UserAuth.live_socket_id(token), "disconnect", %{})
  end

  defp stream_insert_passkey(socket, _scope, nil), do: socket

  defp stream_insert_passkey(socket, scope, id) do
    case Passkeys.get_own(scope.user, id) do
      nil -> socket
      passkey -> stream_insert(socket, :passkeys, passkey)
    end
  end

  defp build_forms(passkeys) do
    Map.new(passkeys, fn pk -> {pk.id, to_form(%{"name" => pk.name}, as: :passkey)} end)
  end

  defp put_form(socket, id, form) do
    update(socket, :forms, &Map.put(&1, id, form))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <WeddingPlannerWeb.Live.TimeZoneHook.probe id="devices-time-zone-probe" />

      <.header>
        Devices
        <:subtitle>Your name and the passkeys registered to your account.</:subtitle>
      </.header>

      <.form
        for={@name_form}
        id="own-name-form"
        phx-submit="rename_self"
        class="mt-6 flex flex-wrap items-end gap-3 rounded-field border border-line bg-surface-raised p-4"
      >
        <div class="min-w-56 flex-1">
          <.input
            field={@name_form[:display_name]}
            type="text"
            label="Your name"
            id="own-name"
            autocomplete="name"
          />
        </div>
        <.button variant="primary" id="own-name-submit">Save name</.button>
      </.form>

      <ul id="passkeys" phx-update="stream" class="mt-6 flex flex-col gap-4">
        <li
          id="passkeys-empty"
          class="hidden only:block rounded-field border border-dashed border-line-strong p-6 text-center text-sm text-ink-soft"
        >
          No passkeys registered.
        </li>

        <li
          :for={{dom_id, passkey} <- @streams.passkeys}
          id={dom_id}
          class="rounded-field border border-line bg-surface-raised p-4"
        >
          <.passkey_row
            passkey={passkey}
            form={@forms[passkey.id]}
            passkey_count={@passkey_count}
            confirming={@confirming_id == passkey.id}
            time_zone={@time_zone}
          />
        </li>
      </ul>
    </Layouts.app>
    """
  end

  attr :passkey, :any, required: true
  attr :form, :any, required: true
  attr :passkey_count, :integer, required: true
  attr :confirming, :boolean, required: true
  attr :time_zone, :string, default: nil

  defp passkey_row(assigns) do
    ~H"""
    <div>
      <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div class="min-w-0 flex-1">
          <.form
            for={@form}
            id={"passkey-#{@passkey.id}-rename-form"}
            phx-change="rename"
            phx-submit="rename"
          >
            <input type="hidden" name="passkey_id" value={@passkey.id} />
            <.input
              field={@form[:name]}
              type="text"
              label="Name"
              id={"passkey-#{@passkey.id}-name"}
              phx-debounce="blur"
            />
          </.form>

          <p class="mt-2 text-xs text-ink-faint">
            Registered
            <span id={"passkey-#{@passkey.id}-registered"} class="tabular-nums">
              {Format.datetime(@passkey.registered_at, @time_zone)}
            </span>
            <span aria-hidden="true">&middot;</span>
            Last used
            <span id={"passkey-#{@passkey.id}-last-used"} class="tabular-nums">
              {last_used_label(@passkey, @time_zone)}
            </span>
          </p>
        </div>

        <div class="flex shrink-0 flex-col items-end gap-1">
          <.button
            variant="destructive"
            id={"passkey-#{@passkey.id}-revoke"}
            phx-click="confirm_revoke"
            phx-value-id={@passkey.id}
            disabled={@passkey_count <= 1}
            title={
              if(@passkey_count <= 1,
                do: "You can't revoke your last passkey — register another device first.",
                else: nil
              )
            }
          >
            Revoke
          </.button>
          <p
            :if={@passkey_count <= 1}
            id={"passkey-#{@passkey.id}-last-passkey-note"}
            class="max-w-[16rem] text-right text-xs text-ink-faint"
          >
            This is your only passkey — add another device before revoking it.
          </p>
        </div>
      </div>

      <.destructive_confirm
        :if={@confirming}
        id={"passkey-#{@passkey.id}-revoke-confirm"}
        title={"Revoke '#{@passkey.name}'?"}
        body="Every session signed in with this passkey — including this one, if it's the one you used to sign in — ends immediately."
        confirm="revoke_confirmed"
        confirm_value={@passkey.id}
        cancel="cancel_revoke"
        confirm_label="Revoke"
      />
    </div>
    """
  end

  defp last_used_label(%{last_used_at: nil}, _time_zone), do: "Never"

  defp last_used_label(%{last_used_at: %DateTime{} = dt}, time_zone),
    do: Format.datetime(dt, time_zone)
end
