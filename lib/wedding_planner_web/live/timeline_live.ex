defmodule WeddingPlannerWeb.Live.TimelineLive do
  @moduledoc """
  `/timeline` (task 77; `docs/modules/tasks-and-timeline.md` **TSK-21**, **TSK-22**,
  **TSK-23**; `docs/modules/invoices-and-budget.md` **BIL-06**; `.claude/plans/roadmap.md`
  **DR-68**): the locked "Timeline v2" design over real data — a horizontal date axis with
  dependency chains in their own lanes, arrows, a today marker and milestones, plus a
  chronological phone list (`TSK-22`). Every placement decision (lanes, rows, arrows,
  tones, ticks, the list) is `WeddingPlanner.Tasks.Timeline.build/2`'s job — this module
  only loads data, holds URL/transient state, and hands the view model to
  `WeddingPlannerWeb.TimelineComponents`.

  ## Selection lives in the URL (`?task=<id>`, `DR-44`)

  `handle_params/3` (not `mount/3`) is the only place `@selected` is set, so a reload keeps
  it. `Timeline.chain/2` is only computed when the selected task is itself **placed**
  (exists among the built lanes' points) — selecting a side-lane task (no effective
  deadline) has no highlighting effect on the axis at all (the task file's "no chain on
  the axis" case for that situation); the reading panel still works either way, since its
  "Waits on"/"Waiting on this" go straight through `Graph.waits_on/2`/`waited_on_by/2`,
  not through the axis placement.

  ## Live (`XC-01`)

  Subscribes to `:task`, `:event`, `:invoice` and `:invoice_line` (an invoice's lines
  changing its total, or a due date/paid-on change, both matter to `BIL-06`'s milestones) —
  every one of them triggers a full `refresh/1` (`NFR-33`, this app's size).

  ## Data sources

  Tasks and the dependency graph: `WeddingPlanner.Tasks.list_tasks_with_graph/0` (never
  re-queried piecemeal). Events and invoice totals: one
  `WeddingPlanner.Valuation.Snapshot.load(Repo)`, with
  `WeddingPlanner.Valuation.Invoices.total/2` computed only for the unpaid, dated invoices
  `Timeline.build/2` can actually turn into a milestone (`BIL-06`). "Today" is
  `WeddingPlanner.Tasks.TodoList.today(@time_zone)` — the viewer's own date (`NFR-22`),
  via `WeddingPlannerWeb.Live.TimeZoneHook`, never `Date.utc_today/0`.

  `Timeline.build/2`'s `min_gap` option is passed explicitly as
  `WeddingPlannerWeb.TimelineComponents.label_gap/0` (review feedback, not a `docs/`
  change) — the same constant `TimelineComponents` derives each task label's CSS
  `max-width` from, so a label can never be wider than the x-distance the engine already
  guarantees between two row-mates. One module attribute, read from both places, rather
  than two numbers that could drift apart.

  ## Phone axis toggle (`TSK-22`, `NFR-31`)

  `@phone_axis?` is a plain transient assign (not URL-tracked — nothing asks for it to
  survive a reload): `false` shows the chronological list below `md`, `true` shows the
  axis instead, scrolling inside its own container. At `md` and up the axis always shows
  regardless of this assign (see `TimelineComponents.timeline_axis/1`'s host markup).
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.TimelineComponents

  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks
  alias WeddingPlanner.Tasks.Graph
  alias WeddingPlanner.Tasks.Timeline
  alias WeddingPlanner.Tasks.TodoList
  alias WeddingPlanner.Valuation.Invoices, as: InvoiceValuation
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Format
  alias WeddingPlannerWeb.TaskComponents

  on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Realtime.subscribe(:task)
      Realtime.subscribe(:event)
      Realtime.subscribe(:invoice)
      Realtime.subscribe(:invoice_line)
    end

    socket =
      socket
      |> assign(:page_title, "Timeline")
      |> assign(:phone_axis?, false)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:selected, parse_task_param(params["task"]))
      |> refresh()

    {:noreply, socket}
  end

  @impl true
  def handle_event("show_phone_axis", _params, socket) do
    {:noreply, assign(socket, :phone_axis?, true)}
  end

  def handle_event("show_phone_list", _params, socket) do
    {:noreply, assign(socket, :phone_axis?, false)}
  end

  @impl true
  def handle_info({Realtime, resource, _event}, socket)
      when resource in [:task, :event, :invoice, :invoice_line] do
    {:noreply, refresh(socket)}
  end

  # -- helpers ---------------------------------------------------------------------------

  defp parse_task_param(nil), do: nil

  defp parse_task_param(id_str) do
    case Integer.parse(id_str) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp refresh(socket) do
    {tasks, graph} = Tasks.list_tasks_with_graph()
    snapshot = Snapshot.load(Repo)
    today = TodoList.today(socket.assigns.time_zone)

    invoices =
      snapshot.invoices
      |> Enum.reject(&InvoiceValuation.paid?/1)
      |> Enum.filter(&(&1.due_date != nil))
      |> Enum.map(&%{invoice: &1, total: InvoiceValuation.total(snapshot, &1)})

    timeline =
      Timeline.build(
        %{
          tasks: tasks,
          graph: graph,
          events: snapshot.events,
          invoices: invoices,
          today: today
        },
        min_gap: label_gap()
      )

    tasks_by_id = Map.new(tasks, &{&1.id, &1})
    points_by_id = timeline.lanes |> Enum.flat_map(& &1.points) |> Map.new(&{&1.task.id, &1})
    side_by_id = Map.new(timeline.side_lane, &{&1.task.id, &1})
    selected = socket.assigns.selected

    chain =
      if selected != nil and Map.has_key?(points_by_id, selected) do
        Timeline.chain(graph, selected)
      else
        MapSet.new()
      end

    socket
    |> assign(:timeline, timeline)
    |> assign(:total_tasks, length(tasks))
    |> assign(:chain, chain)
    |> assign(:panel, panel_data(selected, tasks_by_id, points_by_id, side_by_id, graph))
  end

  # `every task is placed xor in the side lane, exactly once` (`Timeline`'s own
  # invariant) — so once `id` is a known task and not in `points_by_id`, `side_by_id` is
  # guaranteed to have it.
  defp panel_data(nil, _tasks_by_id, _points_by_id, _side_by_id, _graph), do: nil

  defp panel_data(id, tasks_by_id, points_by_id, side_by_id, graph) do
    case Map.fetch(tasks_by_id, id) do
      :error ->
        nil

      {:ok, task} ->
        deadline_line =
          case Map.fetch(points_by_id, id) do
            {:ok, point} -> point_deadline_line(point)
            :error -> side_deadline_line(Map.fetch!(side_by_id, id))
          end

        %{
          task: task,
          deadline_line: deadline_line,
          waits_on: graph |> Graph.waits_on(id) |> Enum.map(&Map.fetch!(tasks_by_id, &1)),
          waiting_on_this:
            graph |> Graph.waited_on_by(id) |> Enum.map(&Map.fetch!(tasks_by_id, &1))
        }
    end
  end

  defp point_deadline_line(point) do
    with_tone("Effective deadline #{Format.date(point.date)}", tone_label(point))
  end

  defp side_deadline_line(side_item) do
    with_tone(TaskComponents.deadline_text(side_item.task), tone_label(side_item))
  end

  defp with_tone(base, nil), do: base
  defp with_tone(base, label), do: base <> " · " <> label

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width="wide">
      <.header>Timeline</.header>

      <div id="timeline" class="space-y-6">
        <p
          :if={@total_tasks == 0}
          id="timeline-empty"
          class="rounded-field border border-dashed border-line-strong p-6 text-center text-sm text-ink-faint"
        >
          No tasks yet.
          <.link navigate={~p"/tasks"} class="font-medium text-accent hover:underline">
            Go to Tasks
          </.link>
        </p>

        <div :if={@total_tasks > 0} class="space-y-6">
          <.timeline_legend :if={@timeline.range} id="timeline-legend" />

          <p
            :if={@timeline.range == nil}
            id="timeline-empty"
            class="rounded-field border border-dashed border-line-strong p-6 text-center text-sm text-ink-faint"
          >
            Nothing dated yet — tasks with a deadline, event dates and unpaid invoice due dates
            appear here.
          </p>

          <div :if={@timeline.range}>
            <div
              id="timeline-list-wrapper"
              class={[if(@phone_axis?, do: "hidden", else: "block"), "md:hidden"]}
            >
              <.timeline_list id="timeline-list" list={@timeline.list} selected={@selected} />
              <button
                type="button"
                id="timeline-show-axis"
                phx-click="show_phone_axis"
                class="mt-3 w-full rounded-field border border-line-strong px-3 py-2 text-sm font-medium text-ink-soft transition hover:bg-surface hover:text-ink"
              >
                Show timeline
              </button>
            </div>

            <div
              id="timeline-axis-wrapper"
              class={[if(@phone_axis?, do: "block", else: "hidden"), "md:block"]}
            >
              <button
                type="button"
                id="timeline-show-list"
                phx-click="show_phone_list"
                class="mb-3 rounded-field border border-line-strong px-3 py-2 text-sm font-medium text-ink-soft transition hover:bg-surface hover:text-ink md:hidden"
              >
                Show list
              </button>
              <div class="relative overflow-x-auto rounded-field border border-line bg-surface-raised p-4">
                <.timeline_axis
                  id="timeline-axis"
                  timeline={@timeline}
                  selected={@selected}
                  chain={@chain}
                />
              </div>
            </div>
          </div>

          <.timeline_side_lane
            id="timeline-side-lane"
            side_lane={@timeline.side_lane}
            selected={@selected}
          />

          <.timeline_panel :if={@panel} id="timeline-panel" panel={@panel} />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
