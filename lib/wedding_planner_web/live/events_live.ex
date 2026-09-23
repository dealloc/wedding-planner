defmodule WeddingPlannerWeb.Live.EventsLive do
  @moduledoc """
  Events CRUD (task 22; `docs/modules/guests-and-events.md` EVT-01 through EVT-05) — the
  **exemplar** vertical slice every later domain module's LiveView copies.

  One LiveView, three routes sharing it via `@live_action`:

    * `/events` (`:index`) — the list, always in manual sort order (EVT-04, never by
      date), with move up/down, edit and delete.
    * `/events/new` (`:new`) — the create form.
    * `/events/:id/edit` (`:edit`) — the edit form, plus this event's own activity
      history (`WeddingPlannerWeb.ActivityComponents.entity_history/1`).

  ## Streams

  The index list is unbounded in principle, so it is held in the `:events` stream
  (`AGENTS.md`). Each streamed row is a plain map `%{id:, event:, first?:, last?:}`
  (not the bare `Event.t()`) — `first?`/`last?` are what disables the boundary move
  button, and computing them requires knowing the row's position in the whole list, so
  they are attached once in `assign_index/1` rather than recomputed per row from
  nothing. Any local mutation (create/update/delete/move) or a matching live broadcast
  refetches `WeddingPlanner.Events.list_events/0` and re-streams with `reset: true` —
  the dataset is small (`NFR-33`: "≤ ~10 events") so this stays cheap, and it is the
  only way to keep `first?`/`last?` correct after a reorder without hand-rolling
  position bookkeeping.

  ## Delete confirmation (`XC-40`)

  `@confirming_delete_id` holds the id of the event currently asking "are you sure?",
  or `nil`. `WeddingPlannerWeb.CoreComponents.destructive_confirm/1` only exists in the
  DOM for the one row being confirmed (`:if={@confirming == true}` on the call site) —
  see that component's moduledoc for the full contract.

  ## Live updates (`XC-01`, `XC-02`)

  `mount/3` subscribes to the `:event` collection topic. Per `DR-21`/`XC-02`, a live
  update is silent — the list simply reflects the new data, no highlight, badge or
  animation marks a row as changed. `:edit` additionally subscribes to
  `:activity_entry` and follows the exact host pattern documented in
  `WeddingPlannerWeb.ActivityComponents.entity_history/1`'s moduledoc, so this event's
  own history updates live too.
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.ActivityComponents, only: [entity_history: 1]

  alias WeddingPlanner.Events
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.Realtime
  alias WeddingPlannerWeb.Format

  on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

  @resource :event

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Realtime.subscribe(@resource)

    {:ok, assign(socket, :confirming_delete_id, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case socket.assigns.live_action do
        :index -> assign_index(socket)
        :new -> assign_form(socket, %Event{})
        :edit -> assign_edit(socket, params["id"])
      end

    {:noreply, socket}
  end

  defp assign_index(socket) do
    socket
    |> assign(:page_title, "Events")
    |> assign(:confirming_delete_id, nil)
    |> stream(:events, decorate_rows(Events.list_events()), reset: true)
  end

  defp assign_form(socket, %Event{} = event) do
    socket
    |> assign(:page_title, if(event.id, do: "Edit event", else: "New event"))
    |> assign(:event, event)
    |> assign(:form, to_form(Events.change_event(event)))
  end

  defp assign_edit(socket, id) do
    event = Events.get_event!(id)
    if connected?(socket), do: Realtime.subscribe(:activity_entry)

    socket
    |> assign_form(event)
    |> assign(:activity_entries, Query.for_entity(:event, event.id))
  end

  defp stream_insert_row(socket, nil), do: socket

  defp stream_insert_row(socket, id) do
    case Enum.find(decorate_rows(Events.list_events()), &(&1.id == id)) do
      nil -> socket
      row -> stream_insert(socket, :events, row)
    end
  end

  defp decorate_rows(events) do
    last_index = length(events) - 1

    events
    |> Enum.with_index()
    |> Enum.map(fn {event, idx} ->
      %{id: event.id, event: event, first?: idx == 0, last?: idx == last_index}
    end)
  end

  @impl true
  def handle_event("validate", %{"event" => params}, socket) do
    form =
      socket.assigns.event
      |> Events.change_event(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"event" => params}, socket) do
    save_event(socket, socket.assigns.live_action, params)
  end

  def handle_event("move_up", %{"id" => id}, socket), do: move(socket, id, :up)
  def handle_event("move_down", %{"id" => id}, socket), do: move(socket, id, :down)

  # AGENTS.md: "when updating an assign that should change content inside any streamed
  # item, re-stream the item along with the updated assign" — @confirming_delete_id is
  # a plain assign, but it changes what the *streamed* row for that id renders (whether
  # its delete confirmation is shown), so the affected row(s) must be explicitly
  # re-inserted for the change to reach the client.
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    id = String.to_integer(id)

    socket =
      socket
      |> assign(:confirming_delete_id, id)
      |> stream_insert_row(id)

    {:noreply, socket}
  end

  def handle_event("cancel_delete", _params, socket) do
    previous_id = socket.assigns.confirming_delete_id

    socket =
      socket
      |> assign(:confirming_delete_id, nil)
      |> stream_insert_row(previous_id)

    {:noreply, socket}
  end

  def handle_event("delete_confirmed", %{"id" => id}, socket) do
    event = Events.get_event!(id)
    {:ok, _} = Events.delete_event(socket.assigns.current_scope, event)

    {:noreply,
     socket
     |> assign(:confirming_delete_id, nil)
     |> stream(:events, decorate_rows(Events.list_events()), reset: true)}
  end

  defp save_event(socket, :new, params) do
    case Events.create_event(socket.assigns.current_scope, params) do
      {:ok, _event} ->
        {:noreply,
         socket
         |> put_flash(:info, "Event created.")
         |> push_navigate(to: ~p"/events")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save_event(socket, :edit, params) do
    case Events.update_event(socket.assigns.current_scope, socket.assigns.event, params) do
      {:ok, _event} ->
        {:noreply,
         socket
         |> put_flash(:info, "Event updated.")
         |> push_navigate(to: ~p"/events")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp move(socket, id, direction) do
    event = Events.get_event!(id)
    :ok = Events.move_event(socket.assigns.current_scope, event, direction)

    {:noreply, stream(socket, :events, decorate_rows(Events.list_events()), reset: true)}
  end

  @impl true
  def handle_info({Realtime, @resource, _event}, %{assigns: %{live_action: :index}} = socket) do
    {:noreply, stream(socket, :events, decorate_rows(Events.list_events()), reset: true)}
  end

  def handle_info({Realtime, @resource, _event}, socket), do: {:noreply, socket}

  def handle_info({Realtime, :activity_entry, {:created, entry}}, socket) do
    %{event: event} = socket.assigns

    if entry.entity_type == "event" and entry.entity_id == event.id do
      entry = Query.preload_user(entry)
      {:noreply, update(socket, :activity_entries, &[entry | &1])}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Events
        <:actions>
          <.button variant="primary" navigate={~p"/events/new"} id="new-event">
            Add event
          </.button>
        </:actions>
      </.header>

      <ul id="events" phx-update="stream" class="space-y-3">
        <li
          id="events-empty"
          class="hidden rounded-field border border-dashed border-line-strong p-6 text-center text-sm text-ink-faint only:block"
        >
          No events yet.
          <.link navigate={~p"/events/new"} class="font-medium text-accent hover:underline">
            Add the first one.
          </.link>
        </li>
        <li
          :for={{dom_id, row} <- @streams.events}
          id={dom_id}
          class="rounded-field border border-line bg-surface-raised p-4"
        >
          <.event_row row={row} confirming={@confirming_delete_id == row.event.id} />
        </li>
      </ul>
    </Layouts.app>
    """
  end

  def render(%{live_action: action} = assigns) when action in [:new, :edit] do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {if @live_action == :new, do: "New event", else: "Edit event"}
        <:actions>
          <.button navigate={~p"/events"} id="back-to-events">Back to events</.button>
        </:actions>
      </.header>

      <.form for={@form} id="event-form" phx-change="validate" phx-submit="save" class="space-y-4">
        <.input field={@form[:name]} type="text" label="Name" id="event-form-name" />
        <.input field={@form[:date]} type="date" label="Date (optional)" id="event-form-date" />
        <.input
          field={@form[:location]}
          type="text"
          label="Location (optional)"
          id="event-form-location"
        />
        <.input
          field={@form[:notes]}
          type="textarea"
          label="Notes (optional)"
          id="event-form-notes"
        />

        <.button variant="primary" id="event-form-submit">Save event</.button>
      </.form>

      <div :if={@live_action == :edit} class="mt-8">
        <.header>History</.header>
        <.entity_history
          id="event-history"
          entity={{:event, @event.id}}
          entries={@activity_entries}
          time_zone={@time_zone}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :row, :map, required: true
  attr :confirming, :boolean, required: true

  defp event_row(assigns) do
    ~H"""
    <div>
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div class="min-w-0">
          <p id={"event-#{@row.event.id}-name"} class="font-semibold text-ink">
            {@row.event.name}
          </p>
          <p class="text-sm text-ink-soft">
            <span
              id={"event-#{@row.event.id}-date"}
              class={[@row.event.date && "tabular-nums"]}
            >
              {Format.date(@row.event.date)}
            </span>
            <span :if={@row.event.location}>
              <span aria-hidden="true">&middot;</span> {@row.event.location}
            </span>
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <button
            type="button"
            id={"event-#{@row.event.id}-move-up"}
            phx-click="move_up"
            phx-value-id={@row.event.id}
            disabled={@row.first?}
            aria-label={"Move #{@row.event.name} up"}
            class="inline-flex min-h-11 min-w-11 items-center justify-center rounded-field border border-line-strong text-ink-soft transition hover:bg-surface disabled:cursor-not-allowed disabled:opacity-40"
          >
            <.icon name="hero-chevron-up" />
          </button>
          <button
            type="button"
            id={"event-#{@row.event.id}-move-down"}
            phx-click="move_down"
            phx-value-id={@row.event.id}
            disabled={@row.last?}
            aria-label={"Move #{@row.event.name} down"}
            class="inline-flex min-h-11 min-w-11 items-center justify-center rounded-field border border-line-strong text-ink-soft transition hover:bg-surface disabled:cursor-not-allowed disabled:opacity-40"
          >
            <.icon name="hero-chevron-down" />
          </button>
          <.button navigate={~p"/events/#{@row.event.id}/edit"} id={"event-#{@row.event.id}-edit"}>
            Edit
          </.button>
          <.button
            variant="destructive"
            phx-click="confirm_delete"
            phx-value-id={@row.event.id}
            id={"event-#{@row.event.id}-delete"}
          >
            Delete
          </.button>
        </div>
      </div>

      <.destructive_confirm
        :if={@confirming}
        id={"event-#{@row.event.id}-delete-confirm"}
        title={"Delete '#{@row.event.name}'?"}
        body="This cannot be undone."
        affected={Events.affected_references(@row.event)}
        confirm="delete_confirmed"
        confirm_value={@row.event.id}
        cancel="cancel_delete"
      />
    </div>
    """
  end
end
