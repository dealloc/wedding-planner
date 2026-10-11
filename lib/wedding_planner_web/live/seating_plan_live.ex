defmodule WeddingPlannerWeb.Live.SeatingPlanLive do
  @moduledoc """
  `/seating/plan` — the computed seating plan, read-only (`docs/modules/seating.md`
  SEAT-50..SEAT-54, SEAT-70). Corrections from this screen (rules, pins, freezing) are
  the next slice; for now it links back to the inputs.

  ## Scenario

  `?event=…&preset=…`, per-view and never stored (SEAT-02, `HC-10`), the same parameters
  `/seating` uses, so the two screens link to each other without losing the scenario.

  ## Computing (SEAT-50)

  The plan is never stored. `recompute/1` loads a fresh snapshot in this process and runs
  the pure engines (`WeddingPlanner.Valuation.Seating.analyse/3`, `SeatingPlan.compute/2`
  and `WeddingPlannerWeb.SeatingOverview.plan/3`) in a `start_async/3` task, cancelling a
  computation still in flight first, so a burst of changes computes once for the latest
  data. While it runs the previous plan stays on screen, dimmed and marked as
  recalculating. Every broadcast that can change who is seated or how triggers it
  (`XC-01`); there is no other change indicator (`DR-21`).
  """
  use WeddingPlannerWeb, :live_view

  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Seating
  alias WeddingPlanner.Valuation.PresetChoice
  alias WeddingPlanner.Valuation.Seating, as: SeatingEngine
  alias WeddingPlanner.Valuation.SeatingPlan
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.SeatingOverview

  @subscriptions [
    :person,
    :group,
    :invitation,
    :plus_one_opt_out,
    :event,
    :headcount_preset,
    :circle,
    :seating_rule,
    :seating_table,
    :seating_pin
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Enum.each(@subscriptions, &Realtime.subscribe/1)

    {:ok,
     socket
     |> assign(:page_title, "Seating plan")
     |> assign(:plan, nil)
     |> assign(:computing?, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:event_id, params["event"])
     |> assign(:preset_id, params["preset"])
     |> recompute()}
  end

  @impl true
  def handle_event("select_scenario", params, socket) do
    event_id = params["event_id"] || socket.assigns.event_id
    preset_id = params["plan-preset-preset"] || socket.assigns.preset_id
    {:noreply, push_patch(socket, to: ~p"/seating/plan?#{[event: event_id, preset: preset_id]}")}
  end

  @impl true
  def handle_info({Realtime, _resource, _event}, socket), do: {:noreply, recompute(socket)}

  @impl true
  def handle_async(:plan, {:ok, plan}, socket) do
    {:noreply, assign(socket, plan: plan, computing?: false)}
  end

  def handle_async(:plan, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:computing?, false)
     |> put_flash(:error, "The plan could not be computed. Try again in a moment.")}
  end

  defp recompute(socket) do
    snapshot = Snapshot.load(Repo)
    event = find_by_id(snapshot.events, socket.assigns.event_id) || List.first(snapshot.events)
    preset = PresetChoice.find(snapshot.headcount_presets, socket.assigns.preset_id)

    socket =
      socket
      |> assign(:events, snapshot.events)
      |> assign(:event, event)
      |> assign(:presets, snapshot.headcount_presets)
      |> assign(:preset, preset)

    if event && preset do
      names = SeatingOverview.names(snapshot.persons, snapshot.circles, Seating.couple_name())
      tables = Enum.filter(snapshot.seating_tables, &(&1.event_id == event.id))
      table_ids = MapSet.new(tables, & &1.id)
      pins = Enum.filter(snapshot.seating_pins, &MapSet.member?(table_ids, &1.seating_table_id))

      socket
      |> cancel_async(:plan)
      |> assign(:computing?, true)
      |> start_async(:plan, fn ->
        analysis = SeatingEngine.analyse(snapshot, preset, event)
        SeatingOverview.plan(analysis, SeatingPlan.compute(analysis, tables, pins), names)
      end)
    else
      assign(socket, plan: nil, computing?: false)
    end
  end

  defp find_by_id(_list, nil), do: nil
  defp find_by_id(list, id), do: Enum.find(list, &(to_string(&1.id) == to_string(id)))

  # -- render --------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width="wide">
      <.header>
        Seating plan
        <:subtitle>
          Computed from your circles, rules and tables — never stored, so it is always current.
        </:subtitle>
        <:actions>
          <.button
            navigate={
              if @event && @preset,
                do: ~p"/seating?#{[event: @event.id, preset: @preset.id]}",
                else: ~p"/seating"
            }
            id="to-inputs"
          >
            <.icon name="hero-adjustments-horizontal" class="size-4" /> Circles, rules & tables
          </.button>
        </:actions>
      </.header>

      <p :if={@events == []} id="plan-no-events" class="mt-6 text-sm text-ink-soft">
        Add an event first: seating is worked out per event.
      </p>

      <form
        :if={@event && @preset}
        id="plan-scenario-form"
        phx-change="select_scenario"
        class="mt-2 flex flex-col gap-3 sm:flex-row sm:items-end"
      >
        <label for="plan-event" class="block sm:w-64">
          <span class="mb-1 block text-xs font-medium text-ink-faint">Event</span>
          <select
            name="event_id"
            id="plan-event"
            class="block min-h-11 w-full rounded-field border border-line-strong bg-surface-raised px-3 py-2 text-sm text-ink focus:border-accent focus:ring-2 focus:ring-accent focus:outline-none"
          >
            {Phoenix.HTML.Form.options_for_select(Enum.map(@events, &{&1.name, &1.id}), @event.id)}
          </select>
        </label>
        <div>
          <span class="mb-1 block text-xs font-medium text-ink-faint">Who is coming</span>
          <.preset_selector id="plan-preset" presets={@presets} selected={@preset.id} />
        </div>
        <p
          :if={@computing?}
          id="plan-computing"
          class="flex items-center gap-1.5 text-sm text-ink-faint sm:ml-auto"
        >
          <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" /> Recalculating…
        </p>
      </form>

      <div
        :if={@plan}
        id="plan"
        data-status={@plan.status}
        class={["mt-6 transition-opacity duration-200", @computing? && "opacity-60"]}
      >
        <.plan_problems status={@plan.status} problems={@plan.problems} />

        <p :if={@plan.used != []} id="plan-used" class="mb-4 text-sm text-ink-soft">
          <span class="font-medium text-ink">
            {length(Enum.reject(@plan.tables, &(&1.seats == 0)))} tables:
          </span>
          {Enum.join(@plan.used, ", ")}
        </p>

        <div
          :if={@plan.tables != []}
          id="plan-tables"
          class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3"
        >
          <.table_card :for={table <- @plan.tables} table={table} />
        </div>
      </div>

      <div
        :if={is_nil(@plan) and @computing?}
        id="plan-first-load"
        class="mt-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-3"
      >
        <div
          :for={_ <- 1..3}
          class="h-48 rounded-field border border-line bg-surface-raised motion-safe:animate-pulse"
        />
      </div>
    </Layouts.app>
    """
  end

  attr :status, :atom, required: true
  attr :problems, :list, required: true

  defp plan_problems(%{status: :ok} = assigns), do: ~H""

  defp plan_problems(assigns) do
    ~H"""
    <div
      id="plan-problems"
      role="alert"
      class={[
        "mb-6 rounded-field border p-4",
        if(@status == :blocked,
          do: "border-bad/30 bg-bad-soft",
          else: "border-warn/30 bg-warn-soft"
        )
      ]}
    >
      <p class="flex items-center gap-2 font-semibold text-ink">
        <.icon
          name={if @status == :blocked, do: "hero-x-circle", else: "hero-exclamation-triangle"}
          class={["size-5", if(@status == :blocked, do: "text-bad", else: "text-warn")]}
        />
        {if @status == :blocked,
          do: "No plan can be made yet",
          else: "No valid plan was found — this is the best attempt"}
      </p>
      <ul class="mt-2 space-y-1.5 pl-7">
        <li :for={problem <- @problems} id={problem.id} class="text-sm">
          <span class="font-medium text-ink">{problem.title}</span>
          <span class="text-ink-soft">— {problem.detail}</span>
        </li>
      </ul>
    </div>
    """
  end

  attr :table, :map, required: true

  defp table_card(assigns) do
    ~H"""
    <section
      id={"plan-table-#{@table.table.id}"}
      class={[
        "flex flex-col rounded-field border bg-surface-raised p-4 shadow-sm transition hover:shadow-md",
        if(@table.seats == 0, do: "border-dashed border-line-strong", else: "border-line")
      ]}
    >
      <header class="flex items-baseline justify-between gap-3">
        <h2 class="flex min-w-0 items-center gap-2 font-semibold text-ink">
          <span class="truncate">{@table.table.name}</span>
          <span
            :if={@table.table.source.kind == :fixed}
            class="shrink-0 rounded-chip bg-accent-soft px-2 py-0.5 text-xs font-medium text-accent"
          >
            Fixed
          </span>
        </h2>
        <p
          id={"plan-table-#{@table.table.id}-seats"}
          class={["shrink-0 text-sm tabular-nums", seat_tone(@table)]}
          title={"#{@table.table.min_seats}–#{@table.table.max_seats} seats"}
        >
          {@table.seats} / {@table.table.max_seats}
        </p>
      </header>
      <div class="mt-2 h-1 overflow-hidden rounded-full bg-surface" aria-hidden="true">
        <div
          class={["h-full rounded-full transition-all duration-300", seat_bar(@table)]}
          style={"width: #{min(100, round(@table.seats * 100 / max(@table.table.max_seats, 1)))}%"}
        />
      </div>

      <p :if={@table.seats == 0} class="mt-4 text-sm text-ink-faint">
        Empty — not needed for this scenario.
      </p>

      <ul :if={@table.seats > 0} class="mt-3 space-y-1.5">
        <li
          :for={unit <- @table.units}
          class={[
            length(unit) > 1 && "rounded-field border-l-2 border-accent/40 bg-surface/60 py-0.5 pl-2"
          ]}
        >
          <details
            :for={party <- unit}
            id={"plan-table-#{@table.table.id}-#{party.id}"}
            class="group rounded-field px-1 py-0.5 open:bg-surface"
          >
            <summary class="flex cursor-pointer list-none items-center justify-between gap-2 text-sm text-ink">
              <span class="truncate">
                <span :if={party.pinned?} title="Pinned here">
                  <.icon name="hero-map-pin" class="size-3.5 text-accent" />
                </span>
                {party.name}
                <span :if={party.seats > 1} class="text-ink-faint">· {party.seats} seats</span>
              </span>
              <span class="flex shrink-0 items-center gap-1">
                <.icon
                  :if={party.broken != []}
                  name="hero-exclamation-triangle"
                  class="size-4 text-warn"
                />
                <.icon
                  name="hero-chevron-down"
                  class="size-3.5 text-ink-faint transition group-open:rotate-180"
                />
              </span>
            </summary>
            <div class="mt-1 space-y-1 pb-1 text-xs">
              <p :if={party.knows != []} class="text-ink-soft">
                <span class="font-medium text-ink">Here with:</span> {Enum.join(party.knows, ", ")}
              </p>
              <p :if={party.knows == []} class="text-ink-faint">
                Nobody at this table pulls them here.
              </p>
              <p :for={rule <- party.broken} class="text-warn">
                <span class="font-medium">Not kept:</span> {rule}
              </p>
            </div>
          </details>
        </li>
      </ul>
    </section>
    """
  end

  defp seat_tone(%{seats: 0}), do: "text-ink-faint"

  defp seat_tone(%{seats: seats, table: table}) do
    if seats < table.min_seats or seats > table.max_seats,
      do: "text-bad font-semibold",
      else: "text-ink-soft"
  end

  defp seat_bar(%{seats: seats, table: table}) do
    cond do
      seats == 0 -> "bg-transparent"
      seats < table.min_seats or seats > table.max_seats -> "bg-bad"
      true -> "bg-good"
    end
  end
end
