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

  ## The view switcher lives in the URL, the preset does not (`DR-76`, task 84)

  `?view=category|event|guest` (`handle_params/3`, missing or unknown → category) picks
  which of the `BUD-07` breakdowns is shown; a *view* is not a preset, so it may live in
  the URL and survive a reload. `@selected_preset_id` stays the transient assign it
  always was — `handle_params/3` never touches it, so switching views keeps whichever
  preset was selected (`FP-84a`). The cash-flow section (`BUD-06`) and both charts
  (`DR-77`) are unaffected by the view switcher; only the by-category/-event/-guest body
  changes (charts render only in the Category view, per the design).

  ## Live updates (`XC-01`)

  Every business rule this screen shows is ultimately over the guest list, the offers,
  the invoices, the categories and the settings row — so it subscribes to all of them
  (the same set `WeddingPlannerWeb.Live.CategoryLive`'s matrix already subscribes to,
  plus `:settings` and `:invoice`/`:invoice_line`) and reloads the snapshot on any of
  them; per `DR-21`/`XC-02` there is no concurrent-edit indicator of any kind.

  "Today" is `WeddingPlanner.Tasks.TodoList.today(@time_zone)` (`on_mount
  {WeddingPlannerWeb.Live.TimeZoneHook, :default}`), never `Date.utc_today/0`.

  ## Recomputing the view model is asynchronous, never the snapshot reload (orchestrator
  amendment, 2026-09-25 — the user reported a confusing ~1s gap between clicking a preset
  and the numbers changing)

  `@snapshot` is loaded exactly twice per interaction cycle: once at mount (via
  `handle_params/3`'s first pass) and once per `{Realtime, _, _}` message — **never** on
  a preset change or a view switch, which only ever re-render the *same* already-loaded
  snapshot under a different preset id / view. `WeddingPlannerWeb.BudgetOverview.build/4`
  measures ~4ms even on realistic data, so it is not itself the reported delay, but the
  user asked for the `start_async/3` treatment regardless, applied uniformly:

    * `recompute/1` is the single entry point every one of `select_preset`, the view
      switcher (`handle_params/3`, once the page already has an `:overview` to keep
      showing) and a `Realtime` broadcast goes through. The very first `:overview` (no
      previous one to show meanwhile) is still built synchronously — there is nothing to
      dim before the page has rendered once.
    * `@recomputing` (`true` while a `start_async/3` task is in flight) dims every
      preset-dependent region — both charts, the overall Forecast/Available formulas,
      the category cards, the by-event and per-guest views — via `aria-busy` plus a
      standing "Updating…" indicator next to the preset selector (`aria-live="polite"`).
      The three-role tiles and the cash-flow section are **not** dimmed: neither depends
      on the selected preset (`DR-71`, `DR-75`), so recomputing them would be a false
      signal.
    * The async function closes over plain data only (`snapshot`, `today`,
      `selected_preset_id`, `view`) — never the socket, per `start_async/3`'s own
      contract.
    * **Staleness**: `Phoenix.LiveView.start_async/3`'s own contract already discards an
      in-flight task's result once a later `start_async/3` call under the same name
      (`:build_overview`) has been issued ("the later `start_async` wins and the
      previous task's result is ignored" — `deps/phoenix_live_view/lib/phoenix_live_view.ex`).
      `handle_async/3` re-checks the preset id and view the result was built for against
      the socket's *current* ones anyway, as a defensive backstop for the narrow race
      where a result was already in the mailbox the instant a newer request began — never
      because the framework's own guarantee is trusted blindly.
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.BudgetChartComponents
  import WeddingPlannerWeb.Components.BudgetComponents
  import WeddingPlannerWeb.Components.ExportComponents, only: [export_link: 1]

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
      |> assign(:recomputing, false)
      |> load_snapshot()

    {:ok, socket}
  end

  # -- the view switcher lives in the URL (BUD-07, DR-76) ------------------------------

  # The only place `@view` is set — a reload on `?view=event` keeps that view, and
  # (`FP-84a`) it never touches `@selected_preset_id`, so switching views keeps the
  # selected preset (`HC-10`). Never reloads `@snapshot` (orchestrator amendment): a
  # view switch re-renders the same snapshot the page already has.
  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:view, parse_view(params))
      |> recompute()
      |> assign_budget_form()

    {:noreply, socket}
  end

  defp parse_view(params) do
    case Map.get(params, "view") do
      "event" -> "event"
      "guest" -> "guest"
      _ -> "category"
    end
  end

  # -- overall budget in place (BUD-01, DR-72) -----------------------------------------

  # The one write this screen makes — unlike a preset/view change, the underlying data
  # genuinely changed, so this reloads the snapshot synchronously (the existing
  # `FP-82c`-style tests read the updated tile back from this same reply, not from a
  # subsequent broadcast).
  @impl true
  def handle_event("save_budget", %{"settings" => params}, socket) do
    case Settings.update(socket.assigns.current_scope, socket.assigns.settings, params) do
      {:ok, updated} ->
        socket =
          socket
          |> assign(:settings, updated)
          |> assign_budget_form()
          |> load_snapshot()
          |> assign_overview_sync()

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :budget_form, to_form(changeset, as: :settings))}
    end
  end

  # -- preset selection (HC-10, DR-71) -------------------------------------------------

  # From `DisplayComponents.preset_selector/1`'s own wrapping form (`#budget-preset`) —
  # never opens a disclosure, just re-points every single-figure computation.
  def handle_event("select_preset", %{"budget-preset-selector-preset" => id}, socket) do
    {:noreply, socket |> assign(:selected_preset_id, id) |> recompute()}
  end

  # From a `role_values/1` button: also marks that figure's formula as open (DR-71).
  def handle_event("select_preset", %{"preset_id" => id} = params, socket) do
    socket =
      socket
      |> assign(:selected_preset_id, id)
      |> mark_formula_open(params["formula_id"])
      |> recompute()

    {:noreply, socket}
  end

  # -- the view switcher (BUD-07, DR-76) ------------------------------------------------

  # From `BudgetComponents.view_switcher/1`'s button — a plain `push_patch/2` to the same
  # URL a `<.link patch>` click would have produced (`handle_params/3`, unchanged, still
  # owns `@view` and the recompute). A real event, not `JS.patch` directly, only so the
  # click carries a `JS.push` `:loading` target — `JS.patch/2` itself has no `:loading`
  # option (orchestrator amendment, loading state & latency).
  def handle_event("select_view", %{"view" => view}, socket) do
    {:noreply, push_patch(socket, to: ~p"/budget?view=#{view}")}
  end

  # -- live updates (XC-01, XC-02) ------------------------------------------------------

  # The snapshot itself genuinely changed — reload it, then recompute through the same
  # async path a preset/view change uses (orchestrator amendment), so a second tab's
  # edit dims this one's preset-dependent regions rather than freezing them.
  @impl true
  def handle_info({Realtime, _resource, _event}, socket) do
    {:noreply, socket |> load_snapshot() |> recompute()}
  end

  # -- the async view-model recompute (orchestrator amendment) -------------------------

  @impl true
  def handle_async(:build_overview, {:ok, {preset_id, view, overview}}, socket) do
    socket =
      if preset_id == socket.assigns.selected_preset_id and view == socket.assigns.view do
        socket |> assign(:overview, overview) |> assign(:recomputing, false)
      else
        # Stale — a newer selection is already in flight or about to be (defensive only,
        # see the moduledoc: `start_async/3` itself already discards this by name).
        socket
      end

    {:noreply, socket}
  end

  def handle_async(:build_overview, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :recomputing, false)}
  end

  # -- private --------------------------------------------------------------------------

  defp mark_formula_open(socket, nil), do: socket
  defp mark_formula_open(socket, id), do: update(socket, :open_formula_ids, &MapSet.put(&1, id))

  # Loads a fresh snapshot — only ever called at mount and on a `Realtime` message
  # (orchestrator amendment): a preset/view change reuses the snapshot already in
  # `@snapshot` and only recomputes the view model.
  defp load_snapshot(socket) do
    snapshot = Snapshot.load(Repo)
    today = TodoList.today(socket.assigns.time_zone)

    socket
    |> assign(:snapshot, snapshot)
    |> assign(:today, today)
    |> assign(:settings, snapshot.settings)
  end

  # The single entry point that (re)builds `@overview` from whatever `@snapshot` already
  # holds: synchronous the very first time (nothing to dim before the page has rendered
  # once), asynchronous every time after (orchestrator amendment) — dims the
  # preset-dependent regions via `@recomputing` while `WeddingPlannerWeb.BudgetOverview.build/4`
  # runs in its own task.
  defp recompute(socket) do
    if Map.has_key?(socket.assigns, :overview) do
      recompute_async(socket)
    else
      assign_overview_sync(socket)
    end
  end

  defp assign_overview_sync(socket) do
    socket
    |> assign(:overview, build_overview(socket.assigns))
    |> assign(:recomputing, false)
  end

  defp recompute_async(socket) do
    %{snapshot: snapshot, today: today, selected_preset_id: preset_id, view: view} =
      socket.assigns

    socket
    |> assign(:recomputing, true)
    |> start_async(:build_overview, fn ->
      {preset_id, view, BudgetOverview.build(snapshot, today, preset_id, view)}
    end)
  end

  defp build_overview(%{
         snapshot: snapshot,
         today: today,
         selected_preset_id: preset_id,
         view: view
       }) do
    BudgetOverview.build(snapshot, today, preset_id, view)
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
          <div class="flex flex-wrap items-center gap-2">
            <.button navigate={~p"/what-if"} id="budget-what-if">What if…</.button>
            <.export_link kind="budget" time_zone={@time_zone} />
          </div>

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
              phx-change={JS.push("select_preset", loading: loading_targets())}
              class="contents"
            >
              <div class="phx-change-loading:opacity-60 transition-opacity">
                <.preset_selector
                  id="budget-preset-selector"
                  presets={@overview.presets}
                  selected={@overview.selected_preset.id}
                />
              </div>
            </.form>
            <p class="mt-1 text-xs text-ink-faint">Used for calculations and charts; not saved</p>
            <p
              :if={@recomputing}
              id="budget-recomputing"
              aria-live="polite"
              class="mt-1 flex items-center gap-1.5 text-xs text-ink-faint"
            >
              <span
                class="size-3 shrink-0 animate-spin rounded-full border-2 border-ink-faint border-t-transparent"
                aria-hidden="true"
              ></span>
              Updating…
            </p>
            <%!-- The client-side twin of #budget-recomputing: every recomputing control's
                 JS.push names it as a loading target, so it shows from the click until the
                 reply is acknowledged, before the server's @recomputing can reach the page. --%>
            <p
              :if={!@recomputing}
              id="budget-updating"
              class="mt-1 hidden items-center gap-1.5 text-xs text-ink-faint phx-click-loading:flex phx-change-loading:flex"
            >
              <span
                class="size-3 shrink-0 animate-spin rounded-full border-2 border-ink-faint border-t-transparent"
                aria-hidden="true"
              ></span>
              Updating…
            </p>
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
                loading_target={loading_targets()}
                bad?={@overview.tiles.available.over_budget?}
              />
            </.tile>

            <.tile id="tile-forecast" label="Forecast">
              <.role_values
                id="tile-forecast-values"
                ranged={@overview.tiles.forecast.role_values}
                formula_id="budget-overall-forecast-formula"
                loading_target={loading_targets()}
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

          <div
            id="budget-overall-formulas"
            class={[
              "mt-4 space-y-3 transition-opacity phx-click-loading:opacity-50 phx-change-loading:opacity-50",
              @recomputing && "opacity-50"
            ]}
            aria-busy={to_string(@recomputing)}
          >
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

          <.view_switcher current={@overview.view} />

          <div
            id="budget-preset-dependent"
            class={[
              "transition-opacity phx-click-loading:opacity-50 phx-change-loading:opacity-50",
              @recomputing && "opacity-50"
            ]}
            aria-busy={to_string(@recomputing)}
          >
            <div :if={@overview.view == "category"} id="budget-charts" class="mt-6 space-y-6">
              <.composition_bar
                id="budget-composition"
                chart={@overview.charts.composition}
                preset_name={@overview.charts.preset_name}
              />
              <.category_bars
                id="budget-category-bars"
                chart={@overview.charts.categories}
                preset_name={@overview.charts.preset_name}
              />
            </div>

            <div :if={@overview.view == "category"} id="budget-categories" class="mt-6 space-y-3">
              <.category_card
                :for={card <- @overview.categories}
                card={card}
                snapshot={@snapshot}
                today={@today}
                open_formula_ids={@open_formula_ids}
              />
            </div>

            <.event_rows
              :if={@overview.view == "event"}
              rows={@overview.by_event}
              open_formula_ids={@open_formula_ids}
            />

            <.per_guest
              :if={@overview.view == "guest"}
              per_guest={@overview.per_guest}
              open_formula_ids={@open_formula_ids}
            />
          </div>

          <.cash_flow cash_flow={@overview.cash_flow} />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
