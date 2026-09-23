defmodule WeddingPlannerWeb.Live.InvitationsLive do
  @moduledoc """
  `/invitations` (task 45; `docs/modules/guests-and-events.md` `INVT-01`–`INVT-04`,
  `PER-04`, `PER-13`, `PER-14`; `DR-37`, `DR-38`, `DR-39`) — the persons × events matrix:
  one native `<select>` per cell, +1 rows collapsed behind a chevron, a name/want-tier/
  status-for-event filter combo (the `INVT-04` B-list is "want tier maybe, not invited to
  `<event>`" on this screen), and the group bulk action (`PER-04`). The locked design is
  `.claude/design/ui-decisions.md` §5's "Invitation matrix" (v2/v4).

  ## Data shape: one stream of `WeddingPlanner.Invitations.Matrix` items

  All the actual row/grouping/filter logic lives in the pure
  `WeddingPlanner.Invitations.Matrix` — this module's job is fetching the four
  collections it needs (`WeddingPlanner.Guests.list_persons/1`, already host-unit
  ordered, `DR-34`; `WeddingPlanner.Guests.list_groups/0`; `WeddingPlanner.Events.list_events/0`,
  `EVT-04` order; `WeddingPlanner.Invitations.Effective.index/3` over every invitation/
  opt-out row), handing them to `Matrix.build/6`, and streaming the result into
  `@streams.matrix_items` (`phx-update="stream"`, one `<div>` per item — never a
  `<table>`, since a stream's children must be direct children and a `<thead>` cannot
  live inside it). The column header row is rendered once, outside the stream. Every
  row (header and body) shares the same inline `grid-template-columns` (`grid_style/1`)
  so independent CSS grids stack into visually aligned columns without a wrapping
  `<table>` — this is also why a dynamic column count needs an inline `style`, not a
  Tailwind class: an interpolated class string can't be discovered by Tailwind's static
  scan.

  ## Re-render discipline (stream items only re-render when re-inserted)

  A single cell (`set_status`) or opt-out (`set_opt_out`) change re-inserts **only** the
  affected host unit (`refresh_after_cell_change/2` — host + its own +1s, since a host's
  status change also changes what its +1s derive) — **unless** the status-for-event
  filter is active, in which case the edited unit might have just stopped matching it,
  so the whole stream resets instead. Every other change — filters, the flat/grouped
  toggle, the group bulk action, a +1 expand/collapse toggle, and every live broadcast
  (`:invitation`, `:plus_one_opt_out`, `:person`, `:group`, `:event`) — calls `refresh/1`
  (full `reset: true`); at `NFR-33`'s "≤ ~150 persons" this stays well under a second,
  and it is the only way expand/collapse or a filter change reliably reaches an already-
  rendered stream item's markup (`DR-21`: no diffing, no "changed" indicator either way).

  ## The group bulk action (`PER-04`, `DR-38`, `DR-39`)

  Each group header in the grouped view carries its own `event_id`/`status` form
  (`group-bulk-<group_id>`, absent on the "Ungrouped" section). Submitting it does
  **not** write anything yet — it computes
  `WeddingPlanner.Invitations.bulk_status_preview/3` over exactly the group's
  **currently shown** members (`Matrix.matching_units/3`, so a bulk action respects
  whatever filter narrowed the screen down — the same "bulk acts on what's filtered"
  convention `WeddingPlannerWeb.Live.PeopleLive`'s own group actions already use) and
  opens `group-bulk-confirm-<group_id>` (`WeddingPlannerWeb.CoreComponents.destructive_confirm/1`,
  `XC-40`) naming the count that would actually change and how many accepted/declined
  RSVPs it would overwrite. A single cell set to "Not invited" needs no such
  confirmation (`DR-38`: the native select is itself the deliberate pick, Escape/click-
  away is the free cancel) — only the bulk path ever shows one.
  """
  use WeddingPlannerWeb, :live_view

  alias WeddingPlanner.Events
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Guests.Group
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Invitations.Effective
  alias WeddingPlanner.Invitations.Matrix
  alias WeddingPlanner.Realtime
  alias WeddingPlannerWeb.Format

  @default_filter_params %{"text" => "", "want_tier" => "", "event_id" => "", "status" => ""}

  @cell_status_options [
    {"Not invited", :not_invited},
    {"Planned", :planned},
    {"Invited", :invited},
    {"Accepted", :accepted},
    {"Declined", :declined}
  ]

  @want_tier_options [{"Yes", :yes}, {"Maybe", :maybe}, {"No", :no}, {"Obligated", :obligated}]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Realtime.subscribe(:invitation)
      Realtime.subscribe(:plus_one_opt_out)
      Realtime.subscribe(:person)
      Realtime.subscribe(:group)
      Realtime.subscribe(:event)
    end

    socket =
      socket
      |> stream_configure(:matrix_items, dom_id: &item_dom_id/1)
      |> assign(:page_title, "Invitations")
      |> assign(:grouping, :grouped)
      |> assign(:expanded_ids, MapSet.new())
      |> assign(:filters, parse_filters(@default_filter_params))
      |> assign(:filter_form, to_form(@default_filter_params, as: "filter"))
      |> assign(:want_tier_options, @want_tier_options)
      |> assign(:cell_status_options, @cell_status_options)
      |> assign(:confirming_bulk_group_id, nil)
      |> assign(:bulk_pending, nil)
      |> assign(:bulk_preview, nil)
      |> refresh()

    {:ok, socket}
  end

  # -- filters, grouping, expand/collapse (all `reset: true`, see moduledoc) --------------

  @impl true
  def handle_event("filter", %{"filter" => params}, socket) do
    socket =
      socket
      |> assign(:filters, parse_filters(params))
      |> assign(:filter_form, to_form(params, as: "filter"))
      |> refresh()

    {:noreply, socket}
  end

  def handle_event("toggle_grouping", _params, socket) do
    grouping = if socket.assigns.grouping == :grouped, do: :flat, else: :grouped
    {:noreply, socket |> assign(:grouping, grouping) |> refresh()}
  end

  def handle_event("toggle_plus_ones", %{"host_id" => host_id}, socket) do
    id = String.to_integer(host_id)
    expanded = socket.assigns.expanded_ids

    expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    {:noreply, socket |> assign(:expanded_ids, expanded) |> refresh()}
  end

  # -- single-cell writes (DR-38: no confirmation) -----------------------------------------

  def handle_event(
        "set_status",
        %{"person_id" => person_id, "event_id" => event_id, "status" => status},
        socket
      ) do
    person = Guests.get_person!(String.to_integer(person_id))
    event = Events.get_event!(String.to_integer(event_id))

    case Invitations.set_invitation_status(
           socket.assigns.current_scope,
           person,
           event,
           parse_cell_status(status)
         ) do
      {:ok, _invitation_or_nil} ->
        {:noreply, refresh_after_cell_change(socket, person.id)}

      {:error, :plus_one} ->
        {:noreply,
         put_flash(socket, :error, "A +1's status follows its host — opt it out instead.")}
    end
  end

  def handle_event(
        "set_opt_out",
        %{"person_id" => person_id, "event_id" => event_id, "opt_out" => opt_out},
        socket
      ) do
    person = Guests.get_person!(String.to_integer(person_id))
    event = Events.get_event!(String.to_integer(event_id))

    case Invitations.set_opt_out(
           socket.assigns.current_scope,
           person,
           event,
           opt_out == "opted_out"
         ) do
      {:ok, _opt_out_or_nil} ->
        {:noreply, refresh_after_cell_change(socket, person.host_id)}

      {:error, :not_a_plus_one} ->
        {:noreply,
         put_flash(socket, :error, "Only a +1 can opt out — set the host's status instead.")}
    end
  end

  # -- group bulk action (PER-04, DR-38, DR-39) --------------------------------------------

  def handle_event(
        "bulk_prepare",
        %{"group_id" => group_key, "event_id" => event_id, "status" => status},
        socket
      ) do
    event = Events.get_event!(String.to_integer(event_id))
    status = parse_cell_status(status)
    persons = shown_group_persons(socket, group_key)
    preview = Invitations.bulk_status_preview(persons, event, status)

    pending = %{
      group_key: group_key,
      group_label: group_label_for(group_key),
      persons: persons,
      event: event,
      status: status
    }

    socket =
      socket
      |> assign(:confirming_bulk_group_id, group_key)
      |> assign(:bulk_pending, pending)
      |> assign(:bulk_preview, preview)
      |> refresh()

    {:noreply, socket}
  end

  def handle_event("bulk_confirm", _params, socket) do
    %{persons: persons, event: event, status: status} = socket.assigns.bulk_pending

    {:ok, changed} =
      Invitations.bulk_set_invitation_status(socket.assigns.current_scope, persons, event, status)

    socket =
      socket
      |> assign(:confirming_bulk_group_id, nil)
      |> assign(:bulk_pending, nil)
      |> assign(:bulk_preview, nil)
      |> put_flash(
        :info,
        "Set #{length(changed)} #{pluralize(length(changed), "person", "people")} to " <>
          "#{status_label(status)} for #{event.name}."
      )
      |> refresh()

    {:noreply, socket}
  end

  def handle_event("bulk_cancel", _params, socket) do
    socket =
      socket
      |> assign(:confirming_bulk_group_id, nil)
      |> assign(:bulk_pending, nil)
      |> assign(:bulk_preview, nil)
      |> refresh()

    {:noreply, socket}
  end

  # -- live updates (XC-01, DR-21 — silent, full refresh) ----------------------------------

  @impl true
  def handle_info({Realtime, :invitation, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :plus_one_opt_out, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :person, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :group, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :event, _event}, socket), do: {:noreply, refresh(socket)}

  # -- data ---------------------------------------------------------------------------------

  defp refresh(socket) do
    events = Events.list_events()
    groups = Guests.list_groups()
    persons = Guests.list_persons(%{})
    lookup = current_lookup(persons)

    result =
      Matrix.build(
        persons,
        groups,
        events,
        lookup,
        socket.assigns.filters,
        socket.assigns.grouping
      )

    socket
    |> assign(:events, events)
    |> assign(:groups, groups)
    |> assign(:shown, result.shown)
    |> assign(:total, result.total)
    |> stream(:matrix_items, result.items, reset: true)
  end

  # `filters.event_id`/`filters.status` (the B-list, status-for-event filter) is the one
  # filter category a status/opt-out write can change the outcome of — every other
  # filter (text, want tier) is independent of invitation status, so a plain re-insert of
  # the one affected unit is always safe otherwise (see the moduledoc).
  defp refresh_after_cell_change(socket, host_id) do
    %{event_id: event_id, status: status} = socket.assigns.filters

    if event_id != nil and status != nil do
      refresh(socket)
    else
      host = Guests.get_person!(host_id)
      plus_ones = host.plus_ones |> Enum.sort_by(& &1.id) |> Enum.map(&Map.put(&1, :host, host))
      lookup = unit_lookup(host, plus_ones)
      item = Matrix.item_for_unit(host, plus_ones, socket.assigns.events, lookup)
      stream_insert(socket, :matrix_items, item)
    end
  end

  defp unit_lookup(host, plus_ones) do
    invitations =
      host
      |> Invitations.statuses_for_person()
      |> Enum.map(fn {event_id, status} ->
        %{person_id: host.id, event_id: event_id, status: status}
      end)

    opt_outs =
      Enum.flat_map(plus_ones, fn plus_one ->
        plus_one
        |> Invitations.opted_out_event_ids()
        |> Enum.map(&%{person_id: plus_one.id, event_id: &1})
      end)

    Effective.index([host | plus_ones], invitations, opt_outs)
  end

  defp current_lookup(persons) do
    Effective.index(persons, Invitations.list_invitations(), Invitations.list_opt_outs())
  end

  defp shown_group_persons(socket, group_key) do
    persons = Guests.list_persons(%{})
    lookup = current_lookup(persons)

    persons
    |> Matrix.matching_units(lookup, socket.assigns.filters)
    |> Enum.filter(fn {host, _plus_ones} -> in_group?(host, group_key) end)
    |> Enum.map(fn {host, _plus_ones} -> host end)
  end

  defp in_group?(%Person{group_id: nil}, "ungrouped"), do: true
  defp in_group?(%Person{group_id: nil}, _group_key), do: false
  defp in_group?(%Person{group_id: group_id}, group_key), do: to_string(group_id) == group_key

  defp group_label_for("ungrouped"), do: "Ungrouped"
  defp group_label_for(group_key), do: Guests.get_group!(String.to_integer(group_key)).name

  defp item_dom_id({:group_header, :ungrouped, _count}), do: "group-ungrouped"
  defp item_dom_id({:group_header, %Group{id: id}, _count}), do: "group-#{id}"
  defp item_dom_id({:unit, host, _plus_ones, _cells}), do: "unit-#{host.id}"

  # -- parsing (never String.to_atom/1 on user input) --------------------------------------

  defp parse_filters(params) do
    %{
      text: blank_to_nil(params["text"]),
      want_tier: parse_want_tier(params["want_tier"]),
      event_id: parse_id(params["event_id"]),
      status: parse_filter_status(params["status"])
    }
  end

  defp parse_want_tier("yes"), do: :yes
  defp parse_want_tier("maybe"), do: :maybe
  defp parse_want_tier("no"), do: :no
  defp parse_want_tier("obligated"), do: :obligated
  defp parse_want_tier(_other), do: nil

  defp parse_filter_status("not_invited"), do: :not_invited
  defp parse_filter_status("planned"), do: :planned
  defp parse_filter_status("invited"), do: :invited
  defp parse_filter_status("accepted"), do: :accepted
  defp parse_filter_status("declined"), do: :declined
  defp parse_filter_status(_other), do: nil

  defp parse_cell_status("not_invited"), do: :not_invited
  defp parse_cell_status("planned"), do: :planned
  defp parse_cell_status("invited"), do: :invited
  defp parse_cell_status("accepted"), do: :accepted
  defp parse_cell_status("declined"), do: :declined

  defp parse_id(nil), do: nil
  defp parse_id(""), do: nil

  defp parse_id(str) do
    case Integer.parse(str) do
      {id, ""} -> id
      _other -> nil
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(str), do: str

  # -- render -------------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width="wide">
      <.header>
        Invitations
        <:actions>
          <button
            type="button"
            id="invitations-grouping-toggle"
            phx-click="toggle_grouping"
            class="rounded-field border border-line-strong bg-surface-raised px-3 py-1.5 text-sm font-medium text-ink hover:bg-surface"
          >
            {if @grouping == :grouped, do: "Show flat", else: "Show grouped"}
          </button>
        </:actions>
      </.header>

      <.form
        for={@filter_form}
        id="invitations-filter"
        phx-change="filter"
        class="flex flex-wrap items-end gap-3"
      >
        <div class="min-w-48 flex-1">
          <.input field={@filter_form[:text]} type="text" label="Name" placeholder="Filter by name" />
        </div>
        <div class="w-40">
          <.input
            field={@filter_form[:want_tier]}
            type="select"
            label="Want tier"
            prompt="Any want tier"
            options={@want_tier_options}
          />
        </div>
        <div class="w-44">
          <.input
            field={@filter_form[:event_id]}
            type="select"
            label="Status for event"
            prompt="Any event"
            options={Enum.map(@events, &{&1.name, &1.id})}
          />
        </div>
        <div class="w-36">
          <.input
            field={@filter_form[:status]}
            type="select"
            label="Status"
            prompt="Any status"
            options={@cell_status_options}
          />
        </div>
      </.form>

      <p id="invitations-shown-count" class="text-sm text-ink-soft">{@shown} of {@total} shown</p>

      <div class="overflow-x-auto rounded-field border border-line bg-surface-raised">
        <div>
          <div class="grid border-b border-line bg-surface" style={grid_style(@events)}>
            <div class="sticky left-0 z-10 bg-surface px-3 py-2 text-xs font-semibold tracking-wide text-ink-soft uppercase">
              Name
            </div>
            <div :for={event <- @events} class="px-3 py-2 text-xs font-semibold text-ink-soft">
              <div class="truncate">{event.name}</div>
              <div class="font-normal text-ink-faint">{Format.date(event.date)}</div>
            </div>
          </div>

          <div id="invitations-matrix" phx-update="stream">
            <p
              id="invitations-empty"
              class="hidden px-3 py-8 text-center text-sm text-ink-faint only:block"
            >
              No people yet — add some on the People screen first.
            </p>
            <div :for={{dom_id, item} <- @streams.matrix_items} id={dom_id}>
              <%= case item do %>
                <% {:group_header, group, count} -> %>
                  <.group_header_row
                    group={group}
                    count={count}
                    events={@events}
                    cell_status_options={@cell_status_options}
                    confirming_bulk_group_id={@confirming_bulk_group_id}
                    bulk_pending={@bulk_pending}
                    bulk_preview={@bulk_preview}
                  />
                <% {:unit, host, plus_ones, cells} -> %>
                  <.unit_row
                    host={host}
                    plus_ones={plus_ones}
                    cells={cells}
                    events={@events}
                    cell_status_options={@cell_status_options}
                    expanded={MapSet.member?(@expanded_ids, host.id)}
                  />
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :group, :any, required: true
  attr :count, :integer, required: true
  attr :events, :list, required: true
  attr :cell_status_options, :list, required: true
  attr :confirming_bulk_group_id, :any, required: true
  attr :bulk_pending, :any, required: true
  attr :bulk_preview, :any, required: true

  defp group_header_row(assigns) do
    ~H"""
    <div class="mt-4 rounded-field border border-line bg-surface px-3 py-2.5 first:mt-0">
      <div class="flex flex-wrap items-center gap-3">
        <span class="text-sm font-semibold text-ink">{group_display_name(@group)}</span>
        <span class="text-xs text-ink-faint">{@count} shown</span>

        <form
          :if={@group != :ungrouped}
          id={"group-bulk-#{group_dom_key(@group)}"}
          phx-submit="bulk_prepare"
          class="ml-auto flex flex-wrap items-center gap-2"
        >
          <input type="hidden" name="group_id" value={group_dom_key(@group)} />
          <select
            name="event_id"
            required
            class="rounded-field border border-line-strong bg-surface-raised px-2 py-1 text-xs text-ink focus:border-accent focus:ring-2 focus:outline-none"
          >
            <option value="">Event…</option>
            <option :for={event <- @events} value={event.id}>{event.name}</option>
          </select>
          <select
            name="status"
            required
            class="rounded-field border border-line-strong bg-surface-raised px-2 py-1 text-xs text-ink focus:border-accent focus:ring-2 focus:outline-none"
          >
            <option value="">Status…</option>
            <option :for={{label, value} <- @cell_status_options} value={value}>{label}</option>
          </select>
          <.button variant="primary" id={"group-bulk-#{group_dom_key(@group)}-apply"}>Apply</.button>
        </form>
      </div>

      <.destructive_confirm
        :if={@confirming_bulk_group_id == group_dom_key(@group)}
        id={"group-bulk-confirm-#{group_dom_key(@group)}"}
        title={bulk_confirm_title(@bulk_pending, @bulk_preview)}
        body={bulk_confirm_body(@bulk_preview)}
        confirm="bulk_confirm"
        cancel="bulk_cancel"
        confirm_label="Apply"
      />
    </div>
    """
  end

  attr :host, :any, required: true
  attr :plus_ones, :list, required: true
  attr :cells, :map, required: true
  attr :events, :list, required: true
  attr :cell_status_options, :list, required: true
  attr :expanded, :boolean, required: true

  defp unit_row(assigns) do
    ~H"""
    <div class="grid border-b border-line" style={grid_style(@events)}>
      <div class="sticky left-0 z-10 flex items-center gap-1.5 bg-surface-raised px-3 py-2 text-sm text-ink">
        <button
          :if={@plus_ones != []}
          type="button"
          id={"plus-one-toggle-#{@host.id}"}
          phx-click="toggle_plus_ones"
          phx-value-host_id={@host.id}
          aria-expanded={@expanded}
          class="flex size-5 shrink-0 items-center justify-center rounded-chip text-ink-faint hover:bg-surface hover:text-ink"
        >
          <.icon
            name={if @expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
            class="size-4"
          />
        </button>
        <span :if={@plus_ones == []} class="size-5 shrink-0" aria-hidden="true"></span>
        <span class="truncate">{Person.display_name(@host)}</span>
      </div>

      <form
        :for={event <- @events}
        id={"cell-#{@host.id}-#{event.id}-form"}
        class="contents"
        phx-change="set_status"
      >
        <input type="hidden" name="person_id" value={@host.id} />
        <input type="hidden" name="event_id" value={event.id} />
        <select
          id={"cell-#{@host.id}-#{event.id}"}
          name="status"
          class={[
            "m-1 rounded-field border px-1.5 py-1 text-xs font-medium focus:border-accent focus:ring-2 focus:ring-accent focus:outline-none",
            cell_class(host_cell(@cells, @host.id, event.id))
          ]}
        >
          <option
            :for={{label, value} <- @cell_status_options}
            value={value}
            selected={host_cell(@cells, @host.id, event.id).status == value}
          >
            {label}
          </option>
        </select>
      </form>
    </div>

    <div
      :for={plus_one <- @plus_ones}
      :if={@expanded}
      class="grid border-b border-line bg-surface"
      style={grid_style(@events)}
    >
      <div class="sticky left-0 z-10 bg-surface px-3 py-2 pl-9 text-sm text-ink-soft italic">
        {Person.display_name(plus_one)}
      </div>

      <form
        :for={event <- @events}
        id={"cell-#{plus_one.id}-#{event.id}-form"}
        class="contents"
        phx-change="set_opt_out"
      >
        <input type="hidden" name="person_id" value={plus_one.id} />
        <input type="hidden" name="event_id" value={event.id} />
        <select
          id={"cell-#{plus_one.id}-#{event.id}"}
          name="opt_out"
          class={[
            "m-1 rounded-field border px-1.5 py-1 text-xs font-medium focus:border-accent focus:ring-2 focus:ring-accent focus:outline-none",
            plus_one_cell_class(host_cell(@cells, plus_one.id, event.id))
          ]}
        >
          <option value="following" selected={not host_cell(@cells, plus_one.id, event.id).opted_out}>
            Following host ({status_label(host_cell(@cells, @host.id, event.id).status)})
          </option>
          <option value="opted_out" selected={host_cell(@cells, plus_one.id, event.id).opted_out}>
            Opted out
          </option>
        </select>
      </form>
    </div>
    """
  end

  defp host_cell(cells, person_id, event_id),
    do: cells |> Map.fetch!(person_id) |> Map.fetch!(event_id)

  defp grid_style(events) do
    columns = length(events)
    min_width = 220 + columns * 150

    "display: grid; grid-template-columns: 220px repeat(#{columns}, minmax(150px, 1fr)); min-width: #{min_width}px;"
  end

  defp group_display_name(:ungrouped), do: "Ungrouped"
  defp group_display_name(%Group{name: name}), do: name

  defp group_dom_key(:ungrouped), do: "ungrouped"
  defp group_dom_key(%Group{id: id}), do: to_string(id)

  defp status_label(:not_invited), do: "Not invited"
  defp status_label(:planned), do: "Planned"
  defp status_label(:invited), do: "Invited"
  defp status_label(:accepted), do: "Accepted"
  defp status_label(:declined), do: "Declined"

  # DR-39 semantic assignment (`.claude/design/ui-decisions.md` §2): planned/declined ->
  # neutral, invited -> info, accepted -> good, not invited -> no fill/faint text.
  defp cell_class(%{status: :not_invited}), do: "border-line-strong bg-transparent text-ink-faint"
  defp cell_class(%{status: :planned}), do: "border-line-strong bg-surface text-ink-soft"
  defp cell_class(%{status: :declined}), do: "border-line-strong bg-surface text-ink-soft"
  defp cell_class(%{status: :invited}), do: "border-info/30 bg-info-soft text-info"
  defp cell_class(%{status: :accepted}), do: "border-good/30 bg-good-soft text-good"

  # +1 opted out -> neutral with a dashed border (DR-39: absence, not a status); otherwise
  # the same tone as whatever status it is currently following.
  defp plus_one_cell_class(%{opted_out: true}),
    do: "border-dashed border-line-strong bg-surface text-ink-soft"

  defp plus_one_cell_class(%{status: status}), do: cell_class(%{status: status})

  defp bulk_confirm_title(%{group_label: label, event: event, status: status}, %{
         changing: changing
       }) do
    "Set #{changing} #{pluralize(changing, "person", "people")} in #{label} to " <>
      "#{status_label(status)} for #{event.name}?"
  end

  defp bulk_confirm_body(%{overwriting_rsvps: 0}), do: "+1s follow their host."

  defp bulk_confirm_body(%{overwriting_rsvps: n}) do
    "#{n} #{pluralize(n, "RSVP", "RSVPs")} will be overwritten. +1s follow their host."
  end

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_n, _singular, plural), do: plural
end
