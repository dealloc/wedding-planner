defmodule WeddingPlanner.Tasks.GraphTest do
  @moduledoc """
  `docs/modules/tasks-and-timeline.md` TSK-10 through TSK-15 — the pure task-dependency
  engine. Pure over bare `%Task{}`/`%Event{couple_attends: false}` structs and plain edge lists, no `Repo`, no
  `DataCase`. Normative examples T1, T2, T3 (`docs/07-normative-examples.md`) are tagged
  `@tag example: "T1"` etc. `DR-35` (`.claude/plans/roadmap.md`) settles direction, cycle
  path choice, self-dependency, done-dependent propagation, conflict `source`/`via`, and
  cycle tolerance.
  """

  use ExUnit.Case, async: true

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Tasks.Graph
  alias WeddingPlanner.Tasks.Task

  # -- helpers -------------------------------------------------------------------------

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

      {:relative, event_id, amount, unit, direction} ->
        %{
          base
          | deadline_kind: :relative,
            deadline_event_id: event_id,
            deadline_amount: amount,
            deadline_unit: unit,
            deadline_direction: direction
        }
    end
  end

  # -- T1: cycle path --------------------------------------------------------------------

  describe "cycle_path/3 — example T1" do
    @describetag example: "T1"

    test "A depends on B, B depends on C; proposing C depends on A names A → B → C → A" do
      edges = [{:a, :b}, {:b, :c}]

      assert Graph.cycle_path(edges, :c, :a) == [:a, :b, :c, :a]
    end

    test "a non-cycle edge returns nil" do
      # a already (transitively) depends on c; proposing a → c directly is redundant
      # but does not close a cycle (c has no outgoing edges).
      edges = [{:a, :b}, {:b, :c}]

      assert Graph.cycle_path(edges, :a, :c) == nil
    end

    test "a self-edge returns [id, id]" do
      assert Graph.cycle_path([], :a, :a) == [:a, :a]
      assert Graph.cycle_path([{:a, :b}], :a, :a) == [:a, :a]
    end

    test "with two paths of different length, the shortest is returned" do
      # a -> b -> d   (length 2)
      # a -> c -> x -> y -> d  (length 4)
      edges = [{:a, :b}, {:b, :d}, {:a, :c}, {:c, :x}, {:x, :y}, {:y, :d}]

      assert Graph.cycle_path(edges, :d, :a) == [:a, :b, :d, :a]
    end
  end

  # -- T2: effective deadline propagation -------------------------------------------------

  describe "effective_deadline/2 and effective_source/2 — example T2" do
    @describetag example: "T2"

    test "Confirm venue (no deadline) gets Book caterer's 1 March effective deadline" do
      confirm_venue = task(1, title: "Confirm venue")
      book_caterer = task(2, title: "Book caterer", deadline: ~D[2027-03-01])

      g = Graph.build([confirm_venue, book_caterer], [{2, 1}], %{})

      assert Graph.effective_deadline(g, 1) == ~D[2027-03-01]
      assert Graph.effective_source(g, 1) == 2
    end
  end

  # -- T3: conflicts -----------------------------------------------------------------------

  describe "conflicts/2 — example T3" do
    @describetag example: "T3"

    test "direct: own 15 March, dependent due 1 March — via == source" do
      x = task(1, deadline: ~D[2027-03-15])
      y = task(2, deadline: ~D[2027-03-01])

      g = Graph.build([x, y], [{2, 1}], %{})

      assert Graph.conflicts(g, 1) == [%{via: 2, source: 2, date: ~D[2027-03-01]}]
    end

    test "indirect: X own 15 March <- Y (no deadline) <- Z due 1 March — via: Y, source: Z" do
      x = task(1, deadline: ~D[2027-03-15])
      y = task(2)
      z = task(3, deadline: ~D[2027-03-01])

      g = Graph.build([x, y, z], [{2, 1}, {3, 2}], %{})

      assert Graph.effective_deadline(g, 2) == ~D[2027-03-01]
      assert Graph.effective_source(g, 2) == 3
      assert Graph.conflicts(g, 1) == [%{via: 2, source: 3, date: ~D[2027-03-01]}]
    end

    test "no own deadline means no conflicts regardless of dependents" do
      x = task(1)
      y = task(2, deadline: ~D[2027-03-01])

      g = Graph.build([x, y], [{2, 1}], %{})

      assert Graph.conflicts(g, 1) == []
    end

    test "a later dependent effective deadline is not a conflict" do
      x = task(1, deadline: ~D[2027-03-01])
      y = task(2, deadline: ~D[2027-03-15])

      g = Graph.build([x, y], [{2, 1}], %{})

      assert Graph.conflicts(g, 1) == []
    end
  end

  # -- TSK-03: unresolved relative deadlines propagate nothing ---------------------------

  describe "TSK-03 — unresolved relative deadlines" do
    test "an unresolved relative deadline propagates nothing; giving the event a date makes it propagate" do
      a = task(1, title: "Prerequisite")
      b = task(2, title: "Dependent", deadline: {:relative, 10, 2, :weeks, :before})

      undated_event = %Event{couple_attends: false, id: 10, name: "Reception", date: nil}
      g1 = Graph.build([a, b], [{2, 1}], %{10 => undated_event})

      assert Graph.own_deadline(g1, 2) == nil
      assert Graph.effective_deadline(g1, 1) == nil

      dated_event = %Event{couple_attends: false, id: 10, name: "Reception", date: ~D[2028-05-01]}
      g2 = Graph.build([a, b], [{2, 1}], %{10 => dated_event})

      assert Graph.own_deadline(g2, 2) == Date.add(~D[2028-05-01], -14)
      assert Graph.effective_deadline(g2, 1) == Date.add(~D[2028-05-01], -14)
      assert Graph.effective_source(g2, 1) == 2
    end
  end

  # -- Transitive propagation -------------------------------------------------------------

  describe "transitive propagation" do
    test "a 4-deep chain propagates the leaf's deadline to the root" do
      a = task(1)
      b = task(2)
      c = task(3)
      d = task(4)
      e = task(5, deadline: ~D[2027-06-01])

      # e depends on d depends on c depends on b depends on a
      edges = [{5, 4}, {4, 3}, {3, 2}, {2, 1}]
      g = Graph.build([a, b, c, d, e], edges, %{})

      assert Graph.effective_deadline(g, 1) == ~D[2027-06-01]
      assert Graph.effective_source(g, 1) == 5
    end

    test "a done dependent still propagates its deadline (TSK-13 does not exclude it)" do
      a = task(1)
      b = task(2, status: :done, deadline: ~D[2027-03-01])

      g = Graph.build([a, b], [{2, 1}], %{})

      assert Graph.effective_deadline(g, 1) == ~D[2027-03-01]
    end

    test "own deadline earlier than every dependent wins, with source nil" do
      a = task(1, deadline: ~D[2027-01-01])
      b = task(2, deadline: ~D[2027-03-01])

      g = Graph.build([a, b], [{2, 1}], %{})

      assert Graph.effective_deadline(g, 1) == ~D[2027-01-01]
      assert Graph.effective_source(g, 1) == nil
    end
  end

  # -- Blocked -----------------------------------------------------------------------------

  describe "blocked?/2 and unfinished_dependencies/2" do
    test "blocked while any direct dependency is not done, and lists only the unfinished ones" do
      a = task(1, status: :done)
      b = task(2, status: :to_do)
      c = task(3)

      g = Graph.build([a, b, c], [{3, 1}, {3, 2}], %{})

      assert Graph.blocked?(g, 3) == true
      assert Graph.unfinished_dependencies(g, 3) == [2]
    end

    test "not blocked when the only dependency is done" do
      a = task(1, status: :done)
      b = task(2)

      g = Graph.build([a, b], [{2, 1}], %{})

      assert Graph.blocked?(g, 2) == false
      assert Graph.unfinished_dependencies(g, 2) == []
    end

    test "not blocked with no dependencies at all" do
      a = task(1)
      g = Graph.build([a], [], %{})

      assert Graph.blocked?(g, 1) == false
    end
  end

  # -- Trees -------------------------------------------------------------------------------

  describe "waits_on_tree/2 and waited_on_by_tree/2" do
    test "both directions, transitive, over a simple chain" do
      a = task(1)
      b = task(2)
      c = task(3)

      # c depends on b depends on a
      g = Graph.build([a, b, c], [{3, 2}, {2, 1}], %{})

      assert Graph.waits_on_tree(g, 3) == [{2, [{1, []}]}]
      assert Graph.waited_on_by_tree(g, 1) == [{2, [{3, []}]}]
    end

    test "a diamond shows the shared node in full under each branch" do
      a = task(1)
      b = task(2)
      c = task(3)
      d = task(4)

      # a depends on b and c; b and c both depend on d
      g = Graph.build([a, b, c, d], [{1, 2}, {1, 3}, {2, 4}, {3, 4}], %{})

      assert Graph.waits_on_tree(g, 1) == [{2, [{4, []}]}, {3, [{4, []}]}]
    end

    test "a cycle is cut and marked instead of recursing forever" do
      a = task(1)
      b = task(2)
      c = task(3)

      # a -> b -> c -> a
      g = Graph.build([a, b, c], [{1, 2}, {2, 3}, {3, 1}], %{})

      assert Graph.waits_on_tree(g, 1) == [{2, [{3, [{1, :cut}]}]}]
    end

    test "a self-dependency is cut immediately" do
      a = task(1)
      g = Graph.build([a], [{1, 1}], %{})

      assert Graph.waits_on_tree(g, 1) == [{1, :cut}]
    end
  end

  # -- Cycle tolerance -----------------------------------------------------------------------

  describe "cycle tolerance" do
    @tag timeout: 2_000
    test "build/3 over a graph containing a cycle terminates and returns the min over the cycle" do
      a = task(1, deadline: ~D[2027-01-10])
      b = task(2, deadline: ~D[2027-01-05])
      c = task(3, deadline: ~D[2027-01-20])

      # a -> b -> c -> a (a self-sustaining cycle, plus each own deadline)
      g = Graph.build([a, b, c], [{1, 2}, {2, 3}, {3, 1}], %{})

      assert Graph.effective_deadline(g, 1) == ~D[2027-01-05]
      assert Graph.effective_deadline(g, 2) == ~D[2027-01-05]
      assert Graph.effective_deadline(g, 3) == ~D[2027-01-05]
      assert Graph.effective_source(g, 1) == 2
      assert Graph.effective_source(g, 2) == nil
      assert Graph.effective_source(g, 3) == 2
    end
  end

  # -- Date comparison (year boundary) -----------------------------------------------------

  describe "date comparison across a year boundary" do
    test "31/12/2027 sorts chronologically before 01/01/2028 in sort_key/2" do
      late_2027 = task(1, title: "Late 2027", deadline: ~D[2027-12-31])
      early_2028 = task(2, title: "Early 2028", deadline: ~D[2028-01-01])

      g = Graph.build([late_2027, early_2028], [], %{})

      sorted =
        [early_2028, late_2027]
        |> Enum.sort_by(&Graph.sort_key(g, &1))
        |> Enum.map(& &1.id)

      assert sorted == [1, 2]
    end

    test "effective_deadline picks the chronologically earlier date, not the smaller day-of-month" do
      root = task(1, title: "Root")
      # X's day-of-month (01) is smaller than Y's (31), but X is chronologically LATER.
      x = task(2, title: "X", deadline: ~D[2028-01-01])
      y = task(3, title: "Y", deadline: ~D[2027-12-31])

      g = Graph.build([root, x, y], [{2, 1}, {3, 1}], %{})

      assert Graph.effective_deadline(g, 1) == ~D[2027-12-31]
      assert Graph.effective_source(g, 1) == 3
    end
  end

  # -- Unknown ids in edges are ignored -----------------------------------------------------

  describe "build/3 ignores edges naming unknown ids" do
    test "an edge to/from a task not in the list is dropped" do
      a = task(1)

      g = Graph.build([a], [{1, 999}, {999, 1}], %{})

      assert Graph.waits_on(g, 1) == []
      assert Graph.waited_on_by(g, 1) == []
      assert Graph.blocked?(g, 1) == false
    end
  end

  # -- Property-style tests (no new dependency; fixed :rand seeds) -------------------------

  describe "property: random DAGs" do
    @describetag :property

    test "effective_deadline matches a brute-force reachable-dependents reference, 220 iterations" do
      :rand.seed(:exsss, {1, 2, 3})

      for _ <- 1..220 do
        {tasks, edges} = random_dag()
        own_deadlines = Map.new(tasks, &{&1.id, own_fixed_deadline(&1)})

        g = Graph.build(tasks, edges, %{})

        for %Task{id: id} <- tasks do
          expected = reference_effective_deadline(id, own_deadlines, edges)
          assert Graph.effective_deadline(g, id) == expected
        end
      end
    end

    test "cycle_path is non-nil exactly when a naive reachability check says the new edge closes a loop, 220 iterations" do
      :rand.seed(:exsss, {4, 5, 6})

      for _ <- 1..220 do
        {tasks, edges} = random_dag()
        ids = Enum.map(tasks, & &1.id)

        task_id = Enum.random(ids)
        depends_on_id = Enum.random(ids)

        would_cycle? =
          task_id == depends_on_id or
            MapSet.member?(forward_reachable_set(edges, depends_on_id), task_id)

        path = Graph.cycle_path(edges, task_id, depends_on_id)

        assert path != nil == would_cycle?

        if path do
          assert List.first(path) == depends_on_id
          assert List.last(path) == depends_on_id

          full_edges = MapSet.new(edges ++ [{task_id, depends_on_id}])

          assert path
                 |> Enum.chunk_every(2, 1, :discard)
                 |> Enum.all?(fn [a, b] -> MapSet.member?(full_edges, {a, b}) end)
        end
      end
    end
  end

  # -- property-test helpers ----------------------------------------------------------------

  # A random DAG of 1-30 tasks: ids are ranked by a random shuffle, and an edge {a, b}
  # ("a depends on b") is only ever generated when rank(a) > rank(b), so following edges
  # forward always strictly decreases rank — acyclic by construction.
  defp random_dag do
    n = :rand.uniform(30)
    ids = 1..n |> Enum.to_list() |> Enum.shuffle()
    rank = ids |> Enum.with_index() |> Map.new()

    possible_pairs =
      for a <- 1..n, b <- 1..n, a != b, Map.fetch!(rank, a) > Map.fetch!(rank, b), do: {a, b}

    edge_count =
      if possible_pairs == [], do: 0, else: :rand.uniform(min(length(possible_pairs), 3 * n))

    edges =
      possible_pairs
      |> Enum.shuffle()
      |> Enum.take(edge_count)

    base = ~D[2027-01-01]

    tasks =
      for id <- 1..n do
        status = Enum.at([:to_do, :in_progress, :done], :rand.uniform(3) - 1)

        case :rand.uniform(2) do
          1 ->
            %Task{id: id, title: "T#{id}", status: status, deadline_kind: :none}

          2 ->
            date = Date.add(base, :rand.uniform(400) - 200)

            %Task{
              id: id,
              title: "T#{id}",
              status: status,
              deadline_kind: :fixed,
              deadline_date: date
            }
        end
      end

    {tasks, edges}
  end

  defp own_fixed_deadline(%Task{deadline_kind: :fixed, deadline_date: date}), do: date
  defp own_fixed_deadline(%Task{deadline_kind: :none}), do: nil

  # All nodes reachable from `start` by following `edges` forward (a -> b for edge {a, b}).
  defp forward_reachable_set(edges, start) do
    adjacency = Enum.reduce(edges, %{}, fn {a, b}, acc -> Map.update(acc, a, [b], &[b | &1]) end)
    do_forward_reachable([start], MapSet.new([start]), adjacency)
  end

  defp do_forward_reachable([], visited, _adjacency), do: visited

  defp do_forward_reachable([node | rest], visited, adjacency) do
    neighbours = Map.get(adjacency, node, [])

    {new_nodes, visited} =
      Enum.reduce(neighbours, {[], visited}, fn n, {acc, vis} ->
        if MapSet.member?(vis, n) do
          {acc, vis}
        else
          {[n | acc], MapSet.put(vis, n)}
        end
      end)

    do_forward_reachable(new_nodes ++ rest, visited, adjacency)
  end

  # Brute-force TSK-13: min own deadline over `id` and every task that can reach `id`
  # along depends-on edges (its full set of transitive dependents), independent of
  # Graph's own internal reachability sweep.
  defp reference_effective_deadline(id, own_deadlines, edges) do
    transitive_dependents =
      own_deadlines
      |> Map.keys()
      |> Enum.filter(fn x -> x != id and MapSet.member?(forward_reachable_set(edges, x), id) end)

    candidates =
      [id | transitive_dependents]
      |> Enum.map(&Map.get(own_deadlines, &1))
      |> Enum.reject(&is_nil/1)

    case candidates do
      [] -> nil
      dates -> Enum.min_by(dates, &Date.to_erl/1)
    end
  end
end
