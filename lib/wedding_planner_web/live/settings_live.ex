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
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.ActivityComponents, only: [entity_history: 1]

  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Settings
  alias WeddingPlannerWeb.Format

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
