defmodule WeddingPlannerWeb.Live.BudgetLive do
  @moduledoc """
  The budget screen (task 82; `/budget`, `DR-76`): phone-first tiles, the overall budget
  edited in place (`BUD-01`), the overdue "needs attention" banner (`BIL-06`), and one
  expandable card per category with its layers, confirmed offers, planning pick,
  invoices and formulas (`BUD-02`, `BUD-08`).

  Built entirely on `WeddingPlannerWeb.BudgetOverview.build/3`: every write and every
  read of a business rule happens elsewhere — `WeddingPlanner.Settings.update/3` (the
  only write this screen makes) and `WeddingPlanner.Valuation.Budget` (via the view
  model). Nothing here re-derives a figure.

  ## The selected preset is a transient assign only (`HC-10`, `D-31`)

  `@selected_preset_id` never leaves this socket's own assigns — no URL param, no
  session key, no PubSub broadcast, no database row. `WeddingPlannerWeb.BudgetOverview.build/3`
  resolves it against the freshly loaded snapshot on every render (`PresetChoice.find/2`,
  so a stale or deleted id quietly falls back to the default).

  ## Disclosure open state survives a live update (`DR-71`)

  A role-value button (`WeddingPlannerWeb.Components.BudgetComponents.role_values/1`)
  both selects a preset and opens a formula's `<details>` via a `Phoenix.LiveView.JS`
  command. Verified in the browser: a plain `<details open={false}>` re-render — which
  happens on *any* subsequent live update, not just this button's own click — strips the
  attribute the `JS` command set, because the assign backing `:open` never changed. Kept
  around instead as `@open_formula_ids` (a `MapSet` of formula element ids), fed into
  `formula/1`'s own `:open` attr from the view model, so a disclosure a role-value button
  opened stays open across a broadcast from the other tab.

  ## Live updates (`XC-01`)

  Every business rule this screen shows is ultimately over the guest list, the offers,
  the invoices, the categories and the settings row — so it subscribes to all of them
  (the same set `WeddingPlannerWeb.Live.CategoryLive`'s matrix already subscribes to,
  plus `:settings` and `:invoice`/`:invoice_line`) and simply reloads the snapshot and
  rebuilds the view model on any of them; per `DR-21`/`XC-02` there is no concurrent-edit
  indicator of any kind.

  "Today" is `WeddingPlanner.Tasks.TodoList.today(@time_zone)` (`on_mount
  {WeddingPlannerWeb.Live.TimeZoneHook, :default}`), never `Date.utc_today/0`.
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.Components.BudgetComponents

  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Settings
  alias WeddingPlanner.Tasks.TodoList
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.BudgetOverview

  on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

  @topics [
    :settings,
    :category,
    :service,
    :offer,
    :offer_line,
    :override,
    :frozen_service,
    :invoice,
    :invoice_line,
    :event,
    :person,
    :group,
    :invitation,
    :plus_one_opt_out,
    :headcount_preset
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Enum.each(@topics, &Realtime.subscribe/1)
    end

    socket =
      socket
      |> assign(:page_title, "Budget")
      |> assign(:selected_preset_id, nil)
      |> assign(:open_formula_ids, MapSet.new())
      |> refresh()
      |> assign_budget_form()

    {:ok, socket}
  end

  # -- overall budget in place (BUD-01, DR-72) -----------------------------------------

  @impl true
  def handle_event("save_budget", %{"settings" => params}, socket) do
    case Settings.update(socket.assigns.current_scope, socket.assigns.settings, params) do
      {:ok, updated} ->
        socket =
          socket
          |> assign(:settings, updated)
          |> assign_budget_form()
          |> refresh()

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :budget_form, to_form(changeset, as: :settings))}
    end
  end

  # -- preset selection (HC-10, DR-71) -------------------------------------------------

  # From `DisplayComponents.preset_selector/1`'s own wrapping form (`#budget-preset`) —
  # never opens a disclosure, just re-points every single-figure computation.
  def handle_event("select_preset", %{"budget-preset-selector-preset" => id}, socket) do
    {:noreply, socket |> assign(:selected_preset_id, id) |> refresh()}
  end

  # From a `role_values/1` button: also marks that figure's formula as open (DR-71).
  def handle_event("select_preset", %{"preset_id" => id} = params, socket) do
    socket =
      socket
      |> assign(:selected_preset_id, id)
      |> mark_formula_open(params["formula_id"])
      |> refresh()

    {:noreply, socket}
  end

  # -- live updates (XC-01, XC-02) -----------------------------------------------------

  @impl true
  def handle_info({Realtime, _resource, _event}, socket), do: {:noreply, refresh(socket)}

  # -- private --------------------------------------------------------------------------

  defp mark_formula_open(socket, nil), do: socket
  defp mark_formula_open(socket, id), do: update(socket, :open_formula_ids, &MapSet.put(&1, id))

  defp refresh(socket) do
    snapshot = Snapshot.load(Repo)
    today = TodoList.today(socket.assigns.time_zone)
    overview = BudgetOverview.build(snapshot, today, socket.assigns.selected_preset_id)

    socket
    |> assign(:snapshot, snapshot)
    |> assign(:today, today)
    |> assign(:settings, snapshot.settings)
    |> assign(:overview, overview)
  end

  defp assign_budget_form(socket) do
    settings = socket.assigns.settings

    changeset =
      settings
      |> Settings.changeset(%{})
      |> Ecto.Changeset.put_change(
        :overall_budget_input,
        budget_input_value(settings.overall_budget)
      )

    assign(socket, :budget_form, to_form(changeset, as: :settings))
  end

  defp budget_input_value(nil), do: ""

  defp budget_input_value(%Money{} = money) do
    money
    |> WeddingPlannerWeb.Format.money()
    |> String.replace_prefix("€ ", "")
  end

  # -- render --------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <WeddingPlannerWeb.Live.TimeZoneHook.probe id="budget-time-zone-probe" />

      <div class="mx-auto max-w-3xl">
        <div id="budget-header" class="flex flex-wrap items-start justify-between gap-4">
          <h1 class="text-2xl font-bold text-ink">Budget</h1>

          <div class="flex flex-col items-end gap-1">
            <.form
              for={@budget_form}
              id="overall-budget-form"
              phx-submit="save_budget"
              class="flex items-baseline gap-2"
            >
              <.input
                field={@budget_form[:overall_budget_input]}
                type="text"
                label="Overall budget"
                placeholder="e.g. 45.000,00"
                class="w-32 rounded-field border border-transparent bg-transparent px-1 py-0.5 text-right text-lg font-semibold text-ink transition focus:border-accent focus:ring-2 focus:ring-accent focus:outline-none sm:w-40"
              />
            </.form>
          </div>
        </div>

        <div
          :if={@overview.presets_missing?}
          id="budget-no-presets"
          class="mt-6 text-sm text-ink-soft"
        >
          No headcount presets are stored, so the budget cannot be computed right now.
        </div>

        <div :if={!@overview.presets_missing?}>
          <div id="budget-preset" class="mt-4">
            <.form
              for={to_form(%{}, as: :budget_preset)}
              id="budget-preset-form"
              phx-change="select_preset"
              class="contents"
            >
              <.preset_selector
                id="budget-preset-selector"
                presets={@overview.presets}
                selected={@overview.selected_preset.id}
              />
            </.form>
            <p class="mt-1 text-xs text-ink-faint">Used for calculations and charts; not saved</p>
          </div>

          <div id="budget-tiles" class="mt-6 grid grid-cols-2 gap-3 md:grid-cols-4">
            <.tile id="tile-available" label="Available" bad?={@overview.tiles.available.over_budget?}>
              <p
                :if={@overview.tiles.available.role_values == :no_budget}
                id="tile-available-no-budget"
                class="text-sm text-ink-soft"
              >
                Set an overall budget
              </p>
              <.role_values
                :if={@overview.tiles.available.role_values != :no_budget}
                id="tile-available-values"
                ranged={@overview.tiles.available.role_values}
                formula_id="budget-overall-available-formula"
                bad?={@overview.tiles.available.over_budget?}
              />
            </.tile>

            <.tile id="tile-forecast" label="Forecast">
              <.role_values
                id="tile-forecast-values"
                ranged={@overview.tiles.forecast.role_values}
                formula_id="budget-overall-forecast-formula"
              />
            </.tile>

            <.tile id="tile-spent" label="Spent">
              <p class="text-lg font-semibold text-ink">{@overview.tiles.spent.value}</p>
            </.tile>

            <.tile id="tile-outstanding" label="Outstanding">
              <p class="text-lg font-semibold text-ink">{@overview.tiles.outstanding.value}</p>
            </.tile>
          </div>

          <p
            :if={@overview.over_budget}
            id="budget-over-budget"
            class="mt-2 text-sm font-semibold text-bad"
          >
            Over budget by {@overview.over_budget}
          </p>

          <div id="budget-overall-formulas" class="mt-4 space-y-3">
            <.formula
              id="budget-overall-forecast-formula"
              total_label="Forecast"
              open={MapSet.member?(@open_formula_ids, "budget-overall-forecast-formula")}
              {@overview.overall_forecast_formula}
            />

            <.formula
              :if={@overview.overall_available_formula}
              id="budget-overall-available-formula"
              total_label="Available"
              open={MapSet.member?(@open_formula_ids, "budget-overall-available-formula")}
              {@overview.overall_available_formula}
            />
          </div>

          <.overdue_banner id="budget-overdue" overdue={@overview.overdue} />

          <%!-- task 84: view switcher + charts --%>

          <div id="budget-categories" class="mt-6 space-y-3">
            <.category_card
              :for={card <- @overview.categories}
              card={card}
              snapshot={@snapshot}
              today={@today}
              open_formula_ids={@open_formula_ids}
            />
          </div>

          <%!-- task 84: cash flow --%>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
