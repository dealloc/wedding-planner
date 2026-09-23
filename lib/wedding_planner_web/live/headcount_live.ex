defmodule WeddingPlannerWeb.Live.HeadcountLive do
  @moduledoc """
  `/headcount` (task 61; `docs/modules/headcount.md` `HC-03`, `HC-07`, `HC-08`, `HC-09`;
  `DR-55`): events × presets, an "All events" row of distinct persons, every count
  openable into who is counted and why (`NFR-32`), and an ad hoc, unsaved filter
  (`HC-07`) that adds one more column and can be saved as a stored preset.

  ## Data (`HC-01`: never stored, computed live)

  `WeddingPlannerWeb.HeadcountOverview.build/2` — the pure view-model builder — turns a
  fresh `WeddingPlanner.Valuation.Snapshot.load/1` plus the transient ad hoc
  `WeddingPlanner.Valuation.Preset` (or `nil`) into `@overview.rows`/`@overview.columns`;
  this module only renders it. `refresh/1` reloads the snapshot from the database and
  rebuilds `@overview` — called on mount and on every `:person`, `:group`, `:invitation`,
  `:plus_one_opt_out`, `:event`, `:headcount_preset` broadcast (`WeddingPlanner.Realtime`,
  `XC-01`) — so a change made in another tab (or another LiveView, e.g. an RSVP set on
  `/invitations`) appears here without a reload, never from a cached snapshot. No change
  indicator of any kind (`DR-6`, `DR-21`).

  ## The ad hoc filter (`HC-07`, `HC-10`, `D-31`)

  `@adhoc_params` is the raw, string-keyed form params (`phx-change` lives on
  `#adhoc-filter-form`, never a bare checkbox — the design record's matrix-v3 bug);
  `@adhoc_preset` is the `WeddingPlanner.Valuation.Preset` built from it (`id: nil`,
  `name: "Ad hoc filter"`), or `nil` when the filter has never been touched this
  connection. Both are **transient socket assigns only** — never written to the
  database, the session or a broadcast (`HC-10`) — so the ad hoc column exists only for
  as long as this LiveView process lives. Each of the five checkbox groups carries a
  hidden `value=""` input alongside its `name="adhoc[<field>][]"` checkboxes so that
  unchecking the last box in a group still submits the key (with an empty value, which
  `filter_adhoc_params/1` strips) rather than dropping it from the params entirely — the
  well-known "browsers don't send unchecked checkboxes" gotcha, doubled for an array
  name. "Clear" (`#adhoc-filter-clear`) resets both assigns and removes the column.

  "Save as preset" (`#adhoc-save-form`) reuses `@adhoc_params` verbatim as the attrs for
  `WeddingPlanner.Presets.create_preset/2` (its keys already match
  `WeddingPlanner.Presets.HeadcountPreset`'s castable fields) plus the submitted name.
  On success the ad hoc column is cleared — the new preset reappears as an ordinary
  column via the `:headcount_preset` broadcast's own `refresh/1`, never assumed
  synchronously. On failure (e.g. a duplicate name) the changeset error renders inline
  and nothing is cleared, so the user's filter and typed name are not lost.

  ## Cell disclosure (`NFR-32`, `HC-08`, `DR-55`)

  Each cell is its own native `<details>` (`#headcount-cell-<row>-<col>`) whose
  `<summary>` is the plain "adults + children = total" text; its body nests
  `WeddingPlannerWeb.DisplayComponents.formula/1` (`#…-formula`, rendered `open`, so the
  formula's own step breakdown needs no second click — NFR-32's "at most one
  interaction" would otherwise mean two nested disclosures) fed by
  `WeddingPlannerWeb.FormulaPresenter.present/1` of
  `WeddingPlanner.Valuation.Headcount.explain/3`, plus a "Who is counted" names list
  (`#…-names`) from `WeddingPlanner.Valuation.Headcount.counted/3`.
  """
  use WeddingPlannerWeb, :live_view

  alias WeddingPlanner.Presets
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.HeadcountOverview

  @status_options [
    {"Planned", "planned"},
    {"Invited", "invited"},
    {"Accepted", "accepted"},
    {"Declined", "declined"}
  ]

  @certainty_options [{"Certain", "certain"}, {"Likely", "likely"}, {"Uncertain", "uncertain"}]

  @want_tier_options [
    {"Yes", "yes"},
    {"Maybe", "maybe"},
    {"No", "no"},
    {"Obligated", "obligated"}
  ]

  @age_category_options [{"Adult", "adult"}, {"Child", "child"}]

  @adhoc_fields ~w(invitation_statuses certainties want_tiers age_categories group_ids)
  @default_adhoc_params Map.new(@adhoc_fields, &{&1, []})

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Realtime.subscribe(:person)
      Realtime.subscribe(:group)
      Realtime.subscribe(:invitation)
      Realtime.subscribe(:plus_one_opt_out)
      Realtime.subscribe(:event)
      Realtime.subscribe(:headcount_preset)
    end

    socket =
      socket
      |> assign(:page_title, "Headcount")
      |> assign(:adhoc_params, @default_adhoc_params)
      |> assign(:adhoc_preset, nil)
      |> assign(:save_form, blank_save_form())
      |> assign(:status_options, @status_options)
      |> assign(:certainty_options, @certainty_options)
      |> assign(:want_tier_options, @want_tier_options)
      |> assign(:age_category_options, @age_category_options)
      |> refresh()

    {:ok, socket}
  end

  # -- ad hoc filter (HC-07, HC-10) ----------------------------------------------------------

  @impl true
  def handle_event("adhoc_filter", %{"adhoc" => params}, socket) do
    filtered = filter_adhoc_params(params)

    socket =
      socket
      |> assign(:adhoc_params, filtered)
      |> assign(:adhoc_preset, build_adhoc_preset(filtered))
      |> refresh()

    {:noreply, socket}
  end

  def handle_event("adhoc_clear", _params, socket) do
    socket =
      socket
      |> assign(:adhoc_params, @default_adhoc_params)
      |> assign(:adhoc_preset, nil)
      |> assign(:save_form, blank_save_form())
      |> refresh()

    {:noreply, socket}
  end

  def handle_event("adhoc_save", %{"preset_save" => %{"name" => name}}, socket) do
    attrs = Map.put(socket.assigns.adhoc_params, "name", name)

    case Presets.create_preset(socket.assigns.current_scope, attrs) do
      {:ok, preset} ->
        socket =
          socket
          |> assign(:adhoc_params, @default_adhoc_params)
          |> assign(:adhoc_preset, nil)
          |> assign(:save_form, blank_save_form())
          |> put_flash(:info, "Saved preset '#{preset.name}'.")
          |> refresh()

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :save_form, to_form(changeset, as: "preset_save"))}
    end
  end

  # -- live updates (XC-01, DR-21 — silent, full refresh, never a cached snapshot) -----------

  @impl true
  def handle_info({Realtime, :person, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :group, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :invitation, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :plus_one_opt_out, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :event, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :headcount_preset, _event}, socket), do: {:noreply, refresh(socket)}

  # -- data (HC-01: computed fresh every time, never cached across a broadcast) --------------

  defp refresh(socket) do
    snapshot = Snapshot.load(Repo)
    overview = HeadcountOverview.build(snapshot, socket.assigns.adhoc_preset)

    socket
    |> assign(:events, snapshot.events)
    |> assign(:presets, snapshot.headcount_presets)
    |> assign(:groups, snapshot.groups)
    |> assign(:overview, overview)
  end

  defp blank_save_form, do: to_form(%{"name" => ""}, as: "preset_save")

  # `Map.get(params, field, [])`, never `String.to_atom/1`: unknown/blank strings are
  # simply dropped — a checkbox's `value` is always one of the fixed atoms below, and the
  # hidden empty-value input's "" is filtered here.
  defp filter_adhoc_params(params) do
    Map.new(@adhoc_fields, fn field ->
      values = params |> Map.get(field, []) |> List.wrap() |> Enum.reject(&(&1 == ""))
      {field, values}
    end)
  end

  defp build_adhoc_preset(params) do
    %Preset{
      id: nil,
      name: "Ad hoc filter",
      invitation_statuses: parse_set(params["invitation_statuses"], &parse_status/1),
      certainties: parse_set(params["certainties"], &parse_certainty/1),
      want_tiers: parse_set(params["want_tiers"], &parse_want_tier/1),
      age_categories: parse_set(params["age_categories"], &parse_age_category/1),
      group_ids: parse_set(params["group_ids"], &parse_group_id/1)
    }
  end

  defp parse_set(values, parser), do: values |> Enum.map(parser) |> MapSet.new()

  defp parse_status("planned"), do: :planned
  defp parse_status("invited"), do: :invited
  defp parse_status("accepted"), do: :accepted
  defp parse_status("declined"), do: :declined

  defp parse_certainty("certain"), do: :certain
  defp parse_certainty("likely"), do: :likely
  defp parse_certainty("uncertain"), do: :uncertain

  defp parse_want_tier("yes"), do: :yes
  defp parse_want_tier("maybe"), do: :maybe
  defp parse_want_tier("no"), do: :no
  defp parse_want_tier("obligated"), do: :obligated

  defp parse_age_category("adult"), do: :adult
  defp parse_age_category("child"), do: :child

  defp parse_group_id(str) do
    case Integer.parse(str) do
      {id, ""} -> id
      _other -> nil
    end
  end

  # -- render -------------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width="wide">
      <.header>Headcount</.header>

      <p :if={@events == []} id="headcount-no-events" class="text-sm text-ink-soft">
        Add an event first —
        <.link navigate={~p"/events"} class="font-medium text-accent underline">
          go to Events
        </.link>
        .
      </p>

      <div
        :if={@events != []}
        class="overflow-x-auto rounded-field border border-line bg-surface-raised"
      >
        <div id="headcount-overview">
          <div class="grid border-b border-line bg-surface" style={grid_style(@overview.columns)}>
            <div class="sticky left-0 z-10 bg-surface px-3 py-2 text-xs font-semibold tracking-wide text-ink-soft uppercase">
              Event
            </div>
            <div
              :for={col <- @overview.columns}
              id={"headcount-col-#{col.id}"}
              class="px-3 py-2 text-xs font-semibold text-ink-soft"
            >
              {col.label}
            </div>
          </div>

          <p
            :if={@overview.columns == []}
            id="headcount-no-columns"
            class="px-3 py-4 text-sm text-ink-faint"
          >
            No presets and no ad hoc filter yet — build one below.
          </p>

          <div
            :for={row <- @overview.rows}
            id={"headcount-row-#{row.id}"}
            class="grid border-b border-line last:border-b-0"
            style={grid_style(@overview.columns)}
          >
            <div class="sticky left-0 z-10 bg-surface-raised px-3 py-2 text-sm font-medium text-ink">
              {row.label}
            </div>
            <div :for={col <- @overview.columns} class="p-1.5">
              <.headcount_cell
                id={"headcount-cell-#{row.id}-#{col.id}"}
                cell={Map.fetch!(row.cells, col.id)}
              />
            </div>
          </div>
        </div>
      </div>

      <p :if={@presets == []} id="headcount-no-presets" class="mt-3 text-sm text-ink-faint">
        There are no presets yet.
      </p>

      <section class="mt-8">
        <h2 class="text-sm font-semibold tracking-wide text-ink-soft uppercase">Ad hoc filter</h2>
        <p class="mt-1 text-xs text-ink-faint">
          Not saved anywhere — per-view only, until you save it as a preset.
        </p>

        <form
          id="adhoc-filter-form"
          phx-change="adhoc_filter"
          class="mt-3 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-5"
        >
          <.adhoc_checkbox_group
            legend="Invitation status"
            field="invitation_statuses"
            options={@status_options}
            selected={@adhoc_params["invitation_statuses"]}
          />
          <.adhoc_checkbox_group
            legend="Effective certainty"
            field="certainties"
            options={@certainty_options}
            selected={@adhoc_params["certainties"]}
          />
          <.adhoc_checkbox_group
            legend="Want tier"
            field="want_tiers"
            options={@want_tier_options}
            selected={@adhoc_params["want_tiers"]}
          />
          <.adhoc_checkbox_group
            legend="Age category"
            field="age_categories"
            options={@age_category_options}
            selected={@adhoc_params["age_categories"]}
          />
          <.adhoc_checkbox_group
            legend="Groups"
            field="group_ids"
            options={Enum.map(@groups, &{&1.name, to_string(&1.id)})}
            selected={@adhoc_params["group_ids"]}
          />
        </form>

        <div :if={@adhoc_preset} class="mt-4 flex flex-wrap items-end gap-4">
          <button
            type="button"
            id="adhoc-filter-clear"
            phx-click="adhoc_clear"
            class="inline-flex min-h-11 items-center justify-center rounded-field border border-line-strong bg-surface-raised px-4 text-sm font-medium text-ink hover:bg-surface"
          >
            Clear
          </button>

          <.form
            for={@save_form}
            id="adhoc-save-form"
            phx-submit="adhoc_save"
            class="flex items-end gap-2"
          >
            <.input
              id="adhoc-save-name"
              field={@save_form[:name]}
              type="text"
              label="Save as preset"
              placeholder="Preset name"
            />
            <.button variant="primary">Save</.button>
          </.form>
        </div>
      </section>

      <section id="headcount-presets-section" class="mt-8">
        <h2 class="text-sm font-semibold tracking-wide text-ink-soft uppercase">Presets</h2>
        <p class="mt-1 text-xs text-ink-faint">
          Preset editing (rename, criteria, role, reorder, delete) lands in a follow-up screen.
        </p>
      </section>
    </Layouts.app>
    """
  end

  attr :legend, :string, required: true
  attr :field, :string, required: true
  attr :options, :list, required: true
  attr :selected, :list, required: true

  defp adhoc_checkbox_group(assigns) do
    ~H"""
    <fieldset id={"adhoc-#{@field}"} class="rounded-field border border-line bg-surface-raised p-3">
      <legend class="px-1 text-xs font-semibold tracking-wide text-ink-soft uppercase">
        {@legend}
      </legend>
      <input type="hidden" id={"adhoc-#{@field}-empty"} name={"adhoc[#{@field}][]"} value="" />
      <label
        :for={{label, value} <- @options}
        class="flex min-h-8 cursor-pointer items-center gap-2 text-sm text-ink"
      >
        <input
          type="checkbox"
          id={"adhoc-#{@field}-#{value}"}
          name={"adhoc[#{@field}][]"}
          value={value}
          checked={value in @selected}
          class="size-4 rounded border-line-strong accent-accent focus:outline-none focus:ring-2 focus:ring-accent"
        />
        {label}
      </label>
      <p :if={@options == []} class="text-xs text-ink-faint">None yet.</p>
    </fieldset>
    """
  end

  attr :id, :string, required: true
  attr :cell, :map, required: true

  defp headcount_cell(assigns) do
    ~H"""
    <details id={@id} class="rounded-field">
      <summary class="tabular-nums cursor-pointer list-none rounded-field px-2 py-1 text-sm font-medium text-ink hover:bg-surface focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent">
        {@cell.total_text}
      </summary>
      <div class="mt-2 space-y-2 px-1">
        <.formula
          id={"#{@id}-formula"}
          total_label={@cell.formula.total_label}
          total={@cell.formula.total}
          steps={@cell.formula.steps}
          open={true}
        />
        <div id={"#{@id}-names"}>
          <p class="text-xs font-medium tracking-wide text-ink-soft uppercase">Who is counted</p>
          <ul :if={@cell.names != []} class="mt-1 space-y-0.5 text-sm text-ink">
            <li :for={name <- @cell.names}>{name}</li>
          </ul>
          <p :if={@cell.names == []} class="mt-1 text-sm text-ink-faint">Nobody</p>
        </div>
      </div>
    </details>
    """
  end

  defp grid_style(columns) do
    count = length(columns)
    min_width = 200 + count * 220

    "display: grid; grid-template-columns: 200px repeat(#{count}, minmax(220px, 1fr)); min-width: #{min_width}px;"
  end
end
