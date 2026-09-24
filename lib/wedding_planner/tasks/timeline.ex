defmodule WeddingPlanner.Tasks.Timeline do
  @moduledoc """
  Pure timeline engine (`docs/modules/tasks-and-timeline.md` **TSK-21**, **TSK-22**,
  **TSK-23**; `docs/modules/invoices-and-budget.md` **BIL-06**; `.claude/plans/roadmap.md`
  **DR-68**). No `Repo`, no Ecto queries, no Phoenix, no `Money` arithmetic — a function of
  plain `%Task{}`/`%Event{}`/`%Invoice{}` structs, a built `WeddingPlanner.Tasks.Graph.t()`,
  caller-supplied invoice totals and `today` (the *viewer's* date, `DR-44`; never computed
  here). `build/2` returns everything the `/timeline` screen draws as one view model, so the
  screen only positions and styles; `chain/2` is the click-to-trace highlight.

  ## Placed vs side lane (`TSK-21`, `TSK-03`, `TSK-13`)

  **Placed** = every task, done included (TSK-21 "colour-coded by status"), with a non-nil
  effective deadline (`Graph.effective_deadline/2` — never re-derived here). Every other
  task — no deadline at all, or an unresolved relative deadline (TSK-03) — is in the
  **side lane**, carrying its `WeddingPlanner.Tasks.Deadline.resolve/2` result (`:none` or
  `{:unresolved, event}`) so the screen can word "8 weeks before Reception — date not set".
  Invariant: every task is placed xor in the side lane, exactly once.

  ## Lanes (`DR-68`)

  One `:chain` lane per connected component of the dependency graph (edges treated as
  undirected) with ≥ 2 tasks and at least one placed task, ordered by the component's
  earliest placed date (ties by the component's lowest task id); then one `:independent`
  lane ("No dependencies") holding every placed task in a singleton component. Lane ids are
  stable: `{:chain, lowest_task_id_in_component}` / `:independent`. A lane with no placed
  point is omitted (so `row_count` is always ≥ 1). A chain member without an effective
  deadline is in the side lane; its placed siblings keep their chain lane.

  ## Rows (`DR-68`)

  Within a lane, points are sorted by `{x, title (case-insensitive), id}` and assigned
  greedily first-fit: a point goes into the first row whose last point is ≥ `min_gap` to
  its left, else into a new row. Deterministic. Invariant: consecutive points within a row
  are ≥ `min_gap` apart.

  ## Arrows (`DR-68`, `DR-35`)

  One `%{from: prerequisite_id, to: dependent_id}` per direct edge with **both** ends placed.
  Invariant (TSK-13): a prerequisite's effective deadline is ≤ its dependent's, so
  `from`'s `x` ≤ `to`'s `x` — never special-cased, asserted by a property test.

  ## Tone (`TSK-11`, `TSK-23`, `DR-68`)

  `:done` if the status is done; else `:overdue` if the effective deadline is before `today`
  (TSK-23 — it wins over blocked, captioned "Overdue · Blocked" via `blocked?`); else
  `:blocked` if `Graph.blocked?/2` (TSK-11); else `:actionable`. `in_progress?` is exposed
  separately (an in-progress task is `:actionable` in tone). `waits_on` lists the unfinished
  direct dependencies as `%Task{}`s, in `Graph.unfinished_dependencies/2` order.

  ## Milestones (`TSK-21`, `BIL-06`, example T5)

  Every event with a date (`kind: :event`, labelled with `event.name`) and every **unpaid**
  invoice with a due date (`kind: :invoice`, labelled with `invoice.label`, `amount:` the
  caller-supplied total, `overdue?: due_date < today`). Paid invoices and undated items never
  appear. Sorted by `{date, kind_rank, label (case-insensitive), id}` (event 0, invoice 1).

  ## Axis (`DR-68`, `NFR-12`)

  With no dated item at all (no placed task, no milestone), `range: nil`, `today.x: nil`
  and no ticks. Otherwise start = min(earliest dated item, today) − 7 days and end =
  max(latest dated item, today) + 7 days, widened symmetrically to span ≥ 60 days.
  Positions are **integers** in `0..10_000` (hundredths of a percent of the axis width):
  `x = div(days_since_start * 10_000, span_days)` — no floats (NFR-12's spirit), monotone in
  date. Ticks are the 1st of every month within the range — only January, April, July and
  October when the range exceeds 24 months — each `%{date, x}`; the screen labels them as
  months (a month label is not a date, so NFR-23 does not apply to them).

  ## Phone list (`TSK-22`)

  Placed tasks and milestones in one list sorted by `{date, kind_rank, title
  (case-insensitive), id}` (event 0, invoice 1, task 2), followed by the side-lane tasks by
  `{title (case-insensitive), id}`. Each entry's `item` is the very point / milestone /
  side-lane map shown on the axis, so it carries the same tone and flags.

  ## Dates

  Every date comparison goes through `Date.compare/2`, `Date.diff/2` or
  `Date.to_gregorian_days/1` (as a sort key) — never `<`/`Enum.min/1`/`Enum.sort/1` on
  `%Date{}` structs directly (see `WeddingPlanner.Tasks.Graph`'s moduledoc for why).
  """

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Tasks.Deadline
  alias WeddingPlanner.Tasks.Graph
  alias WeddingPlanner.Tasks.Task

  @scale 10_000
  @padding_days 7
  @min_span_days 60
  @default_min_gap 1_200
  @quarter_months [1, 4, 7, 10]
  @kind_rank %{event: 0, invoice: 1, task: 2}

  @type invoice_input :: %{invoice: Invoice.t(), total: Money.t()}
  @type input :: %{
          tasks: [Task.t()],
          graph: Graph.t(),
          events: [Event.t()],
          invoices: [invoice_input()],
          today: Date.t()
        }
  @type x :: 0..10_000
  @type tone :: :done | :overdue | :blocked | :actionable
  @type lane_id :: {:chain, term()} | :independent
  @type point :: %{
          task: Task.t(),
          date: Date.t(),
          x: x(),
          lane: lane_id(),
          row: non_neg_integer(),
          tone: tone(),
          blocked?: boolean(),
          overdue?: boolean(),
          in_progress?: boolean(),
          waits_on: [Task.t()]
        }
  @type milestone :: %{
          kind: :event | :invoice,
          id: term(),
          label: String.t(),
          date: Date.t(),
          x: x(),
          amount: Money.t() | nil,
          overdue?: boolean()
        }
  @type side_item :: %{
          task: Task.t(),
          resolved: Deadline.resolved(),
          tone: tone(),
          blocked?: boolean(),
          in_progress?: boolean(),
          waits_on: [Task.t()]
        }
  @type lane :: %{
          id: lane_id(),
          kind: :chain | :independent,
          row_count: pos_integer(),
          points: [point()]
        }
  @type list_item :: %{
          kind: :task | :event | :invoice | :side,
          date: Date.t() | nil,
          item: point() | milestone() | side_item()
        }
  @type t :: %{
          range: {Date.t(), Date.t()} | nil,
          today: %{date: Date.t(), x: x() | nil},
          ticks: [%{date: Date.t(), x: x()}],
          lanes: [lane()],
          arrows: [%{from: term(), to: term()}],
          milestones: [milestone()],
          side_lane: [side_item()],
          list: [list_item()]
        }

  @doc """
  Builds the timeline view model (see the moduledoc). `input.graph` must have been built
  from `input.tasks` (with the same events), and `input.events` must cover every event a
  relative deadline refers to. Options: `min_gap:` the minimum horizontal distance between
  two points sharing a row, in `0..10_000` units (default `#{@default_min_gap}`).
  """
  @spec build(input(), keyword()) :: t()
  def build(
        %{tasks: tasks, graph: graph, events: events, invoices: invoices, today: %Date{} = today},
        opts \\ []
      ) do
    min_gap = Keyword.get(opts, :min_gap, @default_min_gap)
    tasks_by_id = Map.new(tasks, &{&1.id, &1})
    events_by_id = Map.new(events, &{&1.id, &1})

    {placed, unplaced} =
      Enum.split_with(tasks, &(Graph.effective_deadline(graph, &1.id) != nil))

    raw_milestones = raw_milestones(events, invoices, today)

    dated =
      Enum.map(placed, &Graph.effective_deadline(graph, &1.id)) ++
        Enum.map(raw_milestones, & &1.date)

    range = range(dated, today)
    to_x = fn date -> x_of(range, date) end

    lanes = lanes(placed, tasks, tasks_by_id, graph, today, to_x, min_gap)
    points = Enum.flat_map(lanes, & &1.points)
    placed_ids = MapSet.new(placed, & &1.id)

    milestones =
      raw_milestones
      |> Enum.map(&Map.put(&1, :x, to_x.(&1.date)))
      |> Enum.sort_by(&{day(&1.date), @kind_rank[&1.kind], downcase(&1.label), &1.id})

    side_lane =
      unplaced
      |> Enum.map(&side_item(&1, graph, tasks_by_id, events_by_id))
      |> Enum.sort_by(&{downcase(&1.task.title), &1.task.id})

    %{
      range: range,
      today: %{date: today, x: range && to_x.(today)},
      ticks: ticks(range, to_x),
      lanes: lanes,
      arrows: arrows(placed, graph, placed_ids),
      milestones: milestones,
      side_lane: side_lane,
      list: phone_list(points, milestones, side_lane)
    }
  end

  @doc """
  The ids to highlight when `id` is selected: every transitive prerequisite (ancestor),
  every transitive dependent (descendant) and `id` itself. Terminates on cyclic input
  (`DR-35`'s cycle tolerance) — every walk carries a visited set.
  """
  @spec chain(Graph.t(), term()) :: MapSet.t()
  def chain(graph, id) do
    ancestors = reach(graph, [id], MapSet.new([id]), &Graph.waits_on/2)
    descendants = reach(graph, [id], MapSet.new([id]), &Graph.waited_on_by/2)
    MapSet.union(ancestors, descendants)
  end

  # -- axis ----------------------------------------------------------------------------

  defp range([], _today), do: nil

  defp range(dates, today) do
    earliest = Enum.min([today | dates], Date)
    latest = Enum.max([today | dates], Date)
    start_date = Date.add(earliest, -@padding_days)
    end_date = Date.add(latest, @padding_days)
    span = Date.diff(end_date, start_date)

    if span < @min_span_days do
      extra = @min_span_days - span
      before = div(extra, 2)
      {Date.add(start_date, -before), Date.add(end_date, extra - before)}
    else
      {start_date, end_date}
    end
  end

  defp x_of(nil, _date), do: nil

  defp x_of({start_date, end_date}, date) do
    div(Date.diff(date, start_date) * @scale, Date.diff(end_date, start_date))
  end

  defp ticks(nil, _to_x), do: []

  defp ticks({start_date, end_date}, to_x) do
    first =
      if start_date.day == 1,
        do: start_date,
        else: start_date |> Date.beginning_of_month() |> Date.shift(month: 1)

    quarterly? = Date.compare(end_date, Date.shift(start_date, month: 24)) == :gt

    first
    |> Stream.iterate(&Date.shift(&1, month: 1))
    |> Enum.take_while(&(Date.compare(&1, end_date) != :gt))
    |> Enum.filter(&(not quarterly? or &1.month in @quarter_months))
    |> Enum.map(&%{date: &1, x: to_x.(&1)})
  end

  # -- lanes and rows ------------------------------------------------------------------

  defp lanes(placed, tasks, tasks_by_id, graph, today, to_x, min_gap) do
    component_of = components(tasks, graph)

    placed
    |> Enum.map(&point(&1, graph, tasks_by_id, today, to_x))
    |> Enum.group_by(fn point ->
      case Map.fetch!(component_of, point.task.id) do
        {_lowest_id, 1} -> :independent
        {lowest_id, _size} -> {:chain, lowest_id}
      end
    end)
    |> Enum.sort_by(fn
      {:independent, _points} ->
        {1, 0, 0}

      {{:chain, lowest_id}, points} ->
        {0, points |> Enum.map(&day(&1.date)) |> Enum.min(), lowest_id}
    end)
    |> Enum.map(fn {lane_id, points} -> lane(lane_id, points, min_gap) end)
  end

  defp lane(lane_id, points, min_gap) do
    {points, row_ends} =
      points
      |> Enum.sort_by(&{&1.x, downcase(&1.task.title), &1.task.id})
      |> Enum.map_reduce([], fn point, row_ends ->
        row = first_fit(row_ends, point.x, min_gap, 0)

        row_ends =
          if row == length(row_ends),
            do: row_ends ++ [point.x],
            else: List.replace_at(row_ends, row, point.x)

        {%{point | lane: lane_id, row: row}, row_ends}
      end)

    kind = if lane_id == :independent, do: :independent, else: :chain
    %{id: lane_id, kind: kind, row_count: length(row_ends), points: points}
  end

  defp first_fit([], _x, _min_gap, row), do: row

  defp first_fit([last_x | rest], x, min_gap, row) do
    if x - last_x >= min_gap, do: row, else: first_fit(rest, x, min_gap, row + 1)
  end

  # Connected components of the dependency graph with edges treated as undirected:
  # id => {lowest id in its component, component size}.
  defp components(tasks, graph) do
    tasks
    |> Enum.map(& &1.id)
    |> Enum.sort()
    |> Enum.reduce(%{}, fn id, acc ->
      if Map.has_key?(acc, id) do
        acc
      else
        members = reach(graph, [id], MapSet.new([id]), &neighbours/2)
        info = {Enum.min(members), MapSet.size(members)}
        Enum.reduce(members, acc, &Map.put(&2, &1, info))
      end
    end)
  end

  defp neighbours(graph, id), do: Graph.waits_on(graph, id) ++ Graph.waited_on_by(graph, id)

  # BFS over `step`, with a visited set so cyclic input terminates.
  defp reach(_graph, [], visited, _step), do: visited

  defp reach(graph, [id | queue], visited, step) do
    new = graph |> step.(id) |> Enum.reject(&MapSet.member?(visited, &1)) |> Enum.uniq()
    reach(graph, queue ++ new, Enum.reduce(new, visited, &MapSet.put(&2, &1)), step)
  end

  # -- items ---------------------------------------------------------------------------

  defp point(task, graph, tasks_by_id, today, to_x) do
    date = Graph.effective_deadline(graph, task.id)
    blocked? = Graph.blocked?(graph, task.id)
    done? = task.status == :done
    overdue? = not done? and Date.compare(date, today) == :lt

    %{
      task: task,
      date: date,
      x: to_x.(date),
      lane: nil,
      row: 0,
      tone: tone(done?, overdue?, blocked?),
      blocked?: blocked?,
      overdue?: overdue?,
      in_progress?: task.status == :in_progress,
      waits_on: waits_on(graph, task, tasks_by_id)
    }
  end

  defp side_item(task, graph, tasks_by_id, events_by_id) do
    blocked? = Graph.blocked?(graph, task.id)

    %{
      task: task,
      resolved: Deadline.resolve(task, events_by_id),
      tone: tone(task.status == :done, false, blocked?),
      blocked?: blocked?,
      in_progress?: task.status == :in_progress,
      waits_on: waits_on(graph, task, tasks_by_id)
    }
  end

  defp tone(true = _done?, _overdue?, _blocked?), do: :done
  defp tone(false, true = _overdue?, _blocked?), do: :overdue
  defp tone(false, false, true = _blocked?), do: :blocked
  defp tone(false, false, false), do: :actionable

  defp waits_on(graph, task, tasks_by_id) do
    graph
    |> Graph.unfinished_dependencies(task.id)
    |> Enum.map(&Map.fetch!(tasks_by_id, &1))
  end

  defp raw_milestones(events, invoices, today) do
    event_milestones =
      for %Event{date: %Date{} = date} = event <- events do
        %{kind: :event, id: event.id, label: event.name, date: date, amount: nil, overdue?: false}
      end

    invoice_milestones =
      for %{invoice: %Invoice{due_date: %Date{} = due} = invoice, total: total} <- invoices,
          not Invoice.paid?(invoice) do
        %{
          kind: :invoice,
          id: invoice.id,
          label: invoice.label,
          date: due,
          amount: total,
          overdue?: Date.compare(due, today) == :lt
        }
      end

    event_milestones ++ invoice_milestones
  end

  defp arrows(placed, graph, placed_ids) do
    for task <- placed,
        prerequisite <- Graph.waits_on(graph, task.id),
        MapSet.member?(placed_ids, prerequisite) do
      %{from: prerequisite, to: task.id}
    end
    |> Enum.sort_by(&{&1.from, &1.to})
  end

  defp phone_list(points, milestones, side_lane) do
    dated =
      Enum.map(points, &{:task, &1.date, &1.task.title, &1.task.id, &1}) ++
        Enum.map(milestones, &{&1.kind, &1.date, &1.label, &1.id, &1})

    dated_items =
      dated
      |> Enum.sort_by(fn {kind, date, title, id, _item} ->
        {day(date), @kind_rank[kind], downcase(title), id}
      end)
      |> Enum.map(fn {kind, date, _title, _id, item} -> %{kind: kind, date: date, item: item} end)

    dated_items ++ Enum.map(side_lane, &%{kind: :side, date: nil, item: &1})
  end

  defp day(date), do: Date.to_gregorian_days(date)

  defp downcase(text), do: text |> to_string() |> String.downcase()
end
