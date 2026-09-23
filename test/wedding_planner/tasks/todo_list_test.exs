defmodule WeddingPlanner.Tasks.TodoListTest do
  @moduledoc """
  `docs/modules/tasks-and-timeline.md` TSK-20, TSK-23; `.claude/plans/roadmap.md`
  DR-44 — the pure todo-list sectioning/filtering engine. Pure over bare `%Task{}`
  structs and a `Graph.t()` built the same way `graph_test.exs` builds one; no `Repo`,
  no `DataCase`, no LiveView.
  """

  use ExUnit.Case, async: true

  alias WeddingPlanner.Tasks.Graph
  alias WeddingPlanner.Tasks.Task
  alias WeddingPlanner.Tasks.TodoList

  # -- helpers -------------------------------------------------------------------------

  defp task(id, opts \\ []) do
    base = %Task{
      id: id,
      title: Keyword.get(opts, :title, "Task #{id}"),
      status: Keyword.get(opts, :status, :to_do),
      deadline_kind: :none,
      owner_id: Keyword.get(opts, :owner_id),
      owner_shared: Keyword.get(opts, :owner_shared, false)
    }

    case Keyword.get(opts, :deadline) do
      nil -> base
      %Date{} = date -> %{base | deadline_kind: :fixed, deadline_date: date}
    end
  end

  defp graph(tasks, edges \\ []), do: Graph.build(tasks, edges, %{})

  # -- section_of/3 — boundaries (TSK-23, DR-44) ----------------------------------------

  describe "section_of/3 — boundaries" do
    test "yesterday is overdue" do
      today = ~D[2027-06-15]
      t = task(1, deadline: Date.add(today, -1))
      assert TodoList.section_of(graph([t]), t, today) == :overdue
    end

    test "today itself is this week, not overdue" do
      today = ~D[2027-06-15]
      t = task(1, deadline: today)
      assert TodoList.section_of(graph([t]), t, today) == :this_week
    end

    test "today + 6 is the last day still counted as this week" do
      today = ~D[2027-06-15]
      t = task(1, deadline: Date.add(today, 6))
      assert TodoList.section_of(graph([t]), t, today) == :this_week
    end

    test "today + 7 is later, not this week" do
      today = ~D[2027-06-15]
      t = task(1, deadline: Date.add(today, 7))
      assert TodoList.section_of(graph([t]), t, today) == :later
    end

    test "no own deadline and no dependents is no_deadline" do
      today = ~D[2027-06-15]
      t = task(1)
      assert TodoList.section_of(graph([t]), t, today) == :no_deadline
    end

    test "an unresolved relative deadline is no_deadline (TSK-03)" do
      today = ~D[2027-06-15]

      t = %Task{
        id: 1,
        title: "Unresolved",
        status: :to_do,
        deadline_kind: :relative,
        deadline_amount: 2,
        deadline_unit: :weeks,
        deadline_direction: :before,
        deadline_event_id: 99
      }

      g = Graph.build([t], [], %{99 => %WeddingPlanner.Events.Event{id: 99, date: nil}})
      assert TodoList.section_of(g, t, today) == :no_deadline
    end

    test "effective deadline pulled earlier by a dependent moves the section" do
      today = ~D[2027-06-15]
      # root has no own deadline; a dependent's own deadline is tomorrow, so root's
      # effective deadline is tomorrow (still this week) rather than no_deadline.
      root = task(1, title: "Root")
      dependent = task(2, title: "Dependent", deadline: Date.add(today, 1))

      g = graph([root, dependent], [{2, 1}])

      assert Graph.effective_deadline(g, 1) == Date.add(today, 1)
      assert TodoList.section_of(g, root, today) == :this_week
    end

    test "a cross-month boundary: today 28/02, deadline 01/03 is this week, not overdue" do
      today = ~D[2027-02-28]
      t = task(1, deadline: ~D[2027-03-01])
      assert TodoList.section_of(graph([t]), t, today) == :this_week
    end

    test "a cross-year boundary: today 30/12, deadline 02/01 next year is this week" do
      today = ~D[2027-12-30]
      t = task(1, deadline: ~D[2028-01-02])
      assert TodoList.section_of(graph([t]), t, today) == :this_week
    end

    test "a cross-year boundary the other way: deadline last year is overdue, not sorted by day-of-month" do
      # day-of-month 31 > 02, but chronologically 2026-12-31 is before 2027-01-02: if the
      # implementation ever compared with `<` instead of Date.compare/2, this would
      # silently read as "later" instead of overdue.
      today = ~D[2027-01-02]
      t = task(1, deadline: ~D[2026-12-31])
      assert TodoList.section_of(graph([t]), t, today) == :overdue
    end
  end

  # -- build/4 — sectioning ---------------------------------------------------------------

  describe "build/4 — sectioning" do
    test "sections appear in fixed order, empty sections omitted, labels are exact" do
      today = ~D[2027-06-15]

      overdue = task(1, title: "Overdue task", deadline: Date.add(today, -1))
      this_week = task(2, title: "This week task", deadline: today)
      later = task(3, title: "Later task", deadline: Date.add(today, 30))

      tasks = [overdue, this_week, later]
      g = graph(tasks)

      result = TodoList.build(tasks, g, TodoList.default_filters(), today)

      assert Enum.map(result.sections, & &1.id) == [:overdue, :this_week, :later]
      assert Enum.map(result.sections, & &1.label) == ["Overdue", "This week", "Later"]
      assert result.shown == 3
      assert result.total_not_done == 3
      assert result.done == []
    end

    test "no_deadline section is present only when it has tasks, and is last" do
      today = ~D[2027-06-15]

      this_week = task(1, deadline: today)
      no_deadline = task(2)

      tasks = [this_week, no_deadline]
      g = graph(tasks)

      result = TodoList.build(tasks, g, TodoList.default_filters(), today)

      assert Enum.map(result.sections, & &1.id) == [:this_week, :no_deadline]
    end

    test "within a section, task order is preserved from the input list" do
      today = ~D[2027-06-15]

      # Both fall in :later; the input order (b then a) must be preserved, not re-sorted.
      b = task(2, title: "B", deadline: Date.add(today, 20))
      a = task(1, title: "A", deadline: Date.add(today, 10))

      tasks = [b, a]
      g = graph(tasks)

      result = TodoList.build(tasks, g, TodoList.default_filters(), today)
      [section] = result.sections

      assert Enum.map(section.tasks, & &1.id) == [2, 1]
    end

    test "done tasks are excluded from sections and returned unfiltered, always" do
      today = ~D[2027-06-15]

      done = task(1, status: :done, deadline: Date.add(today, -5))
      not_done = task(2, deadline: today)

      tasks = [done, not_done]
      g = graph(tasks)

      # Even with an owner filter that would exclude the not-done task, `done` is
      # returned in full and unfiltered.
      filters = TodoList.put_owner(TodoList.default_filters(), {:user, 999})
      result = TodoList.build(tasks, g, filters, today)

      assert result.done == [done]
      assert result.sections == []
      assert result.shown == 0
      assert result.total_not_done == 1
    end
  end

  # -- filters: actionable / blocked (TSK-20, TSK-11) -------------------------------------

  describe "filters — actionable / blocked" do
    test "actionable shows only not-blocked tasks" do
      today = ~D[2027-06-15]

      prereq = task(1, status: :to_do)
      blocked = task(2, status: :to_do)
      actionable = task(3, status: :to_do)

      tasks = [prereq, blocked, actionable]
      g = graph(tasks, [{2, 1}])

      filters = TodoList.toggle_chip(TodoList.default_filters(), :actionable)
      result = TodoList.build(tasks, g, filters, today)

      shown_ids = result.sections |> Enum.flat_map(& &1.tasks) |> Enum.map(& &1.id)
      assert Enum.sort(shown_ids) == [1, 3]
    end

    test "blocked shows only blocked tasks" do
      today = ~D[2027-06-15]

      prereq = task(1, status: :to_do)
      blocked = task(2, status: :to_do)
      actionable = task(3, status: :to_do)

      tasks = [prereq, blocked, actionable]
      g = graph(tasks, [{2, 1}])

      filters = TodoList.toggle_chip(TodoList.default_filters(), :blocked)
      result = TodoList.build(tasks, g, filters, today)

      shown_ids = result.sections |> Enum.flat_map(& &1.tasks) |> Enum.map(& &1.id)
      assert shown_ids == [2]
    end

    test "actionable and blocked are mutually exclusive: enabling one disables the other" do
      state = TodoList.default_filters()

      state = TodoList.toggle_chip(state, :actionable)
      assert state.chips == MapSet.new([:actionable])

      state = TodoList.toggle_chip(state, :blocked)
      assert state.chips == MapSet.new([:blocked])

      # toggling the same chip again turns it off
      state = TodoList.toggle_chip(state, :blocked)
      assert state.chips == MapSet.new([])
    end
  end

  # -- filters: overdue / this_week (TSK-20, TSK-23) ---------------------------------------

  describe "filters — overdue / this_week" do
    test "overdue chip shows only overdue tasks" do
      today = ~D[2027-06-15]

      overdue = task(1, deadline: Date.add(today, -1))
      this_week = task(2, deadline: today)
      later = task(3, deadline: Date.add(today, 30))

      tasks = [overdue, this_week, later]
      g = graph(tasks)

      filters = TodoList.toggle_chip(TodoList.default_filters(), :overdue)
      result = TodoList.build(tasks, g, filters, today)

      shown_ids = result.sections |> Enum.flat_map(& &1.tasks) |> Enum.map(& &1.id)
      assert shown_ids == [1]
    end

    test "this_week chip shows only this-week tasks" do
      today = ~D[2027-06-15]

      overdue = task(1, deadline: Date.add(today, -1))
      this_week = task(2, deadline: today)
      later = task(3, deadline: Date.add(today, 30))

      tasks = [overdue, this_week, later]
      g = graph(tasks)

      filters = TodoList.toggle_chip(TodoList.default_filters(), :this_week)
      result = TodoList.build(tasks, g, filters, today)

      shown_ids = result.sections |> Enum.flat_map(& &1.tasks) |> Enum.map(& &1.id)
      assert shown_ids == [2]
    end

    test "overdue and this_week are mutually exclusive" do
      state = TodoList.default_filters()

      state = TodoList.toggle_chip(state, :overdue)
      assert state.chips == MapSet.new([:overdue])

      state = TodoList.toggle_chip(state, :this_week)
      assert state.chips == MapSet.new([:this_week])
    end

    test "chips from different pairs combine (AND)" do
      today = ~D[2027-06-15]

      prereq = task(1, status: :to_do, deadline: Date.add(today, -1))
      blocked_overdue = task(2, status: :to_do, deadline: Date.add(today, -1))
      actionable_overdue = task(3, status: :to_do, deadline: Date.add(today, -1))
      actionable_this_week = task(4, status: :to_do, deadline: today)

      tasks = [prereq, blocked_overdue, actionable_overdue, actionable_this_week]
      g = graph(tasks, [{2, 1}])

      state =
        TodoList.default_filters()
        |> TodoList.toggle_chip(:actionable)
        |> TodoList.toggle_chip(:overdue)

      result = TodoList.build(tasks, g, state, today)
      shown_ids = result.sections |> Enum.flat_map(& &1.tasks) |> Enum.map(& &1.id)

      # 1 (prereq) is actionable + overdue; 3 is actionable + overdue; 2 is blocked (excluded);
      # 4 is this_week not overdue (excluded).
      assert Enum.sort(shown_ids) == [1, 3]
    end
  end

  # -- filters: owner (TSK-01, DR-44) -------------------------------------------------------

  describe "filters — owner" do
    test "everyone (default) shows every owner" do
      today = ~D[2027-06-15]

      mine = task(1, owner_id: 7)
      shared = task(2, owner_shared: true)
      unassigned = task(3)
      other = task(4, owner_id: 8)

      tasks = [mine, shared, unassigned, other]
      g = graph(tasks)

      result = TodoList.build(tasks, g, TodoList.default_filters(), today)
      shown_ids = result.sections |> Enum.flat_map(& &1.tasks) |> Enum.map(& &1.id)

      assert Enum.sort(shown_ids) == [1, 2, 3, 4]
    end

    test "{:user, id} shows that user's own tasks plus shared tasks (TSK-01: shared means every user)" do
      today = ~D[2027-06-15]

      mine = task(1, owner_id: 7)
      shared = task(2, owner_shared: true)
      unassigned = task(3)
      other = task(4, owner_id: 8)

      tasks = [mine, shared, unassigned, other]
      g = graph(tasks)

      filters = TodoList.put_owner(TodoList.default_filters(), {:user, 7})
      result = TodoList.build(tasks, g, filters, today)
      shown_ids = result.sections |> Enum.flat_map(& &1.tasks) |> Enum.map(& &1.id)

      assert Enum.sort(shown_ids) == [1, 2]
    end

    test "unassigned shows only tasks with no owner and not shared" do
      today = ~D[2027-06-15]

      mine = task(1, owner_id: 7)
      shared = task(2, owner_shared: true)
      unassigned = task(3)

      tasks = [mine, shared, unassigned]
      g = graph(tasks)

      filters = TodoList.put_owner(TodoList.default_filters(), :unassigned)
      result = TodoList.build(tasks, g, filters, today)
      shown_ids = result.sections |> Enum.flat_map(& &1.tasks) |> Enum.map(& &1.id)

      assert shown_ids == [3]
    end
  end

  # -- params round-trip (DR-44) -----------------------------------------------------------

  describe "from_params/1 and to_params/1" do
    test "defaults produce an empty params map" do
      assert TodoList.to_params(TodoList.default_filters()) == %{}
    end

    test "round-trips chips and a user owner" do
      state =
        TodoList.default_filters()
        |> TodoList.toggle_chip(:actionable)
        |> TodoList.toggle_chip(:overdue)
        |> TodoList.put_owner({:user, 42})

      params = TodoList.to_params(state)
      assert params == %{"filter" => "actionable,overdue", "owner" => "42"}
      assert TodoList.from_params(params) == state
    end

    test "round-trips the blocked/this_week pair" do
      state =
        TodoList.default_filters()
        |> TodoList.toggle_chip(:blocked)
        |> TodoList.toggle_chip(:this_week)
        |> TodoList.put_owner(:unassigned)

      params = TodoList.to_params(state)
      assert TodoList.from_params(params) == state
    end

    test "unknown chip tokens are dropped, not raised on" do
      parsed = TodoList.from_params(%{"filter" => "actionable,bogus,,overdue"})
      assert parsed.chips == MapSet.new([:actionable, :overdue])
    end

    test "a malformed owner value falls back to everyone" do
      assert TodoList.from_params(%{"owner" => "not-a-user-id"}) == TodoList.default_filters()
      assert TodoList.from_params(%{"owner" => ""}) == TodoList.default_filters()
    end

    test "missing params fall back to defaults entirely" do
      assert TodoList.from_params(%{}) == TodoList.default_filters()
    end

    test "the explicit 'everyone' owner string round-trips to the default (also omitted on the way out)" do
      assert TodoList.from_params(%{"owner" => "everyone"}) == TodoList.default_filters()
    end
  end

  # -- property-style tests (no new dependency; fixed :rand seeds) -------------------------

  describe "property: random task sets" do
    @describetag :property

    test "sections partition exactly the not-done tasks, and shown sums the sections, 150 iterations" do
      :rand.seed(:exsss, {10, 20, 30})

      for _ <- 1..150 do
        {tasks, edges, today} = random_task_set()
        g = graph(tasks, edges)

        result = TodoList.build(tasks, g, TodoList.default_filters(), today)

        not_done_ids =
          tasks |> Enum.reject(&(&1.status == :done)) |> Enum.map(& &1.id) |> Enum.sort()

        sectioned_ids =
          result.sections |> Enum.flat_map(& &1.tasks) |> Enum.map(& &1.id) |> Enum.sort()

        assert sectioned_ids == not_done_ids
        assert result.shown == length(sectioned_ids)
        assert result.total_not_done == length(not_done_ids)

        assert Enum.map(result.done, & &1.id) |> Enum.sort() ==
                 tasks |> Enum.filter(&(&1.status == :done)) |> Enum.map(& &1.id) |> Enum.sort()
      end
    end

    test "no filters shows every not-done task, 150 iterations" do
      :rand.seed(:exsss, {11, 21, 31})

      for _ <- 1..150 do
        {tasks, edges, today} = random_task_set()
        g = graph(tasks, edges)

        result = TodoList.build(tasks, g, TodoList.default_filters(), today)

        shown_ids =
          result.sections |> Enum.flat_map(& &1.tasks) |> Enum.map(& &1.id) |> Enum.sort()

        not_done_ids =
          tasks |> Enum.reject(&(&1.status == :done)) |> Enum.map(& &1.id) |> Enum.sort()

        assert shown_ids == not_done_ids
      end
    end

    test "actionable and blocked results are disjoint and together equal the unfiltered set, 150 iterations" do
      :rand.seed(:exsss, {12, 22, 32})

      for _ <- 1..150 do
        {tasks, edges, today} = random_task_set()
        g = graph(tasks, edges)

        actionable_filters = TodoList.toggle_chip(TodoList.default_filters(), :actionable)
        blocked_filters = TodoList.toggle_chip(TodoList.default_filters(), :blocked)

        actionable_ids =
          TodoList.build(tasks, g, actionable_filters, today).sections
          |> Enum.flat_map(& &1.tasks)
          |> Enum.map(& &1.id)
          |> MapSet.new()

        blocked_ids =
          TodoList.build(tasks, g, blocked_filters, today).sections
          |> Enum.flat_map(& &1.tasks)
          |> Enum.map(& &1.id)
          |> MapSet.new()

        unfiltered_ids =
          TodoList.build(tasks, g, TodoList.default_filters(), today).sections
          |> Enum.flat_map(& &1.tasks)
          |> Enum.map(& &1.id)
          |> MapSet.new()

        assert MapSet.disjoint?(actionable_ids, blocked_ids)
        assert MapSet.union(actionable_ids, blocked_ids) == unfiltered_ids
      end
    end

    test "from_params(to_params(state)) round-trips for every reachable filter state, 150 iterations" do
      :rand.seed(:exsss, {13, 23, 33})

      owners_pool = [:everyone, :unassigned, {:user, 1}, {:user, 2}, {:user, 42}]

      for _ <- 1..150 do
        chip_toggles =
          for _ <- 1..Enum.random(0..4)//1,
              do: Enum.random([:actionable, :blocked, :overdue, :this_week])

        state =
          Enum.reduce(chip_toggles, TodoList.default_filters(), &TodoList.toggle_chip(&2, &1))
          |> TodoList.put_owner(Enum.random(owners_pool))

        params = TodoList.to_params(state)
        assert TodoList.from_params(params) == state
      end
    end
  end

  # -- property-test helpers ----------------------------------------------------------------

  defp random_task_set do
    n = :rand.uniform(15)
    ids = 1..n |> Enum.to_list()
    today = Date.add(~D[2027-01-01], :rand.uniform(700))

    possible_pairs = for a <- ids, b <- ids, a != b, a > b, do: {a, b}

    edge_count =
      if possible_pairs == [], do: 0, else: :rand.uniform(min(length(possible_pairs), 2 * n))

    edges = possible_pairs |> Enum.shuffle() |> Enum.take(edge_count)

    tasks =
      for id <- ids do
        status = Enum.random([:to_do, :in_progress, :done])
        owner = random_owner()

        deadline =
          case :rand.uniform(3) do
            1 -> nil
            2 -> Date.add(today, :rand.uniform(60) - 30)
            3 -> Date.add(today, :rand.uniform(6))
          end

        task(id,
          status: status,
          deadline: deadline,
          owner_id: elem(owner, 0),
          owner_shared: elem(owner, 1)
        )
      end

    {tasks, edges, today}
  end

  defp random_owner do
    case :rand.uniform(3) do
      1 -> {nil, false}
      2 -> {nil, true}
      3 -> {Enum.random([1, 2]), false}
    end
  end
end
