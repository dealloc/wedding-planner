defmodule WeddingPlannerWeb.Live.SeatingLive do
  @moduledoc """
  `/seating` — the seating input screen, slice 1 (`docs/modules/seating.md` SEAT-02,
  SEAT-20..SEAT-35, SEAT-60..SEAT-62): circles and their members, seating rules, and a
  live health panel for one scenario. Tables, pins and the plan itself come in the next
  slice.

  ## The scenario (SEAT-02, `HC-10`)

  An event and a headcount preset, both **per-view and not persisted**: the event defaults
  to the first in `EVT-04` order, the preset to *Likely*
  (`WeddingPlanner.Valuation.PresetChoice.default/1`). They only change what the health
  panel evaluates — circles and rules hold for every event.

  ## Data (SEAT-50: computed, never stored)

  `refresh/1` reloads the snapshot and recomputes `WeddingPlanner.Valuation.Seating.analyse/3`
  plus `WeddingPlannerWeb.SeatingOverview`'s view model, on mount and on every broadcast
  that can change who is seated or how (`XC-01`). No change indicator (`DR-21`).

  Circles and rules are small, bounded lists rendered from plain assigns, like the
  headcount overview: every broadcast recomputes the analysis anyway, and the rule list's
  sentences depend on names from the whole snapshot.

  ## Editing

  One circle editor and one rule editor at a time. The rule form both creates and edits
  (`@editing_rule_id`); the circle list's *Edit* swaps that circle's header for a form.
  Deletes go through `CoreComponents.destructive_confirm/1` with the context's effects.
  *Fine anywhere* is toggled from the health panel through `Guests.update_person/3`.
  """
  use WeddingPlannerWeb, :live_view

  alias WeddingPlanner.Guests
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Seating
  alias WeddingPlanner.Seating.Circle
  alias WeddingPlanner.Seating.Rule
  alias WeddingPlanner.Seating.Table
  alias WeddingPlanner.Valuation.PresetChoice
  alias WeddingPlanner.Valuation.Seating, as: SeatingEngine
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

    socket =
      socket
      |> assign(:page_title, "Seating")
      |> assign(:event_id, nil)
      |> assign(:preset_id, nil)
      |> assign(:circle_form, new_circle_form())
      |> assign(:editing_circle_id, nil)
      |> assign(:edit_circle_form, nil)
      |> assign(:confirming_circle_id, nil)
      |> assign(:editing_rule_id, nil)
      |> assign(:rule_form, rule_form(%Rule{}))
      |> assign(:confirming_rule_id, nil)
      |> assign(:table_form, new_table_form())
      |> assign(:editing_table_id, nil)
      |> assign(:edit_table_form, nil)
      |> assign(:confirming_table_id, nil)

    {:ok, socket}
  end

  # The scenario lives in the URL (`?event=…&preset=…`) so the plan view's link keeps it;
  # it is still per-view and never stored (HC-10).
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:event_id, params["event"])
     |> assign(:preset_id, params["preset"])
     |> refresh()}
  end

  # -- scenario ------------------------------------------------------------------------

  @impl true
  def handle_event("select_scenario", params, socket) do
    event_id = params["event_id"] || socket.assigns.event_id
    preset_id = params["seating-preset-preset"] || socket.assigns.preset_id

    {:noreply, push_patch(socket, to: ~p"/seating?#{[event: event_id, preset: preset_id]}")}
  end

  # -- tables (SEAT-40) ------------------------------------------------------------------

  def handle_event("validate_table", %{"table" => params}, socket) do
    form = %Table{} |> Seating.change_table(params) |> Map.put(:action, :validate) |> to_form()
    {:noreply, assign(socket, :table_form, form)}
  end

  def handle_event("add_table", %{"table" => params}, socket) do
    case Seating.create_table(socket.assigns.current_scope, socket.assigns.event, params) do
      {:ok, _table} ->
        {:noreply, socket |> assign(:table_form, new_table_form()) |> refresh()}

      {:error, changeset} ->
        {:noreply, assign(socket, :table_form, to_form(changeset))}
    end
  end

  def handle_event("edit_table", %{"id" => id}, socket) do
    table = Seating.get_table!(id)

    {:noreply,
     socket
     |> assign(:editing_table_id, table.id)
     |> assign(:edit_table_form, to_form(Seating.change_table(table), as: :edit_table))}
  end

  def handle_event("cancel_edit_table", _params, socket) do
    {:noreply, assign(socket, editing_table_id: nil, edit_table_form: nil)}
  end

  def handle_event("update_table", %{"edit_table" => params}, socket) do
    table = Seating.get_table!(socket.assigns.editing_table_id)

    case Seating.update_table(socket.assigns.current_scope, table, params) do
      {:ok, _} ->
        {:noreply, socket |> assign(editing_table_id: nil, edit_table_form: nil) |> refresh()}

      {:error, changeset} ->
        {:noreply, assign(socket, :edit_table_form, to_form(changeset, as: :edit_table))}
    end
  end

  # -- pins (SEAT-42) ---------------------------------------------------------------------

  def handle_event("pin", %{"table_id" => table_id, "side" => side}, socket) when side != "" do
    table = Seating.get_table!(table_id)

    case Seating.pin(socket.assigns.current_scope, table, side) do
      {:ok, _pin} ->
        {:noreply, refresh(socket)}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "That can't be pinned there.") |> refresh()}
    end
  end

  def handle_event("pin", _params, socket), do: {:noreply, socket}

  def handle_event("unpin", %{"id" => id}, socket) do
    {:ok, _} = Seating.unpin(socket.assigns.current_scope, Seating.get_pin!(id))
    {:noreply, refresh(socket)}
  end

  def handle_event("confirm_delete_table", %{"id" => id}, socket) do
    {:noreply, assign(socket, :confirming_table_id, String.to_integer(id))}
  end

  def handle_event("cancel_delete_table", _params, socket) do
    {:noreply, assign(socket, :confirming_table_id, nil)}
  end

  def handle_event("delete_table", %{"id" => id}, socket) do
    {:ok, _} = Seating.delete_table(socket.assigns.current_scope, Seating.get_table!(id))
    {:noreply, socket |> assign(:confirming_table_id, nil) |> refresh()}
  end

  # -- circles -------------------------------------------------------------------------

  def handle_event("validate_circle", %{"circle" => params}, socket) do
    form = %Circle{} |> Seating.change_circle(params) |> Map.put(:action, :validate) |> to_form()
    {:noreply, assign(socket, :circle_form, form)}
  end

  def handle_event("create_circle", %{"circle" => params}, socket) do
    case Seating.create_circle(socket.assigns.current_scope, params) do
      {:ok, _circle} -> {:noreply, socket |> assign(:circle_form, new_circle_form()) |> refresh()}
      {:error, changeset} -> {:noreply, assign(socket, :circle_form, to_form(changeset))}
    end
  end

  def handle_event("edit_circle", %{"id" => id}, socket) do
    circle = find_circle(socket, id)

    {:noreply,
     socket
     |> assign(:editing_circle_id, circle.id)
     |> assign(:edit_circle_form, to_form(Seating.change_circle(circle), as: :edit_circle))}
  end

  def handle_event("cancel_edit_circle", _params, socket) do
    {:noreply, assign(socket, editing_circle_id: nil, edit_circle_form: nil)}
  end

  def handle_event("update_circle", %{"edit_circle" => params}, socket) do
    circle = find_circle(socket, socket.assigns.editing_circle_id)

    case Seating.update_circle(socket.assigns.current_scope, circle, params) do
      {:ok, _} ->
        {:noreply, socket |> assign(editing_circle_id: nil, edit_circle_form: nil) |> refresh()}

      {:error, changeset} ->
        {:noreply, assign(socket, :edit_circle_form, to_form(changeset, as: :edit_circle))}
    end
  end

  def handle_event("confirm_delete_circle", %{"id" => id}, socket) do
    {:noreply, assign(socket, :confirming_circle_id, String.to_integer(id))}
  end

  def handle_event("cancel_delete_circle", _params, socket) do
    {:noreply, assign(socket, :confirming_circle_id, nil)}
  end

  def handle_event("delete_circle", %{"id" => id}, socket) do
    socket = assign(socket, :confirming_circle_id, nil)

    case Seating.delete_circle(socket.assigns.current_scope, find_circle(socket, id)) do
      {:ok, _} ->
        {:noreply, refresh(socket)}

      {:error, :built_in} ->
        {:noreply, put_flash(socket, :error, "The wedding party is built in.")}
    end
  end

  def handle_event("add_member", %{"circle_id" => circle_id, "member" => member}, socket) do
    circle = find_circle(socket, circle_id)
    scope = socket.assigns.current_scope

    _ =
      case member do
        "person:" <> id -> Seating.add_member(scope, circle, Guests.get_person!(id))
        "group:" <> id -> Seating.add_group_members(scope, circle, Guests.get_group!(id))
        _ -> :ignore
      end

    {:noreply, refresh(socket)}
  end

  def handle_event("remove_member", %{"circle_id" => circle_id, "person_id" => person_id}, socket) do
    circle = find_circle(socket, circle_id)

    {:ok, _} =
      Seating.remove_member(socket.assigns.current_scope, circle, Guests.get_person!(person_id))

    {:noreply, refresh(socket)}
  end

  # -- rules ---------------------------------------------------------------------------

  def handle_event("validate_rule", %{"rule" => params}, socket) do
    form =
      socket.assigns.editing_rule_id
      |> editing_rule()
      |> Seating.change_rule(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :rule_form, form)}
  end

  def handle_event("save_rule", %{"rule" => params}, socket) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.editing_rule_id do
        nil -> Seating.create_rule(scope, params)
        id -> Seating.update_rule(scope, Seating.get_rule!(id), params)
      end

    case result do
      {:ok, _rule} ->
        {:noreply, socket |> assign(:editing_rule_id, nil) |> reset_rule_form() |> refresh()}

      {:error, changeset} ->
        {:noreply, assign(socket, :rule_form, to_form(changeset))}
    end
  end

  def handle_event("edit_rule", %{"id" => id}, socket) do
    rule = Seating.get_rule!(id)
    {:noreply, socket |> assign(:editing_rule_id, rule.id) |> assign(:rule_form, rule_form(rule))}
  end

  def handle_event("cancel_edit_rule", _params, socket) do
    {:noreply, socket |> assign(:editing_rule_id, nil) |> reset_rule_form()}
  end

  def handle_event("confirm_delete_rule", %{"id" => id}, socket) do
    {:noreply, assign(socket, :confirming_rule_id, String.to_integer(id))}
  end

  def handle_event("cancel_delete_rule", _params, socket) do
    {:noreply, assign(socket, :confirming_rule_id, nil)}
  end

  def handle_event("delete_rule", %{"id" => id}, socket) do
    {:ok, _} = Seating.delete_rule(socket.assigns.current_scope, Seating.get_rule!(id))

    socket =
      if to_string(socket.assigns.editing_rule_id) == id,
        do: socket |> assign(:editing_rule_id, nil) |> reset_rule_form(),
        else: socket

    {:noreply, socket |> assign(:confirming_rule_id, nil) |> refresh()}
  end

  # -- fine anywhere (SEAT-35) --------------------------------------------------------

  def handle_event("set_fine_anywhere", %{"id" => id, "value" => value}, socket) do
    person = Guests.get_person!(id)

    {:ok, _} =
      Guests.update_person(socket.assigns.current_scope, person, %{"fine_anywhere" => value})

    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_info({Realtime, _resource, _event}, socket), do: {:noreply, refresh(socket)}

  # -- data ----------------------------------------------------------------------------

  defp refresh(socket) do
    snapshot = Snapshot.load(Repo)
    circles = Seating.list_circles()
    rules = Seating.list_rules()
    names = SeatingOverview.names(snapshot.persons, circles, Seating.couple_name())

    event = find_by_id(snapshot.events, socket.assigns.event_id) || List.first(snapshot.events)
    preset = PresetChoice.find(snapshot.headcount_presets, socket.assigns.preset_id)

    tables =
      if event, do: Enum.filter(snapshot.seating_tables, &(&1.event_id == event.id)), else: []

    table_ids = MapSet.new(tables, & &1.id)
    pins = Enum.filter(snapshot.seating_pins, &MapSet.member?(table_ids, &1.seating_table_id))

    health =
      if event && preset,
        do:
          SeatingOverview.health(
            SeatingEngine.analyse(snapshot, preset, event),
            tables,
            pins,
            names
          )

    socket
    |> assign(:events, snapshot.events)
    |> assign(:event, event)
    |> assign(:event_id, event && to_string(event.id))
    |> assign(:presets, snapshot.headcount_presets)
    |> assign(:preset, preset)
    |> assign(:preset_id, preset && to_string(preset.id))
    |> assign(:tables, tables)
    |> assign(:pins_by_table, Enum.group_by(pins, & &1.seating_table_id))
    |> assign(:derived_members, derived_members(snapshot.persons, names))
    |> assign(:circles, circles)
    |> assign(:rules, rules)
    |> assign(:names, names)
    |> assign(:health, health)
    |> assign(:flagged_rule_ids, flagged_rule_ids(health))
    |> assign(:side_options, side_options(snapshot.persons, circles, names))
    |> assign(:member_options, member_options(snapshot.persons, Guests.list_groups(), names))
  end

  # SEAT-24: the wedding party's derived members — the couple and every witness.
  defp derived_members(persons, names) do
    witnesses =
      for p <- persons,
          p.witness_of_id,
          do: {"person-#{p.id}", SeatingOverview.name(names, {:person, p.id})}

    [{"couple", SeatingOverview.name(names, :couple)} | Enum.sort_by(witnesses, &elem(&1, 1))]
  end

  defp find_by_id(_list, nil), do: nil
  defp find_by_id(list, id), do: Enum.find(list, &(to_string(&1.id) == to_string(id)))

  defp find_circle(socket, id),
    do: find_by_id(socket.assigns.circles, id) || Seating.get_circle!(id)

  defp flagged_rule_ids(nil), do: MapSet.new()

  defp flagged_rule_ids(health) do
    blocking = health.blocking |> Enum.map(& &1.rule_id) |> Enum.reject(&is_nil/1)
    warnings = Enum.flat_map(health.warnings, & &1.rule_ids)
    MapSet.new(blocking ++ warnings)
  end

  defp new_table_form do
    %Table{}
    |> Seating.change_table(%{"kind" => "type", "min_seats" => 8, "max_seats" => 10})
    |> to_form()
  end

  defp kind_options,
    do: [{"Table type — as many as needed", :type}, {"Fixed table — one specific table", :fixed}]

  defp new_circle_form,
    do: to_form(Seating.change_circle(%Circle{}, %{"cohesion" => "like_together"}))

  defp rule_form(%Rule{} = rule), do: rule |> Seating.change_rule() |> to_form()

  defp reset_rule_form(socket), do: assign(socket, :rule_form, rule_form(%Rule{}))

  defp editing_rule(nil), do: %Rule{}
  defp editing_rule(id), do: Seating.get_rule!(id)

  defp side_options(persons, circles, names) do
    [
      {"The couple", [{SeatingOverview.name(names, :couple), "couple"}]},
      {"Circles", Enum.map(circles, &{&1.name, Rule.side_key({:circle, &1.id})})},
      {"People", person_options(persons, names, &Rule.side_key({:person, &1}))}
    ]
    |> Enum.reject(fn {_label, options} -> options == [] end)
  end

  defp member_options(persons, groups, names) do
    [
      {"Everyone in a group", Enum.map(groups, &{&1.name, "group:#{&1.id}"})},
      {"A person", person_options(persons, names, &"person:#{&1}")}
    ]
    |> Enum.reject(fn {_label, options} -> options == [] end)
  end

  defp person_options(persons, names, value_fun) do
    # Named people first, alphabetically; unnamed +1s ("+1 of …") after them.
    persons
    |> Enum.sort_by(&{Person.plus_one?(&1) and not Person.name_known?(&1), sort_name(names, &1)})
    |> Enum.map(&{SeatingOverview.name(names, {:person, &1.id}), value_fun.(&1.id)})
  end

  defp sort_name(names, person),
    do: names |> SeatingOverview.name({:person, person.id}) |> String.downcase()

  defp cohesion_options, do: Enum.map(Circle.cohesions(), &{Circle.cohesion_label(&1), &1})

  defp relation_options do
    Enum.map(Rule.relations(), &{relation_hint(&1), &1})
  end

  defp relation_hint(:always_with), do: "always with — hard: one unit"
  defp relation_hint(:seat_with), do: "seat with — strong pull"
  defp relation_hint(:keep_apart), do: "keep apart — strong push"
  defp relation_hint(:never_with), do: "never with — hard: different tables"

  # -- render --------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width="wide">
      <.header>
        Seating
        <:subtitle>
          Who knows whom, and who should or must not sit together. The plan is computed from this.
        </:subtitle>
        <:actions>
          <.button
            :if={@event && @preset}
            variant="primary"
            navigate={~p"/seating/plan?#{[event: @event.id, preset: @preset.id]}"}
            id="to-plan"
          >
            See the plan <.icon name="hero-arrow-right" class="size-4" />
          </.button>
        </:actions>
      </.header>

      <div class="mt-6 grid gap-8 lg:grid-cols-[minmax(0,1fr)_22rem]">
        <div class="min-w-0 space-y-10">
          <.tables_section
            :if={@event}
            event={@event}
            tables={@tables}
            pins_by_table={@pins_by_table}
            names={@names}
            side_options={@side_options}
            table_form={@table_form}
            editing_table_id={@editing_table_id}
            edit_table_form={@edit_table_form}
            confirming_table_id={@confirming_table_id}
          />

          <.circles_section
            circles={@circles}
            names={@names}
            derived_members={@derived_members}
            circle_form={@circle_form}
            editing_circle_id={@editing_circle_id}
            edit_circle_form={@edit_circle_form}
            confirming_circle_id={@confirming_circle_id}
            member_options={@member_options}
          />

          <.rules_section
            rules={@rules}
            names={@names}
            rule_form={@rule_form}
            editing_rule_id={@editing_rule_id}
            confirming_rule_id={@confirming_rule_id}
            side_options={@side_options}
            flagged_rule_ids={@flagged_rule_ids}
          />
        </div>

        <aside class="lg:sticky lg:top-6 lg:self-start">
          <.health_panel
            events={@events}
            event={@event}
            presets={@presets}
            preset={@preset}
            health={@health}
          />
        </aside>
      </div>
    </Layouts.app>
    """
  end

  # -- tables section (SEAT-40, SEAT-45) ------------------------------------------------

  attr :event, :any, required: true
  attr :tables, :list, required: true
  attr :pins_by_table, :map, required: true
  attr :names, :map, required: true
  attr :side_options, :list, required: true
  attr :table_form, :any, required: true
  attr :editing_table_id, :any, required: true
  attr :edit_table_form, :any, required: true
  attr :confirming_table_id, :any, required: true

  defp tables_section(assigns) do
    ~H"""
    <section id="tables-section" aria-labelledby="tables-heading">
      <div class="flex items-baseline justify-between gap-4">
        <h2 id="tables-heading" class="text-sm font-semibold tracking-wide text-ink-soft uppercase">
          Tables · {@event.name}
        </h2>
        <p class="text-sm text-ink-faint">
          The sizes the venue has. The plan works out how many it needs.
        </p>
      </div>

      <.form
        for={@table_form}
        id="table-form"
        phx-change="validate_table"
        phx-submit="add_table"
        class="mt-4 grid grid-cols-2 gap-3 rounded-field border border-dashed border-line-strong p-4 sm:grid-cols-6 sm:items-start"
      >
        <div class="col-span-2 sm:col-span-3">
          <.input
            field={@table_form[:kind]}
            type="select"
            options={kind_options()}
            label="Kind"
            id="table-form-kind"
          />
        </div>
        <div class="col-span-2 sm:col-span-3">
          <.input
            field={@table_form[:name]}
            type="text"
            label="Name"
            placeholder={if fixed_form?(@table_form), do: "e.g. Head table", else: "e.g. Round"}
            id="table-form-name"
          />
        </div>
        <.input
          field={@table_form[:min_seats]}
          type="number"
          min="1"
          label="Min seats"
          id="table-form-min"
        />
        <.input
          field={@table_form[:max_seats]}
          type="number"
          min="1"
          label="Max seats"
          id="table-form-max"
        />
        <div :if={!fixed_form?(@table_form)} class="col-span-2">
          <.input
            field={@table_form[:limit]}
            type="number"
            min="1"
            label="At most (optional)"
            placeholder="no limit"
            id="table-form-limit"
          />
        </div>
        <div class={["col-span-2 sm:pt-6", fixed_form?(@table_form) && "sm:col-span-4"]}>
          <.button variant="primary" id="table-form-submit">
            {if fixed_form?(@table_form), do: "Add fixed table", else: "Add table type"}
          </.button>
        </div>
      </.form>

      <ul id="tables" class="mt-4 grid gap-2 sm:grid-cols-2">
        <li
          :if={@tables == []}
          id="tables-empty"
          class="rounded-field border border-dashed border-line-strong p-6 text-center text-sm text-ink-faint sm:col-span-2"
        >
          No tables for {@event.name} yet. Add the sizes the venue offers — and, if you like, a fixed table for the two of you.
        </li>
        <li
          :for={table <- @tables}
          id={"table-#{table.id}"}
          data-kind={table.kind}
          class="rounded-field border border-line bg-surface-raised p-3 transition hover:border-line-strong"
        >
          <div :if={@editing_table_id != table.id} class="flex items-center justify-between gap-3">
            <div class="min-w-0">
              <p class="flex items-center gap-2">
                <span id={"table-#{table.id}-name"} class="truncate font-semibold text-ink">
                  {table.name}
                </span>
                <span class={[
                  "shrink-0 rounded-chip px-2 py-0.5 text-xs font-medium",
                  if(Table.fixed?(table),
                    do: "bg-accent-soft text-accent",
                    else: "bg-info-soft text-info"
                  )
                ]}>
                  {if Table.fixed?(table), do: "Fixed", else: "Type"}
                </span>
              </p>
              <p id={"table-#{table.id}-seats"} class="text-sm text-ink-soft">
                {table_line(table)}
              </p>
            </div>
            <div class="flex shrink-0 items-center gap-2">
              <.button phx-click="edit_table" phx-value-id={table.id} id={"table-#{table.id}-edit"}>
                Edit
              </.button>
              <.button
                variant="destructive"
                phx-click="confirm_delete_table"
                phx-value-id={table.id}
                id={"table-#{table.id}-delete"}
              >
                Delete
              </.button>
            </div>
          </div>

          <div
            :if={Table.fixed?(table) and @editing_table_id != table.id}
            id={"table-#{table.id}-pins"}
            class="mt-3 border-t border-line pt-3"
          >
            <p class="mb-1.5 text-xs font-medium text-ink-faint">
              Seated here — and nobody else
            </p>
            <div class="flex flex-wrap items-center gap-1.5">
              <span
                :for={pin <- Map.get(@pins_by_table, table.id, [])}
                id={"pin-#{pin.id}"}
                class="inline-flex items-center gap-1 rounded-chip bg-accent-soft py-0.5 pr-1 pl-2 text-sm text-accent"
              >
                <.icon name="hero-map-pin" class="size-3.5" />
                {SeatingOverview.name(@names, WeddingPlanner.Seating.Pin.side(pin))}
                <button
                  type="button"
                  phx-click="unpin"
                  phx-value-id={pin.id}
                  id={"pin-#{pin.id}-remove"}
                  aria-label={"Unpin #{SeatingOverview.name(@names, WeddingPlanner.Seating.Pin.side(pin))}"}
                  class="inline-flex size-6 items-center justify-center rounded-full transition hover:bg-accent/15"
                >
                  <.icon name="hero-x-mark" class="size-3.5" />
                </button>
              </span>
              <form id={"table-#{table.id}-pin-form"} phx-change="pin" class="inline-block">
                <input type="hidden" name="table_id" value={table.id} />
                <select
                  name="side"
                  id={"table-#{table.id}-pin-select"}
                  aria-label={"Seat at #{table.name}"}
                  class="min-h-9 rounded-chip border border-dashed border-line-strong bg-transparent px-2.5 py-1 text-sm text-ink-soft transition hover:border-accent focus:border-accent focus:ring-2 focus:ring-accent focus:outline-none"
                >
                  <option value="">+ Seat here…</option>
                  {Phoenix.HTML.Form.options_for_select(@side_options, nil)}
                </select>
              </form>
            </div>
          </div>

          <.form
            :if={@editing_table_id == table.id}
            for={@edit_table_form}
            id={"table-#{table.id}-edit-form"}
            phx-submit="update_table"
            class="grid grid-cols-2 gap-2"
          >
            <div class="col-span-2">
              <.input
                field={@edit_table_form[:name]}
                type="text"
                id={"table-#{table.id}-edit-name"}
                aria-label="Table name"
              />
            </div>
            <.input
              field={@edit_table_form[:min_seats]}
              type="number"
              min="1"
              label="Min"
              id={"table-#{table.id}-edit-min"}
            />
            <.input
              field={@edit_table_form[:max_seats]}
              type="number"
              min="1"
              label="Max"
              id={"table-#{table.id}-edit-max"}
            />
            <div :if={!Table.fixed?(table)} class="col-span-2">
              <.input
                field={@edit_table_form[:limit]}
                type="number"
                min="1"
                label="At most (optional)"
                placeholder="no limit"
                id={"table-#{table.id}-edit-limit"}
              />
            </div>
            <div class="col-span-2 flex gap-2">
              <.button variant="primary" id={"table-#{table.id}-edit-save"}>Save</.button>
              <button
                type="button"
                phx-click="cancel_edit_table"
                id={"table-#{table.id}-edit-cancel"}
                class={secondary_button_class()}
              >
                Cancel
              </button>
            </div>
          </.form>

          <div :if={@confirming_table_id == table.id} class="mt-3">
            <.destructive_confirm
              id={"table-#{table.id}-delete-confirm"}
              title={"Delete '#{table.name}'?"}
              affected={Seating.table_deletion_effects(table)}
              confirm="delete_table"
              confirm_value={table.id}
              cancel="cancel_delete_table"
            />
          </div>
        </li>
      </ul>
    </section>
    """
  end

  defp fixed_form?(form), do: to_string(form[:kind].value) == "fixed"

  defp table_line(%Table{kind: :fixed} = table), do: Seating.seat_range(table)

  defp table_line(%Table{limit: nil} = table),
    do: "#{Seating.seat_range(table)} · as many as needed"

  defp table_line(table), do: "#{Seating.seat_range(table)} · at most #{table.limit}"

  # -- circles section -----------------------------------------------------------------

  attr :circles, :list, required: true
  attr :names, :map, required: true
  attr :derived_members, :list, required: true
  attr :circle_form, :any, required: true
  attr :editing_circle_id, :any, required: true
  attr :edit_circle_form, :any, required: true
  attr :confirming_circle_id, :any, required: true
  attr :member_options, :list, required: true

  defp circles_section(assigns) do
    ~H"""
    <section id="circles-section" aria-labelledby="circles-heading">
      <div class="flex items-baseline justify-between gap-4">
        <h2 id="circles-heading" class="text-sm font-semibold tracking-wide text-ink-soft uppercase">
          Circles
        </h2>
        <p class="text-sm text-ink-faint">People who know each other. Someone can be in several.</p>
      </div>

      <.form
        for={@circle_form}
        id="circle-form"
        phx-change="validate_circle"
        phx-submit="create_circle"
        class="mt-4 flex flex-col gap-3 rounded-field border border-dashed border-line-strong p-4 sm:flex-row sm:items-start"
      >
        <div class="flex-1">
          <.input
            field={@circle_form[:name]}
            type="text"
            placeholder="New circle, e.g. Uni friends"
            id="circle-form-name"
            aria-label="Circle name"
          />
        </div>
        <div class="sm:w-48">
          <.input
            field={@circle_form[:cohesion]}
            type="select"
            options={cohesion_options()}
            id="circle-form-cohesion"
            aria-label="Cohesion"
          />
        </div>
        <.button variant="primary" id="circle-form-submit">Add circle</.button>
      </.form>

      <ul id="circles" class="mt-4 space-y-3">
        <li
          :if={@circles == []}
          id="circles-empty"
          class="rounded-field border border-dashed border-line-strong p-6 text-center text-sm text-ink-faint"
        >
          No circles yet. Groups already count as a light “know each other”; circles are for everything else.
        </li>
        <li
          :for={circle <- @circles}
          id={"circle-#{circle.id}"}
          class="rounded-field border border-line bg-surface-raised p-4 transition hover:border-line-strong"
        >
          <.circle_header
            :if={@editing_circle_id != circle.id}
            circle={circle}
            derived={if Circle.wedding_party?(circle), do: length(@derived_members), else: 0}
          />
          <.form
            :if={@editing_circle_id == circle.id}
            for={@edit_circle_form}
            id={"circle-#{circle.id}-edit-form"}
            phx-submit="update_circle"
            class="flex flex-col gap-3 sm:flex-row sm:items-start"
          >
            <div class="flex-1">
              <.input
                field={@edit_circle_form[:name]}
                type="text"
                id={"circle-#{circle.id}-edit-name"}
                aria-label="Circle name"
              />
            </div>
            <div class="sm:w-48">
              <.input
                field={@edit_circle_form[:cohesion]}
                type="select"
                options={cohesion_options()}
                id={"circle-#{circle.id}-edit-cohesion"}
                aria-label="Cohesion"
              />
            </div>
            <.button variant="primary" id={"circle-#{circle.id}-edit-save"}>Save</.button>
            <button
              type="button"
              phx-click="cancel_edit_circle"
              id={"circle-#{circle.id}-edit-cancel"}
              class={secondary_button_class()}
            >
              Cancel
            </button>
          </.form>

          <div id={"circle-#{circle.id}-members"} class="mt-3 flex flex-wrap items-center gap-1.5">
            <span
              :for={{key, name} <- if(Circle.wedding_party?(circle), do: @derived_members, else: [])}
              id={"circle-#{circle.id}-derived-#{key}"}
              title="Always in the wedding party"
              class="inline-flex items-center gap-1 rounded-chip bg-accent-soft py-0.5 pr-2.5 pl-2 text-sm text-accent"
            >
              <.icon name="hero-lock-closed" class="size-3.5" />
              {name}
            </span>
            <span
              :for={member <- sort_members(circle.members, @names)}
              id={"circle-#{circle.id}-member-#{member.id}"}
              class="group inline-flex items-center gap-1 rounded-chip bg-surface py-0.5 pr-1 pl-2.5 text-sm text-ink"
            >
              {SeatingOverview.name(@names, {:person, member.id})}
              <button
                type="button"
                phx-click="remove_member"
                phx-value-circle_id={circle.id}
                phx-value-person_id={member.id}
                id={"circle-#{circle.id}-member-#{member.id}-remove"}
                aria-label={"Remove #{SeatingOverview.name(@names, {:person, member.id})} from #{circle.name}"}
                class="inline-flex size-6 items-center justify-center rounded-full text-ink-faint transition hover:bg-bad-soft hover:text-bad"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </button>
            </span>

            <form
              id={"circle-#{circle.id}-add-member"}
              phx-change="add_member"
              class="inline-block"
            >
              <input type="hidden" name="circle_id" value={circle.id} />
              <select
                name="member"
                id={"circle-#{circle.id}-add-member-select"}
                aria-label={"Add to #{circle.name}"}
                class="min-h-9 rounded-chip border border-dashed border-line-strong bg-transparent px-2.5 py-1 text-sm text-ink-soft transition hover:border-accent focus:border-accent focus:ring-2 focus:ring-accent focus:outline-none"
              >
                <option value="">+ Add…</option>
                {Phoenix.HTML.Form.options_for_select(@member_options, nil)}
              </select>
            </form>
          </div>

          <div :if={@confirming_circle_id == circle.id} class="mt-3">
            <.destructive_confirm
              id={"circle-#{circle.id}-delete-confirm"}
              title={"Delete circle '#{circle.name}'?"}
              body="Its members stay on the guest list."
              affected={Seating.circle_deletion_effects(circle)}
              confirm="delete_circle"
              confirm_value={circle.id}
              cancel="cancel_delete_circle"
            />
          </div>
        </li>
      </ul>
    </section>
    """
  end

  attr :circle, :map, required: true
  attr :derived, :integer, default: 0

  defp circle_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-3">
      <div class="flex min-w-0 items-center gap-2">
        <p id={"circle-#{@circle.id}-name"} class="truncate font-semibold text-ink">{@circle.name}</p>
        <span
          :if={Circle.wedding_party?(@circle)}
          id={"circle-#{@circle.id}-built-in"}
          class="shrink-0 rounded-chip bg-accent-soft px-2 py-0.5 text-xs font-medium text-accent"
        >
          Built-in
        </span>
        <.cohesion_meter id={"circle-#{@circle.id}-cohesion"} cohesion={@circle.cohesion} />
        <span class="text-sm text-ink-faint tabular-nums">
          · {length(@circle.members) + @derived}
        </span>
      </div>
      <div class="flex items-center gap-2">
        <.button phx-click="edit_circle" phx-value-id={@circle.id} id={"circle-#{@circle.id}-edit"}>
          Edit
        </.button>
        <.button
          :if={!Circle.wedding_party?(@circle)}
          variant="destructive"
          phx-click="confirm_delete_circle"
          phx-value-id={@circle.id}
          id={"circle-#{@circle.id}-delete"}
        >
          Delete
        </.button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :cohesion, :atom, required: true

  defp cohesion_meter(assigns) do
    assigns = assign(assigns, :strength, cohesion_strength(assigns.cohesion))

    ~H"""
    <span
      id={@id}
      data-cohesion={@cohesion}
      class="inline-flex items-center gap-1.5 rounded-chip bg-info-soft px-2 py-0.5 text-xs font-medium text-info"
    >
      <span aria-hidden="true" class="inline-flex gap-0.5">
        <span
          :for={i <- 1..3}
          class={["size-1.5 rounded-full", if(i <= @strength, do: "bg-info", else: "bg-info/25")]}
        />
      </span>
      {Circle.cohesion_label(@cohesion)}
    </span>
    """
  end

  defp cohesion_strength(:keep_together), do: 3
  defp cohesion_strength(:like_together), do: 2
  defp cohesion_strength(:know_each_other), do: 1

  defp sort_members(members, names) do
    Enum.sort_by(members, &String.downcase(SeatingOverview.name(names, {:person, &1.id})))
  end

  # -- rules section -------------------------------------------------------------------

  attr :rules, :list, required: true
  attr :names, :map, required: true
  attr :rule_form, :any, required: true
  attr :editing_rule_id, :any, required: true
  attr :confirming_rule_id, :any, required: true
  attr :side_options, :list, required: true
  attr :flagged_rule_ids, :any, required: true

  defp rules_section(assigns) do
    ~H"""
    <section id="rules-section" aria-labelledby="rules-heading">
      <div class="flex items-baseline justify-between gap-4">
        <h2 id="rules-heading" class="text-sm font-semibold tracking-wide text-ink-soft uppercase">
          Rules
        </h2>
        <p class="text-sm text-ink-faint">
          The exceptions. A rule between two people beats their circles.
        </p>
      </div>

      <.form
        for={@rule_form}
        id="rule-form"
        phx-change="validate_rule"
        phx-submit="save_rule"
        class={[
          "mt-4 grid gap-3 rounded-field border p-4 transition sm:grid-cols-[1fr_auto_1fr]",
          if(@editing_rule_id,
            do: "border-accent bg-accent-soft",
            else: "border-dashed border-line-strong"
          )
        ]}
      >
        <.input
          field={@rule_form[:subject]}
          type="select"
          options={@side_options}
          prompt="Who…"
          id="rule-form-subject"
          aria-label="First side"
        />
        <.input
          field={@rule_form[:relation]}
          type="select"
          options={relation_options()}
          prompt="…relation…"
          id="rule-form-relation"
          aria-label="Relation"
        />
        <.input
          field={@rule_form[:object]}
          type="select"
          options={@side_options}
          prompt="…whom"
          id="rule-form-object"
          aria-label="Second side"
        />
        <div class="sm:col-span-3 flex flex-col gap-3 sm:flex-row sm:items-start">
          <div class="flex-1">
            <.input
              field={@rule_form[:reason]}
              type="text"
              placeholder="Why? (optional, but future you will ask)"
              id="rule-form-reason"
              aria-label="Reason"
            />
          </div>
          <.button variant="primary" id="rule-form-submit">
            {if @editing_rule_id, do: "Save rule", else: "Add rule"}
          </.button>
          <button
            :if={@editing_rule_id}
            type="button"
            phx-click="cancel_edit_rule"
            id="rule-form-cancel"
            class={secondary_button_class()}
          >
            Cancel
          </button>
        </div>
      </.form>

      <ul
        id="rules"
        class="mt-4 divide-y divide-line rounded-field border border-line bg-surface-raised"
      >
        <li :if={@rules == []} id="rules-empty" class="p-6 text-center text-sm text-ink-faint">
          No rules yet.
        </li>
        <li
          :for={rule <- @rules}
          id={"rule-#{rule.id}"}
          class={[
            "p-3 transition hover:bg-surface sm:px-4",
            @editing_rule_id == rule.id && "bg-accent-soft"
          ]}
        >
          <.rule_row
            rule={rule}
            names={@names}
            flagged={MapSet.member?(@flagged_rule_ids, rule.id)}
          />
          <div :if={@confirming_rule_id == rule.id} class="mt-3">
            <.destructive_confirm
              id={"rule-#{rule.id}-delete-confirm"}
              title="Delete this rule?"
              confirm="delete_rule"
              confirm_value={rule.id}
              cancel="cancel_delete_rule"
            />
          </div>
        </li>
      </ul>
    </section>
    """
  end

  attr :rule, :map, required: true
  attr :names, :map, required: true
  attr :flagged, :boolean, required: true

  defp rule_row(assigns) do
    {a, relation, b} = SeatingOverview.sentence(assigns.names, assigns.rule)
    assigns = assign(assigns, a: a, relation: relation, b: b)

    ~H"""
    <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
      <div class="min-w-0">
        <p class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm text-ink">
          <span :if={@flagged} id={"rule-#{@rule.id}-flag"} title="See the health panel">
            <.icon name="hero-exclamation-triangle" class="size-4 text-warn" />
          </span>
          <span class="font-medium">{@a}</span>
          <.relation_badge
            id={"rule-#{@rule.id}-relation"}
            relation={@rule.relation}
            label={@relation}
          />
          <span class="font-medium">{@b}</span>
        </p>
        <p :if={@rule.reason} id={"rule-#{@rule.id}-reason"} class="mt-0.5 text-sm text-ink-faint">
          {@rule.reason}
        </p>
      </div>
      <div class="flex shrink-0 items-center gap-2">
        <.button phx-click="edit_rule" phx-value-id={@rule.id} id={"rule-#{@rule.id}-edit"}>
          Edit
        </.button>
        <.button
          variant="destructive"
          phx-click="confirm_delete_rule"
          phx-value-id={@rule.id}
          id={"rule-#{@rule.id}-delete"}
        >
          Delete
        </.button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :relation, :atom, required: true
  attr :label, :string, required: true

  defp relation_badge(assigns) do
    ~H"""
    <span
      id={@id}
      data-relation={@relation}
      class={[
        "inline-flex items-center gap-1 rounded-chip px-2 py-0.5 text-xs font-semibold",
        relation_class(@relation)
      ]}
    >
      <.icon name={relation_icon(@relation)} class="size-3.5" />
      {@label}
    </span>
    """
  end

  defp relation_icon(:always_with), do: "hero-link"
  defp relation_icon(:seat_with), do: "hero-arrows-pointing-in"
  defp relation_icon(:keep_apart), do: "hero-arrows-pointing-out"
  defp relation_icon(:never_with), do: "hero-no-symbol"

  # Hard relations are solid, soft ones a soft tint: the difference must read at a glance.
  defp relation_class(:always_with), do: "bg-good text-white"
  defp relation_class(:seat_with), do: "bg-good-soft text-good"
  defp relation_class(:keep_apart), do: "bg-bad-soft text-bad"
  defp relation_class(:never_with), do: "bg-bad text-white"

  # -- health panel --------------------------------------------------------------------

  attr :events, :list, required: true
  attr :event, :any, required: true
  attr :presets, :list, required: true
  attr :preset, :any, required: true
  attr :health, :any, required: true

  defp health_panel(assigns) do
    ~H"""
    <section
      id="health-panel"
      aria-labelledby="health-heading"
      class="rounded-field border border-line bg-surface-raised p-4 shadow-sm"
    >
      <h2 id="health-heading" class="text-sm font-semibold tracking-wide text-ink-soft uppercase">
        Health
      </h2>

      <p :if={@events == []} id="health-no-events" class="mt-3 text-sm text-ink-soft">
        Add an event first: seating is worked out per event.
        <.link navigate={~p"/events/new"} class="font-medium text-accent hover:underline">Add one.</.link>
      </p>

      <p
        :if={@events != [] and is_nil(@preset)}
        id="health-no-presets"
        class="mt-3 text-sm text-ink-soft"
      >
        No headcount presets are stored, so nobody can be seated yet.
      </p>

      <form
        :if={@events != [] and @preset}
        id="scenario-form"
        phx-change="select_scenario"
        class="mt-3 space-y-2"
      >
        <label for="scenario-event" class="block">
          <span class="mb-1 block text-xs font-medium text-ink-faint">Event</span>
          <select
            name="event_id"
            id="scenario-event"
            class="block min-h-11 w-full rounded-field border border-line-strong bg-surface-raised px-3 py-2 text-sm text-ink focus:border-accent focus:ring-2 focus:ring-accent focus:outline-none"
          >
            {Phoenix.HTML.Form.options_for_select(
              Enum.map(@events, &{&1.name, &1.id}),
              @event && @event.id
            )}
          </select>
        </label>
        <div>
          <span class="mb-1 block text-xs font-medium text-ink-faint">Who is coming</span>
          <.preset_selector id="seating-preset" presets={@presets} selected={@preset.id} />
        </div>
        <p class="text-xs text-ink-faint">Only changes this panel; not saved.</p>
      </form>

      <div :if={@health} id="health-body" class="mt-4 space-y-5">
        <dl id="health-counts" class="grid grid-cols-2 gap-3">
          <div class="rounded-field bg-surface p-3">
            <dt class="text-xs text-ink-faint">Seats needed</dt>
            <dd id="health-seats" class="text-2xl font-semibold text-ink tabular-nums">
              {@health.seats}
            </dd>
          </div>
          <div class="rounded-field bg-surface p-3">
            <dt class="text-xs text-ink-faint">Seats at tables</dt>
            <dd
              id="health-available"
              class={[
                "font-semibold text-ink tabular-nums",
                if(@health.available == :unlimited, do: "pt-1.5 text-base", else: "text-2xl")
              ]}
            >
              {if @health.available == :unlimited, do: "As needed", else: @health.available}
            </dd>
          </div>
        </dl>
        <p class="-mt-3 text-xs text-ink-faint">
          {health_summary(@health, @preset)}
        </p>

        <.health_group
          id="health-blocking"
          title="Blocking"
          tone={:bad}
          icon="hero-x-circle"
          items={@health.blocking}
          empty="Nothing blocks a plan."
        />

        <.health_group
          id="health-warnings"
          title="Warnings"
          tone={:warn}
          icon="hero-exclamation-triangle"
          items={@health.warnings}
          empty="No conflicting rules."
        />

        <div id="health-loose-ends">
          <h3 class="flex items-center gap-1.5 text-sm font-semibold text-ink">
            <.icon name="hero-user-minus" class="size-4 text-warn" /> Loose ends
            <span class="text-ink-faint tabular-nums">{length(@health.loose_ends)}</span>
          </h3>
          <p :if={@health.loose_ends == []} class="mt-1 text-sm text-ink-faint">
            Everyone knows someone.
          </p>
          <p :if={@health.loose_ends != []} class="mt-1 text-xs text-ink-faint">
            Nobody pulls these towards anyone. Add them to a circle, or mark them fine anywhere.
          </p>
          <ul :if={@health.loose_ends != []} class="mt-2 space-y-1.5">
            <li
              :for={unit <- @health.loose_ends}
              id={unit.id}
              class="rounded-field bg-warn-soft/60 px-3 py-2 text-sm"
            >
              <div :for={member <- unit.members} class="flex items-center justify-between gap-2">
                <span class="text-ink">{member.name}</span>
                <button
                  :if={member.person_id}
                  type="button"
                  phx-click="set_fine_anywhere"
                  phx-value-id={member.person_id}
                  phx-value-value="true"
                  id={"fine-anywhere-#{member.person_id}"}
                  class="shrink-0 rounded-chip px-2 py-0.5 text-xs font-medium text-accent transition hover:bg-accent/10"
                >
                  Fine anywhere
                </button>
              </div>
            </li>
          </ul>
        </div>

        <div :if={@health.inactive_pins != []} id="health-inactive-pins">
          <h3 class="flex items-center gap-1.5 text-sm font-semibold text-ink">
            <.icon name="hero-map-pin" class="size-4 text-ink-faint" /> Inactive pins
            <span class="text-ink-faint tabular-nums">{length(@health.inactive_pins)}</span>
          </h3>
          <ul class="mt-2 space-y-1.5">
            <li
              :for={pin <- @health.inactive_pins}
              id={pin.id}
              class="rounded-field bg-surface px-3 py-2"
            >
              <p class="text-sm font-medium text-ink">{pin.title}</p>
              <p class="mt-0.5 text-sm text-ink-soft">{pin.detail}</p>
            </li>
          </ul>
        </div>

        <div :if={@health.fine_anywhere != []} id="health-fine-anywhere">
          <h3 class="text-sm font-semibold text-ink">Fine anywhere</h3>
          <ul class="mt-1.5 flex flex-wrap gap-1.5">
            <li
              :for={person <- @health.fine_anywhere}
              id={"fine-anywhere-person-#{person.id}"}
              class="inline-flex items-center gap-1 rounded-chip bg-good-soft py-0.5 pr-1 pl-2.5 text-sm text-good"
            >
              {person.name}
              <button
                type="button"
                phx-click="set_fine_anywhere"
                phx-value-id={person.id}
                phx-value-value="false"
                id={"fine-anywhere-#{person.id}-undo"}
                aria-label={"#{person.name} is not fine anywhere after all"}
                class="inline-flex size-6 items-center justify-center rounded-full transition hover:bg-good/15"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </button>
            </li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :tone, :atom, required: true
  attr :icon, :string, required: true
  attr :items, :list, required: true
  attr :empty, :string, required: true

  defp health_group(assigns) do
    ~H"""
    <div id={@id}>
      <h3 class="flex items-center gap-1.5 text-sm font-semibold text-ink">
        <.icon name={@icon} class={["size-4", tone_text(@tone)]} /> {@title}
        <span class="text-ink-faint tabular-nums">{length(@items)}</span>
      </h3>
      <p :if={@items == []} class="mt-1 text-sm text-ink-faint">{@empty}</p>
      <ul :if={@items != []} class="mt-2 space-y-1.5">
        <li :for={item <- @items} id={item.id} class={["rounded-field px-3 py-2", tone_bg(@tone)]}>
          <p class="text-sm font-medium text-ink">{item.title}</p>
          <p class="mt-0.5 text-sm text-ink-soft">{item.detail}</p>
        </li>
      </ul>
    </div>
    """
  end

  # A cancel inside a form must not submit it, and `.button/1` takes no `type` — the same
  # plain-button idiom `OfferLive`'s line editor uses.
  defp secondary_button_class do
    "inline-flex min-h-11 items-center justify-center gap-2 rounded-field px-4 text-sm font-semibold " <>
      "cursor-pointer transition-all duration-150 ease-out active:scale-[0.98] " <>
      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-paper " <>
      "bg-transparent text-ink border border-line-strong hover:bg-surface active:bg-line"
  end

  defp health_summary(health, preset) do
    people = "#{health.people} #{plural(health.people, "person", "people")}"
    couple = if health.couple?, do: " + the two of you", else: ""

    "#{people}#{couple} under #{preset.name}, in #{health.units} seating " <>
      "#{plural(health.units, "unit", "units")}."
  end

  defp plural(1, one, _many), do: one
  defp plural(_n, _one, many), do: many

  defp tone_text(:bad), do: "text-bad"
  defp tone_text(:warn), do: "text-warn"

  defp tone_bg(:bad), do: "bg-bad-soft"
  defp tone_bg(:warn), do: "bg-warn-soft/60"
end
