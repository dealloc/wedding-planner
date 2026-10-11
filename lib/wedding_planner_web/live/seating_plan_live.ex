defmodule WeddingPlannerWeb.Live.SeatingPlanLive do
  @moduledoc """
  `/seating/plan` — the computed seating plan (`docs/modules/seating.md` SEAT-50..SEAT-54,
  SEAT-70) and the corrections made from it (SEAT-71).

  ## Corrections are inputs (SEAT-71)

  The plan is never edited or stored: every action here writes an input through
  `WeddingPlanner.Seating` and the plan recomputes from the broadcast.

    * **Rule between two people** — "Select" on two people opens `#plan-rule-panel`,
      pre-filled with the two of them, or with their existing rule (SEAT-30: at most one
      per pair) to edit.
    * **Move to…** — pins the person to a fixed table (SEAT-42; only fixed tables can be
      pinned to). Their unit follows. "Unpin" removes a direct pin.
    * **Pins when the plan has no tables** — a blocked or invalid plan shows no tables to
      correct from, so `#plan-pins` lists the event's pins by fixed table, each with
      "Unpin" and, per table, "Unfreeze" (`unpin`/`unfreeze`), next to the problem about
      that table (e.g. SEAT-61 below the minimum).
    * **Freeze / Unfreeze** (SEAT-44) — from the plan shown, held in the assigns, never a
      second computation. Offered only on a valid plan (`:ok`).

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
  alias WeddingPlanner.Seating.Pin
  alias WeddingPlanner.Seating.Rule
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
     |> assign(:pins, [])
     |> assign(:pin_groups, [])
     |> assign(:fixed_pinned, [])
     |> assign(:selected, [])
     |> assign(:rule_panel, nil)
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

  def handle_event("toggle_select", %{"key" => key}, socket) do
    selected = socket.assigns.selected

    selected =
      if Enum.any?(selected, &(&1.key == key)),
        do: Enum.reject(selected, &(&1.key == key)),
        else: Enum.take(selected ++ [%{key: key, name: party_name(socket.assigns.plan, key)}], -2)

    {:noreply, socket |> assign(:selected, selected) |> open_rule_panel()}
  end

  def handle_event("clear_selection", _params, socket),
    do: {:noreply, socket |> assign(:selected, []) |> open_rule_panel()}

  def handle_event("validate_rule", %{"rule" => params}, socket) do
    case socket.assigns.rule_panel do
      nil ->
        {:noreply, socket}

      panel ->
        form = rule_form(panel.rule, panel.keys, params)
        {:noreply, assign(socket, :rule_panel, %{panel | form: form})}
    end
  end

  def handle_event("save_rule", %{"rule" => params}, socket) do
    scope = socket.assigns.current_scope

    case socket.assigns.rule_panel do
      nil ->
        {:noreply, socket}

      %{rule: nil, keys: [a, b]} = panel ->
        attrs = Map.merge(params, %{"subject" => a, "object" => b})
        saved_rule(socket, panel, Seating.create_rule(scope, attrs), "Rule added.")

      %{rule: rule} = panel ->
        attrs = Map.take(params, ["relation", "reason"])
        saved_rule(socket, panel, Seating.update_rule(scope, rule, attrs), "Rule updated.")
    end
  end

  def handle_event("move", %{"key" => key, "table_id" => table_id}, socket)
      when table_id != "" do
    scope = socket.assigns.current_scope
    plan = socket.assigns.plan
    table = Enum.find(fixed_sources(plan), &(to_string(&1.id) == table_id))

    result =
      table && Seating.move_person(scope, table, key, unit_keys(plan, key))

    case result do
      {:ok, _pin} ->
        {:noreply,
         put_flash(socket, :info, "#{party_name(plan, key)} is pinned to #{table.name}.")}

      _ ->
        {:noreply,
         put_flash(socket, :error, "That can't be pinned there: only fixed tables can.")}
    end
  end

  def handle_event("move", _params, socket), do: {:noreply, socket}

  def handle_event("unpin_person", %{"key" => key}, socket) do
    case Enum.find(socket.assigns.pins, &(&1.target_key == key)) do
      nil ->
        {:noreply, put_flash(socket, :error, "That pin is already gone.")}

      pin ->
        {:ok, _} = Seating.unpin(socket.assigns.current_scope, pin)

        {:noreply,
         put_flash(socket, :info, "#{party_name(socket.assigns.plan, key)} is unpinned.")}
    end
  end

  def handle_event("unpin", %{"pin" => pin_id}, socket) do
    case Enum.find(socket.assigns.pins, &(to_string(&1.id) == pin_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "That pin is already gone.")}

      pin ->
        {:ok, _} = Seating.unpin(socket.assigns.current_scope, pin)
        {:noreply, put_flash(socket, :info, "Unpinned.")}
    end
  end

  def handle_event("freeze", %{"table" => plan_table_id}, socket) do
    %{plan: plan, pins: pins, event: event, current_scope: scope} = socket.assigns

    with %{table: table} = row <- Enum.find(plan.tables, &(&1.table.id == plan_table_id)),
         true <- plan.status == :ok do
      keys = freezable_keys(row, pins)

      case Seating.freeze_table(scope, event, table, keys) do
        {:ok, %{table: fixed, pinned: n}} ->
          {:noreply,
           put_flash(
             socket,
             :info,
             "#{fixed.name} is frozen: #{n} #{if n == 1, do: "pin", else: "pins"} added."
           )}

        {:error, :empty} ->
          {:noreply, put_flash(socket, :error, "Nobody to freeze at #{table.name}.")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           put_flash(socket, :error, "Could not freeze: #{changeset_message(changeset)}")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Only a valid plan can be frozen.")}
    end
  end

  def handle_event("unfreeze", %{"table" => table_id}, socket) do
    table =
      Enum.find(
        fixed_sources(socket.assigns.plan) ++ socket.assigns.fixed_pinned,
        &(to_string(&1.id) == table_id)
      )

    case table && Seating.unfreeze_table(socket.assigns.current_scope, table) do
      {:ok, 0} ->
        {:noreply, put_flash(socket, :info, "#{table.name} had no pins.")}

      {:ok, n} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "#{table.name} is unfrozen: #{n} #{if n == 1, do: "pin", else: "pins"} removed."
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Only a fixed table can be unfrozen.")}
    end
  end

  @impl true
  def handle_info({Realtime, _resource, _event}, socket), do: {:noreply, recompute(socket)}

  @impl true
  def handle_async(:plan, {:ok, {plan, pins, groups}}, socket) do
    {:noreply,
     assign(socket,
       plan: plan,
       pins: pins,
       pin_groups: groups,
       fixed_pinned: Enum.map(groups, & &1.table),
       computing?: false
     )}
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
        plan = SeatingOverview.plan(analysis, SeatingPlan.compute(analysis, tables, pins), names)
        {plan, pins, pin_groups(plan, tables, pins, names)}
      end)
    else
      assign(socket, plan: nil, pins: [], pin_groups: [], fixed_pinned: [], computing?: false)
    end
  end

  # The pins of the event by fixed table, with each pinned side's label and the problem
  # about that table (SEAT-61 pins below the minimum or above the maximum), if any.
  defp pin_groups(plan, tables, pins, names) do
    for table <- tables,
        table.kind == :fixed,
        table_pins = pins_of(pins, table),
        table_pins != [] do
      %{
        table: table,
        pins:
          for pin <- table_pins do
            %{pin: pin, label: SeatingOverview.name(names, Pin.side(pin))}
          end,
        problem:
          Enum.find(
            plan.problems,
            &(&1.id in ["problem-pinned-below-#{table.id}", "problem-pinned-above-#{table.id}"])
          )
      }
    end
  end

  defp pins_of(pins, table), do: Enum.filter(pins, &(&1.seating_table_id == table.id))

  # -- corrections (SEAT-71) -------------------------------------------------------------

  defp saved_rule(socket, _panel, {:ok, _rule}, message) do
    {:noreply,
     socket
     |> assign(:selected, [])
     |> assign(:rule_panel, nil)
     |> put_flash(:info, message)}
  end

  defp saved_rule(socket, panel, {:error, %Ecto.Changeset{} = changeset}, _message) do
    {:noreply, assign(socket, :rule_panel, %{panel | form: to_form(changeset)})}
  end

  # Two selected people open the panel on their rule, or on a blank one with both sides set.
  defp open_rule_panel(%{assigns: %{selected: [%{key: a}, %{key: b}]}} = socket) do
    rule = Seating.get_rule_between(a, b)
    keys = [a, b]

    assign(socket, :rule_panel, %{
      rule: rule,
      keys: keys,
      names: Enum.map(socket.assigns.selected, & &1.name),
      form: rule_form(rule, keys, %{})
    })
  end

  defp open_rule_panel(socket), do: assign(socket, :rule_panel, nil)

  defp rule_form(nil, [a, b], params) do
    attrs = Map.merge(params, %{"subject" => a, "object" => b})
    %Rule{} |> Seating.change_rule(attrs) |> to_form()
  end

  defp rule_form(%Rule{} = rule, _keys, params),
    do: rule |> Seating.change_rule(params) |> to_form()

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp parties(plan), do: for(row <- plan.tables, unit <- row.units, party <- unit, do: party)

  defp party_name(nil, _key), do: "That person"

  defp party_name(plan, key) do
    case Enum.find(parties(plan), &(&1.key == key)) do
      nil -> "That person"
      party -> party.name
    end
  end

  # The other members of `key`'s seating unit, as they sit in the shown plan.
  defp unit_keys(nil, _key), do: []

  defp unit_keys(plan, key) do
    plan.tables
    |> Enum.flat_map(& &1.units)
    |> Enum.find([], fn unit -> Enum.any?(unit, &(&1.key == key)) end)
    |> Enum.map(& &1.key)
    |> List.delete(key)
  end

  defp fixed_sources(nil), do: []

  defp fixed_sources(plan) do
    for %{table: %{source: source}} <- plan.tables, source.kind == :fixed, do: source
  end

  # Who Freeze pins on `row`: every party seated there, bar those already pinned to it
  # directly (a fixed table's own pins).
  defp freezable_keys(%{table: %{source: source}} = row, pins) do
    direct =
      for pin <- pins, pin.seating_table_id == source.id, into: MapSet.new(), do: pin.target_key

    for unit <- row.units, party <- unit, not MapSet.member?(direct, party.key), do: party.key
  end

  defp pin_count(pins, table_id), do: Enum.count(pins, &(&1.seating_table_id == table_id))

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

        <.pins_panel :if={@plan.status != :ok and @pin_groups != []} groups={@pin_groups} />

        <.selection_bar :if={@selected != [] and is_nil(@rule_panel)} selected={@selected} />
        <.rule_panel :if={@rule_panel} panel={@rule_panel} />

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
          <.table_card
            :for={table <- @plan.tables}
            table={table}
            status={@plan.status}
            pins={@pins}
            selected={@selected}
            fixed_tables={fixed_sources(@plan)}
          />
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

  attr :groups, :list, required: true

  defp pins_panel(assigns) do
    ~H"""
    <section id="plan-pins" class="mb-6 rounded-field border border-line bg-surface-raised p-4">
      <h2 class="font-semibold text-ink">Pins</h2>
      <p class="mt-1 text-sm text-ink-soft">
        Pins are inputs: undo one here and the plan recomputes.
      </p>
      <div
        :for={group <- @groups}
        id={"plan-pins-table-#{group.table.id}"}
        class="mt-3 border-t border-line pt-3"
      >
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h3 class="font-medium text-ink">
            {group.table.name}
            <span class="text-sm font-normal text-ink-faint">
              · {group.table.min_seats}–{group.table.max_seats} seats
            </span>
          </h3>
          <button
            type="button"
            id={"plan-pins-unfreeze-#{group.table.id}"}
            phx-click="unfreeze"
            phx-value-table={group.table.id}
            class={secondary_button_class(:small)}
          >
            <.icon name="hero-lock-open" class="size-4" /> Unfreeze
          </button>
        </div>
        <p
          :if={group.problem}
          id={"plan-pins-problem-#{group.table.id}"}
          class="mt-1 text-sm text-bad"
        >
          {group.problem.title}
        </p>
        <ul class="mt-2 space-y-1.5">
          <li
            :for={entry <- group.pins}
            id={"plan-pin-#{entry.pin.id}"}
            class="flex items-center justify-between gap-2 text-sm text-ink"
          >
            <span class="truncate">
              <.icon name="hero-map-pin" class="size-3.5 text-accent" /> {entry.label}
            </span>
            <button
              type="button"
              id={"plan-pin-#{entry.pin.id}-unpin"}
              phx-click="unpin"
              phx-value-pin={entry.pin.id}
              class={secondary_button_class(:small)}
            >
              Unpin
            </button>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :selected, :list, required: true

  defp selection_bar(assigns) do
    ~H"""
    <div
      id="plan-selection"
      class="mb-4 flex flex-wrap items-center gap-3 rounded-field border border-accent/30 bg-accent-soft px-4 py-3 text-sm"
    >
      <p class="text-ink">
        <span class="font-medium">{Enum.map_join(@selected, ", ", & &1.name)}</span>
        selected — pick one more person to set a rule between them.
      </p>
      <button
        type="button"
        id="plan-selection-clear"
        phx-click="clear_selection"
        class={[secondary_button_class(), "ml-auto"]}
      >
        Clear
      </button>
    </div>
    """
  end

  attr :panel, :map, required: true

  defp rule_panel(assigns) do
    ~H"""
    <section
      id="plan-rule-panel"
      data-mode={if @panel.rule, do: "edit", else: "create"}
      class="mb-6 rounded-field border border-accent/30 bg-surface-raised p-4 shadow-sm"
    >
      <h2 class="font-semibold text-ink">
        {if @panel.rule, do: "Edit the rule between", else: "New rule between"}
        <span id="plan-rule-names">{Enum.join(@panel.names, " and ")}</span>
      </h2>
      <p class="mt-1 text-sm text-ink-soft">
        A rule is an input: the plan recomputes once you save it.
      </p>
      <.form
        for={@panel.form}
        id="plan-rule-form"
        phx-change="validate_rule"
        phx-submit="save_rule"
        class="mt-3 grid gap-3 sm:grid-cols-3 sm:items-start"
      >
        <.input field={@panel.form[:subject]} type="hidden" id="plan-rule-subject" />
        <.input field={@panel.form[:object]} type="hidden" id="plan-rule-object" />
        <.input
          field={@panel.form[:relation]}
          type="select"
          options={relation_options()}
          prompt="…relation…"
          id="plan-rule-relation"
          aria-label="Relation"
        />
        <div class="sm:col-span-2">
          <.input
            field={@panel.form[:reason]}
            type="text"
            placeholder="Why? (optional)"
            id="plan-rule-reason"
            aria-label="Reason"
          />
        </div>
        <div class="flex gap-2 sm:col-span-3">
          <.button variant="primary" id="plan-rule-submit">
            {if @panel.rule, do: "Save rule", else: "Add rule"}
          </.button>
          <button
            type="button"
            id="plan-rule-cancel"
            phx-click="clear_selection"
            class={secondary_button_class()}
          >
            Cancel
          </button>
        </div>
      </.form>
    </section>
    """
  end

  defp relation_options do
    Enum.map(Rule.relations(), &{relation_hint(&1), &1})
  end

  defp relation_hint(:always_with), do: "always with — hard: one unit"
  defp relation_hint(:seat_with), do: "seat with — strong pull"
  defp relation_hint(:keep_apart), do: "keep apart — strong push"
  defp relation_hint(:never_with), do: "never with — hard: different tables"

  # `.button/1` takes no `type`: a plain button for anything inside a form or inline.
  defp secondary_button_class(size \\ :normal) do
    [
      "inline-flex items-center justify-center gap-2 rounded-field text-sm font-semibold cursor-pointer",
      "transition-all duration-150 ease-out active:scale-[0.98] focus-visible:outline-none",
      "focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-paper",
      "bg-transparent text-ink border border-line-strong hover:bg-surface active:bg-line",
      if(size == :small, do: "min-h-9 px-3", else: "min-h-11 px-4")
    ]
    |> Enum.join(" ")
  end

  attr :table, :map, required: true
  attr :status, :atom, required: true
  attr :pins, :list, required: true
  attr :selected, :list, required: true
  attr :fixed_tables, :list, required: true

  defp table_card(assigns) do
    direct = for pin <- assigns.pins, into: %{}, do: {pin.target_key, pin}
    source = assigns.table.table.source

    assigns =
      assigns
      |> assign(:direct, direct)
      |> assign(:fixed?, source.kind == :fixed)
      |> assign(:pin_count, pin_count(assigns.pins, source.id))
      |> assign(
        :freezable?,
        assigns.status == :ok and assigns.table.seats > 0 and
          freezable_keys(assigns.table, assigns.pins) != []
      )

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

      <div :if={@freezable? or (@fixed? and @pin_count > 0)} class="mt-3 flex flex-wrap gap-2">
        <button
          :if={@freezable?}
          type="button"
          id={"freeze-#{@table.table.id}"}
          phx-click="freeze"
          phx-value-table={@table.table.id}
          class={secondary_button_class(:small)}
        >
          <.icon name="hero-lock-closed" class="size-4" /> Freeze
        </button>
        <button
          :if={@fixed? and @pin_count > 0}
          type="button"
          id={"unfreeze-#{@table.table.id}"}
          phx-click="unfreeze"
          phx-value-table={@table.table.source.id}
          class={secondary_button_class(:small)}
        >
          <.icon name="hero-lock-open" class="size-4" /> Unfreeze
        </button>
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
                <span :if={Enum.any?(@selected, &(&1.key == party.key))} title="Selected">
                  <.icon name="hero-check-circle" class="size-3.5 text-accent" />
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
              <.party_actions
                party={party}
                unit={unit}
                table={@table}
                direct={@direct}
                selected={@selected}
                fixed_tables={@fixed_tables}
              />
            </div>
          </details>
        </li>
      </ul>
    </section>
    """
  end

  attr :party, :map, required: true
  attr :unit, :list, required: true
  attr :table, :map, required: true
  attr :direct, :map, required: true
  attr :selected, :list, required: true
  attr :fixed_tables, :list, required: true

  defp party_actions(assigns) do
    prefix = "plan-table-#{assigns.table.table.id}-#{assigns.party.id}"
    # Pinned, yet not by a pin on anyone in the unit: a circle pins them (SEAT-42).
    circle_pinned? =
      assigns.party.pinned? and not Enum.any?(assigns.unit, &Map.has_key?(assigns.direct, &1.key))

    targets =
      Enum.reject(assigns.fixed_tables, &(&1.id == assigns.table.table.source.id))

    assigns =
      assigns
      |> assign(:prefix, prefix)
      |> assign(:selected?, Enum.any?(assigns.selected, &(&1.key == assigns.party.key)))
      |> assign(:circle_pinned?, circle_pinned?)
      |> assign(:targets, targets)

    ~H"""
    <div class="flex flex-wrap items-center gap-2 pt-1">
      <button
        type="button"
        id={"#{@prefix}-select"}
        phx-click="toggle_select"
        phx-value-key={@party.key}
        aria-pressed={to_string(@selected?)}
        class={secondary_button_class(:small)}
      >
        <.icon
          name={if @selected?, do: "hero-check-circle", else: "hero-plus-circle"}
          class="size-4"
        />
        {if @selected?, do: "Selected", else: "Select"}
      </button>
      <form
        :if={@targets != [] and not @circle_pinned?}
        id={"#{@prefix}-move-form"}
        phx-change="move"
        class="inline-block"
      >
        <input type="hidden" name="key" value={@party.key} />
        <select
          name="table_id"
          id={"#{@prefix}-move-select"}
          aria-label={"Move #{@party.name} to"}
          class="min-h-9 rounded-field border border-line-strong bg-surface-raised px-2.5 py-1 text-sm text-ink focus:border-accent focus:ring-2 focus:ring-accent focus:outline-none"
        >
          <option value="">Move to…</option>
          {Phoenix.HTML.Form.options_for_select(Enum.map(@targets, &{&1.name, &1.id}), nil)}
        </select>
      </form>
      <button
        :if={Map.has_key?(@direct, @party.key)}
        type="button"
        id={"#{@prefix}-unpin"}
        phx-click="unpin_person"
        phx-value-key={@party.key}
        class={secondary_button_class(:small)}
      >
        <.icon name="hero-map-pin" class="size-4" /> Unpin
      </button>
    </div>
    <p
      :if={@fixed_tables == []}
      id={"#{@prefix}-move-hint"}
      class="text-ink-faint"
    >
      Moving someone needs a fixed table: freeze a table first.
    </p>
    <p :if={@circle_pinned?} id={"#{@prefix}-circle-pinned"} class="text-ink-faint">
      Pinned through a circle or their unit: change that pin on the inputs screen.
    </p>
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
