defmodule WeddingPlannerWeb.Live.ActivityLogLive do
  @moduledoc """
  The global activity log (task 20; `docs/04-cross-cutting.md` `XC-11`, `XC-12`, `XC-01`,
  `XC-13`): every logged entry, newest first, filterable by user, entity type and date
  range, with bulk-action children collapsed under their summary and expandable, and new
  entries appearing live without a refresh.

  ## Streams (`AGENTS.md`)

  The log grows without bound, so top-level entries (`WeddingPlanner.Log.Query.list/1` —
  standalone entries and bulk summaries, never a summary's own children) are held in the
  `:log_entries` stream, newest first. A filter change refetches and re-streams with
  `reset: true` rather than filtering client-side (streams are not enumerable).

  Expand/collapse state (`@expanded`, a `MapSet` of summary ids) and a summary's loaded
  children (`@children`, `%{summary_id => [Entry.t()]}`) live in ordinary assigns, not the
  stream — but changing them changes what a *streamed* summary row renders, so every
  toggle re-inserts that one row (`stream_insert/3`, no `at:`, updates the existing item
  in place) per `AGENTS.md`'s "re-stream the items along with the updated assign" rule.
  `@children_counts` (`%{summary_id => non_neg_integer()}`) is what lets a collapsed
  summary's toggle button say how many entries it hides without fetching them first.

  ## Live updates (`XC-01`)

  Subscribes to the `:activity_entry` collection topic. A newly broadcast top-level entry
  (`entry.parent_id == nil` — a standalone entry or a summary) is inserted at the top only
  if it matches the *currently active* filters (`WeddingPlanner.Log.Query.matches_filters?/2`
  — the same predicate `list/1`'s query applies); otherwise it is silently dropped, exactly
  as if it had never been fetched. A newly broadcast **child** is only interesting if its
  summary is currently a row on this page (tracked via `@children_counts`); if so, the
  count goes up, the child is appended to `@children` when that summary is expanded, and
  the summary row is re-streamed so its toggle label and (if expanded) its children list
  reflect the new count/child immediately.

  Per `DR-21`/`XC-02`, arrival is silent — no highlight, badge or animation marks a row as
  new.
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.ActivityComponents, only: [activity_entry: 1]

  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.Realtime

  on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

  @resource :activity_entry

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Realtime.subscribe(@resource)

    socket =
      socket
      |> assign(:page_title, "Activity")
      |> assign(:users, Query.list_users())
      |> assign(:entity_types, Query.list_entity_types())
      |> assign(:children, %{})
      |> assign(:children_counts, %{})
      |> assign(:expanded, MapSet.new())

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = parse_filters(params, socket.assigns.time_zone)
    entries = Query.list(filters)
    summary_ids = for e <- entries, is_nil(e.entity_type), do: e.id

    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:filter_form, to_form(raw_filter_params(params), as: :filter))
      |> assign(:children, %{})
      |> assign(:children_counts, Query.children_counts(summary_ids))
      |> assign(:expanded, MapSet.new())
      |> stream(:log_entries, entries, reset: true)

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", %{"filter" => raw_params}, socket) do
    {:noreply, push_patch(socket, to: ~p"/activity?#{compact(raw_params)}")}
  end

  @impl true
  def handle_event("toggle_children", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    %{expanded: expanded, children: children} = socket.assigns

    {expanded, children} =
      if MapSet.member?(expanded, id) do
        {MapSet.delete(expanded, id), Map.delete(children, id)}
      else
        {MapSet.put(expanded, id), Map.put(children, id, Query.children(id))}
      end

    socket =
      socket
      |> assign(:expanded, expanded)
      |> assign(:children, children)
      |> stream_insert(:log_entries, Query.get!(id))

    {:noreply, socket}
  end

  @impl true
  def handle_info({Realtime, @resource, {:created, entry}}, socket) do
    if is_nil(entry.parent_id) do
      {:noreply, handle_new_top_level(entry, socket)}
    else
      {:noreply, handle_new_child(entry, socket)}
    end
  end

  defp handle_new_top_level(entry, socket) do
    if Query.matches_filters?(entry, socket.assigns.filters) do
      entry = Query.preload_user(entry)

      socket = stream_insert(socket, :log_entries, entry, at: 0)

      if is_nil(entry.entity_type) do
        assign(socket, :children_counts, Map.put(socket.assigns.children_counts, entry.id, 0))
      else
        socket
      end
    else
      socket
    end
  end

  # A child is only interesting to this view if its summary is currently one of the
  # streamed rows (tracked via @children_counts, populated for every summary this view
  # has ever shown since the last reset). A child whose summary was filtered out, or
  # belongs to a page loaded before the current filters, is silently ignored.
  defp handle_new_child(entry, socket) do
    summary_id = entry.parent_id

    if Map.has_key?(socket.assigns.children_counts, summary_id) do
      counts = Map.update(socket.assigns.children_counts, summary_id, 1, &(&1 + 1))

      children =
        if MapSet.member?(socket.assigns.expanded, summary_id) do
          Map.update(socket.assigns.children, summary_id, [entry], &(&1 ++ [entry]))
        else
          socket.assigns.children
        end

      socket
      |> assign(:children_counts, counts)
      |> assign(:children, children)
      |> stream_insert(:log_entries, Query.get!(summary_id))
    else
      socket
    end
  end

  defp parse_filters(params, time_zone) do
    %{}
    |> maybe_put(:user_id, parse_int(params["user_id"]))
    |> maybe_put(:entity_type, presence(params["entity_type"]))
    |> put_range(params["from"], params["to"], time_zone)
  end

  defp raw_filter_params(params) do
    Map.take(params, ["user_id", "entity_type", "from", "to"])
  end

  defp compact(params) do
    params
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp put_range(filters, from_str, to_str, time_zone) do
    filters
    |> maybe_put(:from, day_start(presence(from_str), time_zone))
    |> maybe_put(:to, day_end(presence(to_str), time_zone))
  end

  defp day_start(nil, _time_zone), do: nil

  defp day_start(date_str, time_zone) do
    with {:ok, date} <- Date.from_iso8601(date_str) do
      local_datetime_to_utc(date, ~T[00:00:00], time_zone)
    else
      _ -> nil
    end
  end

  defp day_end(nil, _time_zone), do: nil

  defp day_end(date_str, time_zone) do
    with {:ok, date} <- Date.from_iso8601(date_str) do
      local_datetime_to_utc(date, ~T[23:59:59], time_zone)
    else
      _ -> nil
    end
  end

  # Converts a local wall-clock moment in `time_zone` to UTC. DST ambiguity/gaps pick the
  # first resolvable option rather than erroring — a filter boundary a few minutes off
  # around a DST transition twice a year is an acceptable tradeoff for keeping this
  # total (never raises, never rejects a filter).
  defp local_datetime_to_utc(date, time, time_zone) do
    case DateTime.new(date, time, time_zone) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:ambiguous, dt, _} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:gap, dt, _} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:error, _} -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <WeddingPlannerWeb.Live.TimeZoneHook.probe id="activity-time-zone-probe" />

      <.header>Activity log</.header>

      <.form
        for={@filter_form}
        id="activity-filters"
        phx-change="filter"
        class="grid gap-3 sm:grid-cols-4"
      >
        <.input
          field={@filter_form[:user_id]}
          type="select"
          label="User"
          prompt="All users"
          options={Enum.map(@users, &{&1.display_name, &1.id})}
        />
        <.input
          field={@filter_form[:entity_type]}
          type="select"
          label="Entity type"
          prompt="All types"
          options={Enum.map(@entity_types, &{Phoenix.Naming.humanize(&1), &1})}
        />
        <.input field={@filter_form[:from]} type="date" label="From" />
        <.input field={@filter_form[:to]} type="date" label="To" />
      </.form>

      <div id="activity-log" phx-update="stream" class="divide-y divide-line">
        <p id="activity-log-empty" class="hidden py-6 text-sm text-ink-faint only:block">
          No activity matches these filters.
        </p>
        <div :for={{dom_id, entry} <- @streams.log_entries} id={dom_id} class="py-3">
          <.summary_or_entry
            entry={entry}
            time_zone={@time_zone}
            expanded={MapSet.member?(@expanded, entry.id)}
            child_count={Map.get(@children_counts, entry.id, 0)}
            children={Map.get(@children, entry.id, [])}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :entry, :any, required: true
  attr :time_zone, :string, default: nil
  attr :expanded, :boolean, required: true
  attr :child_count, :integer, required: true
  attr :children, :list, required: true

  defp summary_or_entry(assigns) do
    ~H"""
    <div>
      <.activity_entry id={"activity-entry-#{@entry.id}"} entry={@entry} time_zone={@time_zone} />

      <div :if={is_nil(@entry.entity_type)} class="mt-1.5">
        <button
          type="button"
          phx-click="toggle_children"
          phx-value-id={@entry.id}
          id={"activity-toggle-#{@entry.id}"}
          class="text-xs font-medium text-ink-soft underline decoration-dotted underline-offset-2 transition hover:text-ink"
        >
          {toggle_label(@expanded, @child_count)}
        </button>

        <div
          :if={@expanded}
          id={"activity-children-#{@entry.id}"}
          class="mt-2 space-y-2 border-l-2 border-line pl-3"
        >
          <p :if={@children == []} class="text-xs text-ink-faint">No entries recorded yet.</p>
          <.activity_entry
            :for={child <- @children}
            id={"activity-child-#{child.id}"}
            entry={child}
            time_zone={@time_zone}
          />
        </div>
      </div>
    </div>
    """
  end

  defp toggle_label(true, count), do: "Hide #{entity_word(count)}"
  defp toggle_label(false, count), do: "Show #{entity_word(count)}"

  defp entity_word(1), do: "1 affected entity"
  defp entity_word(count), do: "#{count} affected entities"
end
