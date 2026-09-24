defmodule WeddingPlanner.Tasks.TimelineTest do
  @moduledoc """
  `WeddingPlanner.Tasks.Timeline` — the pure timeline view model
  (`docs/modules/tasks-and-timeline.md` TSK-21, TSK-22, TSK-23; `docs/modules/invoices-and-budget.md`
  BIL-06; examples T4 (timeline half) and T5; `.claude/plans/roadmap.md` DR-68). Pure over
  in-memory `%Task{}`/`%Event{}`/`%Invoice{}` structs and a `Graph.t()` built with
  `Graph.build/3`, as `todo_list_test.exs` does; no `Repo`, no LiveView.

  The property tests (fixed `:rand` seeds, no StreamData — `comparison_test.exs` style) hold
  small independent oracles: lane membership is checked against a union-find over the raw
  edge list and arrows against the raw edge list, sharing no code with the engine.
  """

  use ExUnit.Case, async: true

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Tasks.Graph
  alias WeddingPlanner.Tasks.Task
  alias WeddingPlanner.Tasks.Timeline

  @today ~D[2027-06-15]

  # -- helpers -------------------------------------------------------------------------

  defp eur(amount), do: WeddingPlanner.Money.new(amount)

  defp task(id, opts \\ []) do
    base = %Task{
      id: id,
      title: Keyword.get(opts, :title, "Task #{id}"),
      status: Keyword.get(opts, :status, :to_do),
      deadline_kind: :none
    }

    case Keyword.get(opts, :deadline) do
      nil ->
        base

      %Date{} = date ->
        %{base | deadline_kind: :fixed, deadline_date: date}

      {amount, unit, direction, event_id} ->
        %{
          base
          | deadline_kind: :relative,
            deadline_amount: amount,
            deadline_unit: unit,
            deadline_direction: direction,
            deadline_event_id: event_id
        }
    end
  end

  defp invoice(id, opts) do
    %{
      invoice: %Invoice{
        id: id,
        label: Keyword.get(opts, :label, "Invoice #{id}"),
        invoice_date: ~D[2026-09-01],
        due_date: Keyword.get(opts, :due),
        paid_on: Keyword.get(opts, :paid_on)
      },
      total: Keyword.get(opts, :total, eur(100))
    }
  end

  defp timeline(tasks, edges, opts \\ []) do
    events = Keyword.get(opts, :events, [])
    graph = Graph.build(tasks, edges, Map.new(events, &{&1.id, &1}))

    Timeline.build(
      %{
        tasks: tasks,
        graph: graph,
        events: events,
        invoices: Keyword.get(opts, :invoices, []),
        today: Keyword.get(opts, :today, @today)
      },
      Keyword.take(opts, [:min_gap])
    )
  end

  defp points(tl), do: Enum.flat_map(tl.lanes, & &1.points)

  defp point!(tl, id), do: Enum.find(points(tl), &(&1.task.id == id)) || flunk("#{id} not placed")

  defp point_ids(lane), do: lane.points |> Enum.map(& &1.task.id) |> Enum.sort()

  defp side_ids(tl), do: Enum.map(tl.side_lane, & &1.task.id)

  # -- T5 (BIL-06) -----------------------------------------------------------------------

  describe "T5 — unpaid invoice milestone" do
    @describetag example: "T5"

    test "an unpaid invoice due 2027-03-01 is a milestone with its amount; once paid it is gone" do
      unpaid = invoice(1, label: "Venue deposit", due: ~D[2027-03-01], total: eur(1_500))

      tl = timeline([], [], invoices: [unpaid], today: ~D[2026-09-24])

      assert [milestone] = tl.milestones
      assert %{kind: :invoice, id: 1, label: "Venue deposit", date: ~D[2027-03-01]} = milestone
      assert Money.equal?(milestone.amount, eur(1_500))
      assert milestone.overdue? == false
      assert [%{kind: :invoice, date: ~D[2027-03-01], item: ^milestone}] = tl.list

      paid = put_in(unpaid.invoice.paid_on, ~D[2026-10-01])
      tl = timeline([], [], invoices: [paid], today: ~D[2026-09-24])

      assert tl.milestones == []
      assert tl.list == []
    end
  end

  # -- T4 timeline half (TSK-03, TSK-21) -------------------------------------------------

  describe "T4 — relative deadline on an undated event" do
    @describetag example: "T4"

    test "unresolved: in the side lane, not placed; with Reception dated 2028-05-13, placed at 2028-02-19" do
      reception = %Event{id: 1, name: "Reception", date: nil}
      invitations = task(1, title: "Send invitations", deadline: {12, :weeks, :before, 1})

      tl = timeline([invitations], [], events: [reception])

      assert [%{task: ^invitations, resolved: {:unresolved, ^reception}}] = tl.side_lane
      assert tl.lanes == []
      assert tl.range == nil
      assert [%{kind: :side, date: nil}] = tl.list

      dated = %{reception | date: ~D[2028-05-13]}
      tl = timeline([invitations], [], events: [dated])

      assert tl.side_lane == []
      assert %{date: ~D[2028-02-19]} = point!(tl, 1)
      assert [%{kind: :event, date: ~D[2028-05-13], label: "Reception"}] = tl.milestones
    end
  end

  # -- tones (TSK-11, TSK-23, DR-68) -----------------------------------------------------

  describe "tones" do
    test "done, overdue, blocked, actionable, overdue ∧ blocked, in progress, waits_on" do
      yesterday = Date.add(@today, -1)
      later = Date.add(@today, 30)

      tasks = [
        task(1, status: :done, deadline: yesterday),
        task(2, deadline: yesterday),
        task(3, deadline: later),
        task(4, title: "Book caterer", deadline: Date.add(later, 10)),
        task(5, deadline: yesterday),
        task(6, title: "Confirm venue"),
        task(7, status: :in_progress, deadline: later),
        task(8, status: :done)
      ]

      # 3 waits on 4 (4 inherits 3's earlier deadline); 5 waits on 6 (6 inherits yesterday).
      tl = timeline(tasks, [{3, 4}, {5, 6}, {4, 8}])

      assert %{tone: :done, overdue?: false, blocked?: false} = point!(tl, 1)
      assert %{tone: :overdue, overdue?: true, blocked?: false} = point!(tl, 2)

      assert %{tone: :blocked, blocked?: true, overdue?: false, waits_on: [%Task{id: 4}]} =
               point!(tl, 3)

      # 4 waits only on a done task: not blocked.
      assert %{tone: :actionable, blocked?: false, waits_on: []} = point!(tl, 4)

      assert %{
               tone: :overdue,
               overdue?: true,
               blocked?: true,
               waits_on: [%Task{title: "Confirm venue"}]
             } =
               point!(tl, 5)

      assert %{tone: :actionable, in_progress?: true} = point!(tl, 7)
      assert %{in_progress?: false} = point!(tl, 3)
    end

    test "side-lane tasks carry tone, blocked? and waits_on too" do
      tasks = [task(1), task(2, status: :in_progress), task(3, status: :done)]
      tl = timeline(tasks, [{1, 2}])

      by_id = Map.new(tl.side_lane, &{&1.task.id, &1})

      assert %{tone: :blocked, blocked?: true, waits_on: [%Task{id: 2}], resolved: :none} =
               by_id[1]

      assert %{tone: :actionable, in_progress?: true} = by_id[2]
      assert %{tone: :done} = by_id[3]
    end
  end

  # -- lanes and rows (DR-68) ------------------------------------------------------------

  describe "lanes" do
    test "the design's demo chain is one :chain lane; independent tasks share :independent" do
      tasks = [
        task(1, title: "Send invitations", deadline: ~D[2027-07-01]),
        task(2, title: "Confirm catering headcount", deadline: ~D[2027-08-01]),
        task(3, title: "Print menus", deadline: ~D[2027-09-01]),
        task(4, title: "Seating plan", deadline: ~D[2027-09-05]),
        task(5, title: "Order cake", deadline: ~D[2027-07-10]),
        task(6, title: "Final dress fitting", deadline: ~D[2027-08-20])
      ]

      tl = timeline(tasks, [{2, 1}, {3, 2}, {4, 2}])

      assert [chain, independent] = tl.lanes
      assert %{id: {:chain, 1}, kind: :chain} = chain
      assert point_ids(chain) == [1, 2, 3, 4]
      assert Enum.all?(chain.points, &(&1.lane == {:chain, 1}))
      assert %{id: :independent, kind: :independent} = independent
      assert point_ids(independent) == [5, 6]
      assert Enum.all?(independent.points, &(&1.lane == :independent))
    end

    test "two separate chains become two lanes ordered by earliest placed date" do
      tasks = [
        task(1, deadline: ~D[2027-09-01]),
        task(2, deadline: ~D[2027-10-01]),
        task(3, deadline: ~D[2027-08-01]),
        task(4, deadline: ~D[2027-11-01])
      ]

      tl = timeline(tasks, [{2, 1}, {4, 3}])

      assert Enum.map(tl.lanes, & &1.id) == [{:chain, 3}, {:chain, 1}]
    end

    test "chains tied on earliest date are ordered by lowest task id" do
      tasks = [
        task(3, deadline: ~D[2027-08-01]),
        task(4, deadline: ~D[2027-09-01]),
        task(1, deadline: ~D[2027-08-01]),
        task(2, deadline: ~D[2027-10-01])
      ]

      tl = timeline(tasks, [{4, 3}, {2, 1}])

      assert Enum.map(tl.lanes, & &1.id) == [{:chain, 1}, {:chain, 3}]
    end

    test "a chain with an unplaced member keeps its placed members; the unplaced one is in the side lane" do
      # 2 waits on 1 and has no deadline of its own: 1's deadline does not flow to it.
      tasks = [task(1, deadline: ~D[2027-08-01]), task(2), task(3, deadline: ~D[2027-09-01])]

      tl = timeline(tasks, [{2, 1}, {3, 1}])

      assert [%{id: {:chain, 1}} = chain] = tl.lanes
      assert point_ids(chain) == [1, 3]
      assert side_ids(tl) == [2]
    end

    test "a chain whose tasks are all unplaced produces no lane" do
      tl = timeline([task(1), task(2)], [{2, 1}])

      assert tl.lanes == []
      assert Enum.sort(side_ids(tl)) == [1, 2]
    end
  end

  describe "rows" do
    test "points too close together stack into rows; far-apart points share row 0" do
      tasks = [
        task(1, title: "B", deadline: ~D[2027-08-01]),
        task(2, title: "A", deadline: ~D[2027-08-01]),
        task(3, title: "C", deadline: ~D[2027-08-02]),
        task(4, title: "D", deadline: ~D[2028-06-01])
      ]

      tl = timeline(tasks, [])

      assert [%{row_count: 3} = lane] = tl.lanes
      # sorted by {x, title, id}: A (2), B (1) on the same x, then C, then D far right.
      assert Enum.map(lane.points, &{&1.task.id, &1.row}) == [{2, 0}, {1, 1}, {3, 2}, {4, 0}]
    end

    test "min_gap is honoured" do
      tasks = [task(1, deadline: ~D[2027-08-01]), task(2, deadline: ~D[2027-08-02])]

      assert [%{row_count: 2}] = timeline(tasks, []).lanes
      assert [%{row_count: 1}] = timeline(tasks, [], min_gap: 0).lanes
    end
  end

  # -- arrows (DR-68) --------------------------------------------------------------------

  describe "arrows" do
    test "exactly the direct edges with both ends placed, prerequisite → dependent" do
      tasks = [
        task(1, deadline: ~D[2027-07-01]),
        task(2, deadline: ~D[2027-08-01]),
        task(3, deadline: ~D[2027-09-01]),
        task(4, deadline: ~D[2027-09-05]),
        task(7)
      ]

      # 7 waits on 4 but has no deadline — unplaced, so no arrow.
      tl = timeline(tasks, [{2, 1}, {3, 2}, {4, 2}, {7, 4}])

      assert tl.arrows == [%{from: 1, to: 2}, %{from: 2, to: 3}, %{from: 2, to: 4}]
    end
  end

  # -- axis (DR-68, NFR-12) --------------------------------------------------------------

  describe "axis" do
    test "range pads 7 days either side of the dated items and today; x is an integer" do
      tl = timeline([task(1, deadline: ~D[2027-06-01])], [], today: ~D[2027-01-10])

      assert tl.range == {~D[2027-01-03], ~D[2027-06-08]}
      assert tl.today == %{date: ~D[2027-01-10], x: div(7 * 10_000, 156)}
      assert point!(tl, 1).x == div(149 * 10_000, 156)

      assert Enum.map(tl.ticks, & &1.date) ==
               [~D[2027-02-01], ~D[2027-03-01], ~D[2027-04-01], ~D[2027-05-01], ~D[2027-06-01]]
    end

    test "every position is an integer in 0..10_000 (NFR-12: no floats)" do
      tasks = [task(1, deadline: ~D[2027-03-07]), task(2, deadline: ~D[2027-11-19])]
      events = [%Event{id: 1, name: "Reception", date: ~D[2027-09-13]}]
      invoices = [invoice(1, due: ~D[2027-05-03])]

      tl = timeline(tasks, [], events: events, invoices: invoices, today: ~D[2027-02-11])

      xs =
        [tl.today.x] ++
          Enum.map(points(tl), & &1.x) ++
          Enum.map(tl.milestones, & &1.x) ++ Enum.map(tl.ticks, & &1.x)

      assert length(xs) > 4
      assert Enum.all?(xs, &(is_integer(&1) and &1 in 0..10_000))
    end

    test "a short range is widened symmetrically to 60 days" do
      tl = timeline([task(1, deadline: ~D[2027-01-10])], [], today: ~D[2027-01-10])

      # base {01-03, 01-17} spans 14 days; 46 more, 23 each side.
      assert tl.range == {~D[2026-12-11], ~D[2027-02-09]}
      assert Enum.map(tl.ticks, & &1.date) == [~D[2027-01-01], ~D[2027-02-01]]

      tl = timeline([task(1, deadline: ~D[2027-01-11])], [], today: ~D[2027-01-10])
      {start_date, end_date} = tl.range
      assert Date.diff(end_date, start_date) == 60
      # base {01-03, 01-18} spans 15 days; 45 more: 22 before, 23 after.
      assert tl.range == {~D[2026-12-12], ~D[2027-02-10]}
    end

    test "items before today stretch the range to the left" do
      tl = timeline([task(1, deadline: ~D[2026-11-20])], [], today: ~D[2027-03-01])

      assert tl.range == {~D[2026-11-13], ~D[2027-03-08]}
    end

    test "monthly ticks up to 24 months, quarterly (Jan/Apr/Jul/Oct) beyond" do
      tl = timeline([task(1, deadline: ~D[2028-12-20])], [], today: ~D[2027-01-10])
      assert length(tl.ticks) == 23
      assert hd(tl.ticks).date == ~D[2027-02-01]

      tl = timeline([task(1, deadline: ~D[2029-06-01])], [], today: ~D[2027-01-10])
      months = Enum.map(tl.ticks, & &1.date.month)
      assert Enum.uniq(months) |> Enum.sort() == [1, 4, 7, 10]
      assert hd(tl.ticks).date == ~D[2027-04-01]
      assert List.last(tl.ticks).date == ~D[2029-04-01]
      assert Enum.map(tl.ticks, & &1.x) == Enum.sort(Enum.map(tl.ticks, & &1.x))
    end

    test "no dated item at all: range nil, today's x nil, no ticks; the side lane still exists" do
      tl =
        timeline([task(1)], [],
          events: [%Event{id: 1, name: "Reception", date: nil}],
          invoices: [invoice(1, due: nil)]
        )

      assert tl.range == nil
      assert tl.today == %{date: @today, x: nil}
      assert tl.ticks == []
      assert tl.lanes == []
      assert tl.milestones == []
      assert side_ids(tl) == [1]
    end
  end

  # -- milestones (TSK-21, BIL-06) -------------------------------------------------------

  describe "milestones" do
    test "undated events and invoices without a due date are excluded; an overdue unpaid invoice is flagged" do
      events = [
        %Event{id: 1, name: "Civil ceremony", date: ~D[2027-09-10]},
        %Event{id: 2, name: "Brunch", date: nil}
      ]

      invoices = [
        invoice(1, label: "Late", due: Date.add(@today, -1), total: eur(250)),
        invoice(2, label: "Upcoming", due: Date.add(@today, 10)),
        invoice(3, label: "No due date", due: nil),
        invoice(4, label: "Paid", due: Date.add(@today, 5), paid_on: @today)
      ]

      tl = timeline([], [], events: events, invoices: invoices)

      assert [
               %{kind: :invoice, id: 1, label: "Late", overdue?: true},
               %{kind: :invoice, id: 2, overdue?: false},
               %{kind: :event, id: 1, label: "Civil ceremony", amount: nil, overdue?: false}
             ] = tl.milestones
    end
  end

  # -- phone list (TSK-22) ---------------------------------------------------------------

  describe "phone list" do
    test "dated items by {date, event < invoice < task, title}, then the side lane by title" do
      day = ~D[2027-08-01]

      tasks = [
        task(1, title: "Zebra", deadline: day),
        task(2, title: "apple", deadline: day),
        task(3, title: "B side"),
        task(4, title: "a side"),
        task(5, title: "Earlier", deadline: ~D[2027-07-01])
      ]

      tl =
        timeline(tasks, [],
          events: [%Event{id: 9, name: "Party", date: day}],
          invoices: [invoice(8, due: day)]
        )

      assert Enum.map(tl.list, &{&1.kind, item_id(&1)}) == [
               {:task, 5},
               {:event, 9},
               {:invoice, 8},
               {:task, 2},
               {:task, 1},
               {:side, 4},
               {:side, 3}
             ]

      assert Enum.find(tl.list, &(&1.kind == :task and &1.item.task.id == 5)).item ==
               point!(tl, 5)
    end
  end

  defp item_id(%{kind: kind, item: item}) when kind in [:task, :side], do: item.task.id
  defp item_id(%{item: item}), do: item.id

  # -- chain/2 (DR-68, DR-35) ------------------------------------------------------------

  describe "chain/2" do
    test "ancestors ∪ descendants ∪ self" do
      tasks = for id <- 1..5, do: task(id)
      graph = Graph.build(tasks, [{2, 1}, {3, 2}, {4, 2}], %{})

      assert Timeline.chain(graph, 2) == MapSet.new([1, 2, 3, 4])
      # a sibling is neither an ancestor nor a descendant
      assert Timeline.chain(graph, 3) == MapSet.new([1, 2, 3])
      assert Timeline.chain(graph, 5) == MapSet.new([5])
    end

    test "terminates on a cyclic edge list (DR-35 cycle tolerance)" do
      tasks = for id <- 1..4, do: task(id, deadline: ~D[2027-08-01])
      edges = [{1, 2}, {2, 3}, {3, 1}, {4, 3}]
      graph = Graph.build(tasks, edges, %{})

      assert Timeline.chain(graph, 1) == MapSet.new([1, 2, 3, 4])
      assert Timeline.chain(graph, 4) == MapSet.new([1, 2, 3, 4])
      assert [%{id: {:chain, 1}}] = timeline(tasks, edges).lanes
    end
  end

  # -- property tests --------------------------------------------------------------------

  describe "property: random task sets" do
    @describetag :property

    test "every task is placed xor in the side lane, exactly once" do
      for_each_case({11, 12, 13}, 300, fn c ->
        placed = Enum.map(points(c.tl), & &1.task.id)
        side = side_ids(c.tl)

        assert Enum.sort(placed ++ side) == Enum.sort(Enum.map(c.tasks, & &1.id))
        assert Enum.all?(placed, &(Graph.effective_deadline(c.graph, &1) != nil))
        assert Enum.all?(side, &(Graph.effective_deadline(c.graph, &1) == nil))
      end)
    end

    test "x is an integer in 0..10_000 and monotone in date" do
      for_each_case({21, 22, 23}, 300, fn c ->
        positioned =
          Enum.map(points(c.tl), &{&1.date, &1.x}) ++
            Enum.map(c.tl.milestones, &{&1.date, &1.x}) ++
            Enum.map(c.tl.ticks, &{&1.date, &1.x}) ++
            if(c.tl.range, do: [{c.tl.today.date, c.tl.today.x}], else: [])

        assert Enum.all?(positioned, fn {_date, x} -> is_integer(x) and x in 0..10_000 end)

        xs =
          positioned
          |> Enum.sort_by(fn {date, x} -> {Date.to_gregorian_days(date), x} end)
          |> Enum.map(&elem(&1, 1))

        assert xs == Enum.sort(xs)
      end)
    end

    test "within a row consecutive points are at least min_gap apart; row_count matches" do
      for_each_case({31, 32, 33}, 300, fn c ->
        for lane <- c.tl.lanes do
          rows = Enum.group_by(lane.points, & &1.row)
          assert map_size(rows) == lane.row_count
          assert Enum.sort(Map.keys(rows)) == Enum.to_list(0..(lane.row_count - 1))

          for {_row, row_points} <- rows do
            row_points
            |> Enum.map(& &1.x)
            |> Enum.chunk_every(2, 1, :discard)
            |> Enum.each(fn [a, b] -> assert b - a >= c.min_gap end)
          end
        end
      end)
    end

    test "arrows are exactly the placed-to-placed edges and never point backwards" do
      for_each_case({41, 42, 43}, 300, fn c ->
        x_of = Map.new(points(c.tl), &{&1.task.id, &1.x})

        expected =
          for {dependent, prerequisite} <- c.edges,
              Map.has_key?(x_of, dependent) and Map.has_key?(x_of, prerequisite),
              do: %{from: prerequisite, to: dependent}

        assert Enum.sort(c.tl.arrows) == Enum.sort(expected)
        assert Enum.all?(c.tl.arrows, &(x_of[&1.from] <= x_of[&1.to]))
      end)
    end

    test "lanes follow the undirected connected components (union-find oracle)" do
      for_each_case({51, 52, 53}, 300, fn c ->
        root = union_find(Enum.map(c.tasks, & &1.id), c.edges)
        size = Enum.frequencies(Map.values(root))

        for lane <- c.tl.lanes, point <- lane.points do
          r = root[point.task.id]

          expected =
            if size[r] == 1,
              do: :independent,
              else:
                {:chain,
                 root |> Enum.filter(&(elem(&1, 1) == r)) |> Enum.map(&elem(&1, 0)) |> Enum.min()}

          assert lane.id == expected
          assert point.lane == expected
        end
      end)
    end

    test "list holds every placed task, milestone and side-lane task exactly once, dated items in date order" do
      for_each_case({61, 62, 63}, 300, fn c ->
        keys = Enum.map(c.tl.list, &{&1.kind, item_id(&1)})

        expected =
          Enum.map(points(c.tl), &{:task, &1.task.id}) ++
            Enum.map(c.tl.milestones, &{&1.kind, &1.id}) ++
            Enum.map(c.tl.side_lane, &{:side, &1.task.id})

        assert Enum.sort(keys) == Enum.sort(expected)
        assert length(keys) == length(Enum.uniq(keys))

        {dated, undated} = Enum.split_while(c.tl.list, &(&1.date != nil))
        assert Enum.all?(undated, &(&1.kind == :side and &1.date == nil))
        days = Enum.map(dated, &Date.to_gregorian_days(&1.date))
        assert days == Enum.sort(days)
      end)
    end
  end

  # Union-find over the raw edge list, edges undirected: id => root (the component's
  # smallest id is not guaranteed; the caller picks the minimum itself).
  defp union_find(ids, edges) do
    parent = Map.new(ids, &{&1, &1})

    parent =
      Enum.reduce(edges, parent, fn {a, b}, parent ->
        ra = find(parent, a)
        rb = find(parent, b)
        if ra == rb, do: parent, else: Map.put(parent, ra, rb)
      end)

    Map.new(ids, &{&1, find(parent, &1)})
  end

  defp find(parent, id) do
    case Map.fetch!(parent, id) do
      ^id -> id
      next -> find(parent, next)
    end
  end

  # Runs `fun` over `n` random cases from a fixed seed; on failure, names the seed, the
  # iteration and the input.
  defp for_each_case(seed, n, fun) do
    :rand.seed(:exsss, seed)

    for iteration <- 1..n do
      c = random_case()

      try do
        fun.(c)
      rescue
        error in ExUnit.AssertionError ->
          input =
            inspect(
              %{
                today: c.today,
                min_gap: c.min_gap,
                tasks:
                  Enum.map(c.tasks, fn t ->
                    {t.id, t.status, t.deadline_kind, t.deadline_date, t.deadline_amount,
                     t.deadline_unit, t.deadline_direction, t.deadline_event_id}
                  end),
                edges: c.edges,
                events: Enum.map(c.events, &{&1.id, &1.date}),
                invoices:
                  Enum.map(c.invoices, &{&1.invoice.id, &1.invoice.due_date, &1.invoice.paid_on})
              },
              pretty: true,
              limit: :infinity
            )

          message =
            "#{error.message}\n\nseed #{inspect(seed)}, iteration #{iteration} of #{n}\ninput:\n#{input}"

          reraise %{error | message: message}, __STACKTRACE__
      end
    end
  end

  # 0–40 tasks with random statuses and deadlines (none, fixed, relative to one of 1–3
  # events, some undated), random acyclic edges (a task only waits on a lower id), 0–4
  # invoices (random due date / paid), a random today and a random min_gap.
  defp random_case do
    today = Date.add(~D[2026-01-01], :rand.uniform(1_500))

    events =
      for id <- 1..:rand.uniform(3), do: %Event{id: id, name: "Event #{id}", date: random_date()}

    tasks =
      for id <- 1..(:rand.uniform(41) - 1)//1 do
        deadline =
          case :rand.uniform(4) do
            1 ->
              nil

            2 ->
              random_date() || Date.add(today, :rand.uniform(30))

            _ ->
              {:rand.uniform(20) - 1, Enum.random([:days, :weeks]),
               Enum.random([:before, :after]), Enum.random(events).id}
          end

        task(id,
          title: Enum.random(["Alpha", "beta", "Gamma", "delta"]),
          status: Enum.random([:to_do, :in_progress, :done]),
          deadline: deadline
        )
      end

    edges =
      for a <- tasks, b <- tasks, b.id < a.id, :rand.uniform(12) == 1, do: {a.id, b.id}

    invoices =
      for id <- 1..(:rand.uniform(5) - 1)//1 do
        invoice(id,
          due: random_date(),
          paid_on: if(:rand.uniform(3) == 1, do: today),
          total: eur(:rand.uniform(5_000))
        )
      end

    min_gap = Enum.random([0, 1, 500, 1_200, 3_000])
    graph = Graph.build(tasks, edges, Map.new(events, &{&1.id, &1}))

    tl =
      Timeline.build(
        %{tasks: tasks, graph: graph, events: events, invoices: invoices, today: today},
        min_gap: min_gap
      )

    %{
      tasks: tasks,
      edges: edges,
      events: events,
      invoices: invoices,
      today: today,
      min_gap: min_gap,
      graph: graph,
      tl: tl
    }
  end

  defp random_date do
    if :rand.uniform(4) == 1, do: nil, else: Date.add(~D[2026-01-01], :rand.uniform(1_500))
  end
end
