defmodule WeddingPlannerWeb.Live.SettingsLive do
  @moduledoc """
  The `/settings` screen (task 21; `docs/03-domain-model.md`'s Settings singleton):
  editing the overall budget (`BUD-01`) and the default time zone (`NFR-22`), plus that
  singleton's own activity history (`XC-11`).

  ## Live updates (`XC-01`)

  Subscribes to both `:settings` (the row itself) and `:activity_entry` (its history),
  following `WeddingPlannerWeb.ActivityComponents.entity_history/1`'s documented host
  pattern: a broadcast entry is only appended when it is this entity's
  (`{"settings", @settings.id}`). A `:settings` broadcast (including this view's own save
  — `WeddingPlanner.Realtime` broadcasts to every subscriber, itself included) simply
  replaces the shown values and rebuilds the form; per `DR-21`/`XC-02` there is no
  concurrent-edit indicator of any kind.

  ## Money input (`DR-23`)

  The budget field binds to the changeset's virtual `:overall_budget_input`, never to
  `:overall_budget` itself (a real `%Money{}` or `nil`, never text) — see
  `WeddingPlanner.Settings`'s moduledoc.

  ## Transfer data (`DR-93`, `DR-97`, `XC-40`, `AUTH-01`, `NFR-22`/`NFR-23`/`NFR-31`)

  The "Transfer data" section (task 101) is the UI on top of the `WeddingPlanner.Transfer`
  façade (task 100, the only entry point) and `WeddingPlannerWeb.TransferController`'s two
  authenticated downloads (`AUTH-01`). An import goes through one state machine, `@transfer`:

      :idle | {:checking, token} | {:preview, token, preview} | {:importing, token, preview}
      | {:done, result} | {:refused, refusal}

  `:transfer_file` is `allow_upload/3` with `auto_upload: true` and a `progress:` callback
  (`handle_progress/3`) — the moment the browser finishes sending the file, its temp path
  is consumed and handed to `Transfer.stash_upload/1`, and the resulting token drives
  `start_async(:transfer_preview, ...)`. Confirming a preview similarly starts
  `start_async(:transfer_import, ...)`, closing over plain data only (`token`, the scope,
  the time zone, `TransferController.source_host/0`) — never the socket. Both async tasks
  keep the LiveView responsive (`AGENTS.md`'s standing loading-state pattern, the
  `WeddingPlannerWeb.Live.BudgetLive` idiom): the confirm button's own `phx-click`
  (`JS.push(..., loading: "#transfer-panel")`) plus `phx-disable-with` give instant
  client-side feedback, and the server-side `:importing` state extends it — disabling the
  button and showing "Importing…" — for the task's whole real duration, never a
  synchronous `Transfer.import/3` call on the socket's own process.

  **`origin: self()` is captured *before* `start_async/3`** (task 99's
  `WeddingPlannerWeb.Live.ReloadOnImportHook` reloads every *other* open authenticated
  screen on a successful import, `XC-01`/`DR-95`) — `start_async/3` runs the import in a
  separate process, so passing the task's own `self()` would name the wrong pid and this
  screen would reload itself too, losing its own success panel.

  A `:pending_token` assign tracks whichever stash token hasn't yet been discarded —
  through `:checking`, `:preview`, `:importing` and (since a refusal keeps the stash,
  `WeddingPlanner.Transfer`'s moduledoc) `:refused` — so `cancel_import`, `choose_another`
  and, as a last resort, `terminate/2` can always call `Transfer.discard/1` on whatever is
  still stashed, never leaving an abandoned upload past the façade's own 1-hour sweep.

  Rendering is delegated to `WeddingPlannerWeb.Components.TransferComponents`, which only
  ever sees the flat `Preview.t()`/`Result.t()`/`Refusal.t()` data, never the state tuple.
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.ActivityComponents, only: [entity_history: 1]
  import WeddingPlannerWeb.Components.TransferComponents

  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Settings
  alias WeddingPlanner.Transfer
  alias WeddingPlanner.Transfer.Refusal
  alias WeddingPlannerWeb.Format
  alias WeddingPlannerWeb.TransferController

  on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Realtime.subscribe(:settings)
      Realtime.subscribe(:activity_entry)
    end

    settings = Settings.get()

    socket =
      socket
      |> assign(:page_title, "Settings")
      |> assign(:settings, settings)
      |> assign(:activity_entries, Query.for_entity(:settings, settings.id))
      |> assign_form(settings)
      |> assign(:transfer, :idle)
      |> assign(:pending_token, nil)
      |> assign(:safety_copies, Transfer.list_safety_copies())
      |> allow_upload(:transfer_file,
        accept: ~w(.json),
        max_entries: 1,
        max_file_size: Transfer.max_upload_bytes(),
        auto_upload: true,
        progress: &handle_progress/3
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("save", %{"settings" => params}, socket) do
    case Settings.update(socket.assigns.current_scope, socket.assigns.settings, params) do
      {:ok, updated} ->
        socket =
          socket
          |> assign(:settings, updated)
          |> assign_form(updated)
          |> put_flash(:info, "Settings saved.")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :settings))}
    end
  end

  # -- transfer data (DR-93, DR-95, DR-97, XC-40) ---------------------------------------

  def handle_event("validate_transfer", _params, socket), do: {:noreply, socket}
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_import", _params, socket) do
    discard_pending(socket)
    {:noreply, socket |> assign(:transfer, :idle) |> assign(:pending_token, nil)}
  end

  def handle_event("choose_another", _params, socket) do
    discard_pending(socket)
    {:noreply, socket |> assign(:transfer, :idle) |> assign(:pending_token, nil)}
  end

  def handle_event("confirm_import", _params, socket) do
    case socket.assigns.transfer do
      {:preview, token, preview} ->
        scope = socket.assigns.current_scope
        time_zone = socket.assigns.time_zone
        source_host = TransferController.source_host()
        # Captured before `start_async/3`, which runs the import in a separate process
        # (see the moduledoc): this screen must stay the reload hook's `origin`, or it
        # would reload (and lose) its own success panel.
        origin = self()

        socket =
          socket
          |> assign(:transfer, {:importing, token, preview})
          |> start_async(:transfer_import, fn ->
            Transfer.import(token, scope,
              origin: origin,
              time_zone: time_zone,
              source_host: source_host
            )
          end)

        {:noreply, socket}

      _other ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({Realtime, :settings, {:updated, updated}}, socket) do
    socket =
      socket
      |> assign(:settings, updated)
      |> assign_form(updated)

    {:noreply, socket}
  end

  @impl true
  def handle_info({Realtime, :activity_entry, {:created, entry}}, socket) do
    settings = socket.assigns.settings

    if entry.entity_type == "settings" and entry.entity_id == settings.id do
      entry = Query.preload_user(entry)
      {:noreply, update(socket, :activity_entries, &[entry | &1])}
    else
      {:noreply, socket}
    end
  end

  # Consumes the finished upload the moment the browser is done sending it
  # (`auto_upload: true`), so the user never has to press a separate submit button.
  # `Transfer.stash_upload/1` (which copies the file) MUST run *inside* this callback:
  # `consume_uploaded_entries/3`'s temp file is only guaranteed to exist for the
  # callback's own duration — calling `stash_upload/1` afterward, on the path handed
  # back, hits `:enoent` (confirmed empirically).
  defp handle_progress(:transfer_file, entry, socket) do
    if entry.done? do
      [result] =
        consume_uploaded_entries(socket, :transfer_file, fn %{path: path}, _entry ->
          {:ok, Transfer.stash_upload(path)}
        end)

      case result do
        {:ok, token} ->
          scope = socket.assigns.current_scope

          socket =
            socket
            |> assign(:transfer, {:checking, token})
            |> assign(:pending_token, token)
            |> start_async(:transfer_preview, fn -> Transfer.preview(token, scope) end)

          {:noreply, socket}

        {:error, refusal} ->
          {:noreply, assign(socket, :transfer, {:refused, refusal})}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:transfer_preview, {:ok, {:ok, preview}}, socket) do
    case socket.assigns.transfer do
      {:checking, token} ->
        {:noreply, assign(socket, :transfer, {:preview, token, preview})}

      _other ->
        # A newer selection (or a cancel) has already moved the state on — ignore this
        # stale result rather than resurrect a preview nobody asked for any more.
        {:noreply, socket}
    end
  end

  def handle_async(:transfer_preview, {:ok, {:error, refusal}}, socket) do
    {:noreply, assign(socket, :transfer, {:refused, refusal})}
  end

  def handle_async(:transfer_preview, {:exit, reason}, socket) do
    {:noreply, assign(socket, :transfer, {:refused, unexpected_refusal(reason)})}
  end

  def handle_async(:transfer_import, {:ok, {:ok, result}}, socket) do
    socket =
      socket
      |> assign(:transfer, {:done, result})
      |> assign(:pending_token, nil)
      |> reload_after_import()

    {:noreply, socket}
  end

  def handle_async(:transfer_import, {:ok, {:error, refusal}}, socket) do
    {:noreply, assign(socket, :transfer, {:refused, refusal})}
  end

  def handle_async(:transfer_import, {:exit, reason}, socket) do
    {:noreply, assign(socket, :transfer, {:refused, unexpected_refusal(reason)})}
  end

  @impl true
  # Best-effort cleanup of whatever is still stashed when this LiveView goes away
  # (closed tab, crash) without the user cancelling or choosing another file
  # (`WeddingPlanner.Transfer`'s moduledoc: 100 also sweeps stale stashes after an hour).
  def terminate(_reason, socket), do: discard_pending(socket)

  defp discard_pending(socket) do
    case socket.assigns[:pending_token] do
      nil -> :ok
      token -> Transfer.discard(token)
    end
  end

  defp reload_after_import(socket) do
    settings = Settings.get()

    socket
    |> assign(:settings, settings)
    |> assign(:activity_entries, Query.for_entity(:settings, settings.id))
    |> assign_form(settings)
    |> assign(:safety_copies, Transfer.list_safety_copies())
  end

  defp unexpected_refusal(reason) do
    %Refusal{
      reason: :storage,
      message: "The import failed unexpectedly, so nothing may have changed. Try again.",
      detail: reason
    }
  end

  defp assign_form(socket, settings) do
    changeset =
      settings
      |> Settings.changeset(%{})
      |> Ecto.Changeset.put_change(
        :overall_budget_input,
        budget_input_value(settings.overall_budget)
      )

    assign(socket, :form, to_form(changeset, as: :settings))
  end

  defp budget_input_value(nil), do: ""

  defp budget_input_value(%Money{} = money) do
    money
    |> Format.money()
    |> String.replace_prefix("€ ", "")
  end

  # A curated set of common IANA zones for the dropdown — not an exhaustive enumeration
  # (the `tz` package exposes no public "list every zone" API), but that is only a
  # convenience for picking a value: `WeddingPlanner.Settings.changeset/2` validates
  # whatever is actually submitted against the real, configured `Tz` time zone database,
  # not against this list.
  @time_zone_options [
    {"Brussels", "Europe/Brussels"},
    {"Amsterdam", "Europe/Amsterdam"},
    {"Paris", "Europe/Paris"},
    {"London", "Europe/London"},
    {"Berlin", "Europe/Berlin"},
    {"Madrid", "Europe/Madrid"},
    {"Rome", "Europe/Rome"},
    {"Zurich", "Europe/Zurich"},
    {"Dublin", "Europe/Dublin"},
    {"Lisbon", "Europe/Lisbon"},
    {"Vienna", "Europe/Vienna"},
    {"Copenhagen", "Europe/Copenhagen"},
    {"Stockholm", "Europe/Stockholm"},
    {"Oslo", "Europe/Oslo"},
    {"Warsaw", "Europe/Warsaw"},
    {"Prague", "Europe/Prague"},
    {"Athens", "Europe/Athens"},
    {"Bucharest", "Europe/Bucharest"},
    {"Helsinki", "Europe/Helsinki"},
    {"New York", "America/New_York"},
    {"Chicago", "America/Chicago"},
    {"Denver", "America/Denver"},
    {"Los Angeles", "America/Los_Angeles"},
    {"São Paulo", "America/Sao_Paulo"},
    {"Tokyo", "Asia/Tokyo"},
    {"Shanghai", "Asia/Shanghai"},
    {"Dubai", "Asia/Dubai"},
    {"Singapore", "Asia/Singapore"},
    {"Kolkata", "Asia/Kolkata"},
    {"Sydney", "Australia/Sydney"},
    {"Auckland", "Pacific/Auckland"},
    {"Johannesburg", "Africa/Johannesburg"},
    {"UTC", "Etc/UTC"}
  ]

  defp time_zone_options, do: @time_zone_options

  # -- transfer data render helpers ------------------------------------------------------

  defp transfer_state(:idle), do: :idle
  defp transfer_state({:checking, _token}), do: :checking
  defp transfer_state({:preview, _token, _preview}), do: :preview
  defp transfer_state({:importing, _token, _preview}), do: :importing
  defp transfer_state({:done, _result}), do: :done
  defp transfer_state({:refused, _refusal}), do: :refused

  defp transfer_preview_data({:preview, _token, preview}), do: preview
  defp transfer_preview_data({:importing, _token, preview}), do: preview

  defp transfer_result_data({:done, result}), do: result

  defp transfer_refusal_data({:refused, refusal}), do: refusal

  defp transfer_upload_error(:too_large), do: "This file is larger than 50 MB."
  defp transfer_upload_error(:not_accepted), do: "Choose a JSON file."
  defp transfer_upload_error(:too_many_files), do: "One file at a time."
  defp transfer_upload_error(_other), do: "This file could not be uploaded."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <WeddingPlannerWeb.Live.TimeZoneHook.probe id="settings-time-zone-probe" />

      <.header>Settings</.header>

      <.form for={@form} id="settings-form" phx-submit="save" class="space-y-6">
        <div>
          <.input
            field={@form[:overall_budget_input]}
            type="text"
            label="Overall budget"
            placeholder="e.g. 45.000,00"
          />
          <p id="settings-budget-current" class="mt-1.5 text-xs text-ink-faint">
            Currently:
            <span class="tabular-nums">{Settings.budget_label(@settings.overall_budget)}</span>
          </p>
        </div>

        <.input
          field={@form[:default_time_zone]}
          type="select"
          label="Default time zone"
          options={time_zone_options()}
        />

        <.button variant="primary" id="settings-save">Save</.button>
      </.form>

      <section id="transfer-data" class="mt-10 space-y-3">
        <h2 class="text-sm font-semibold text-ink-soft">Transfer data</h2>
        <p class="text-sm text-ink-soft">
          Move everything to another copy of this app, for example from your computer to
          the live site. Users and passkeys stay where they are.
        </p>

        <div
          id="transfer-panel"
          aria-busy={to_string(transfer_state(@transfer) == :importing)}
        >
          <div class="flex flex-wrap items-center gap-3">
            <a
              id="transfer-export"
              href={~p"/transfer/export?#{[tz: @time_zone]}"}
              download
              class="inline-flex min-h-11 items-center justify-center gap-2 rounded-field border border-line-strong bg-transparent px-4 text-sm font-semibold text-ink transition-all duration-150 ease-out hover:bg-surface active:scale-[0.98] active:bg-line"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> Export all data (JSON)
            </a>

            <.form
              for={to_form(%{}, as: :transfer)}
              id="transfer-import-form"
              phx-change="validate_transfer"
              phx-submit="noop"
              class="flex flex-col gap-1"
            >
              <span class="text-sm font-semibold text-ink">Import…</span>
              <.live_file_input upload={@uploads.transfer_file} />
              <p class="text-xs text-ink-faint">JSON export from this app, up to 50 MB</p>
              <p
                :for={err <- upload_errors(@uploads.transfer_file)}
                class="text-sm text-bad"
              >
                {transfer_upload_error(err)}
              </p>
            </.form>
          </div>

          <p
            :if={transfer_state(@transfer) == :checking}
            id="transfer-status"
            aria-live="polite"
            class="mt-3 flex items-center gap-1.5 text-sm text-ink-soft"
          >
            <span
              class="size-3 shrink-0 animate-spin rounded-full border-2 border-ink-faint border-t-transparent"
              aria-hidden="true"
            ></span>
            Checking file…
          </p>

          <.transfer_preview
            :if={transfer_state(@transfer) in [:preview, :importing]}
            id="transfer-preview"
            preview={transfer_preview_data(@transfer)}
            importing?={transfer_state(@transfer) == :importing}
            time_zone={@time_zone}
          />

          <.transfer_done
            :if={transfer_state(@transfer) == :done}
            id="transfer-done"
            result={transfer_result_data(@transfer)}
            time_zone={@time_zone}
          />

          <.transfer_refused
            :if={transfer_state(@transfer) == :refused}
            id="transfer-refused"
            refusal={transfer_refusal_data(@transfer)}
          />
        </div>

        <.transfer_safety_copies
          id="transfer-safety-copies"
          copies={@safety_copies}
          time_zone={@time_zone}
        />
      </section>

      <section class="mt-10">
        <h2 class="mb-2 text-sm font-semibold text-ink-soft">History</h2>
        <.entity_history
          id="settings-history"
          entity={{:settings, @settings.id}}
          entries={@activity_entries}
          time_zone={@time_zone}
          empty_message="No changes yet."
        />
      </section>
    </Layouts.app>
    """
  end
end
