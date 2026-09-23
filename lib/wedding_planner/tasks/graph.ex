defmodule WeddingPlanner.Tasks.Graph do
  @moduledoc """
  Pure task-dependency engine (`docs/modules/tasks-and-timeline.md` TSK-10 through
  TSK-15). Database-free and web-free by construction — everything here is a function of
  a plain list of `%WeddingPlanner.Tasks.Task{}` structs and a plain list of dependency
  edges, so it can be property-tested without a database and reused by task 42
  (persistence), task 43 (the `/tasks` screen), and later slices T3/T4.

  ## Direction (`DR-35`)

  An edge `{task_id, depends_on_id}` means **`task_id` waits on `depends_on_id`** — the
  latter is the prerequisite. In rejection messages "→" reads "depends on": `A → B` is
  "A depends on B". `waits_on/2` follows an edge forward (from a task to what it needs
  done first); `waited_on_by/2` follows it backward (from a task to what needs *it* done
  first).

  ## Cycle path (`TSK-10`, `DR-35`, example T1)

  For a proposed edge `{t, p}` ("t would depend on p"), a cycle exists iff `t` is
  reachable from `p` along *existing* depends-on edges, or `t == p` (a self-dependency).
  `cycle_path/3` returns the path starting at `p`, following the shortest existing
  depends-on path to `t` (BFS, neighbours visited in ascending id order so the result is
  deterministic when more than one shortest path exists), then appending `p` again:
  example T1 (`A→B`, `B→C`, proposing `C→A`) gives `[A, B, C, A]`. A self-edge
  (`t == p`) gives `[p, p]`. It works on the raw edge list (not a built `t()`) so task 42
  can call it inside the same transaction that would insert the edge, without paying for
  a full graph build.

  ## Effective deadline (`TSK-13`, `DR-35`, example T2)

  A task's effective deadline is the earliest of its own resolved deadline
  (`WeddingPlanner.Tasks.Deadline.resolve/2` — `:none` and `{:unresolved, _}` both count
  as no deadline per `TSK-03`) and the effective deadlines of *every* task that depends
  on it, directly or transitively — **done dependents included**; TSK-13 does not
  exclude them. Because that is a fixed-point definition, it collapses to: the minimum
  own-resolved-deadline over `{id} ∪ every task that can reach id along depends-on
  edges}` (its full set of transitive dependents). `effective_source/2` records which
  task's own deadline is the one that binds — `nil` when it is the task's own deadline
  or there is no deadline at all; ties prefer the task's own deadline, then the lowest
  id (`DR-35`).

  Sizes here are tens to low hundreds of tasks, so `build/3` computes this per task as a
  plain reachability sweep over the "who depends on me" adjacency (BFS with a
  *per-sweep* visited set) rather than a single memoised depth-first pass reusing
  children's results. A cache-reusing DFS is the more obvious reading of "memoised DFS"
  but is only correct on an acyclic graph without extra work (Tarjan SCC condensation)
  to fold cycles into one value first; a plain per-node reachability sweep is exactly as
  correct on cyclic input as on acyclic input, for a documented, trivial cost at this
  scale (see "Cycle tolerance" below). Either way, `build/3` does this work once and
  every query after it is a map lookup.

  ## Conflicts (`TSK-14`, `DR-35`, example T3)

  Only checked when the task has an own *resolved* deadline. For each **direct**
  dependent whose effective deadline is strictly earlier, `conflicts/2` returns one
  `%{via: dependent_id, source: id, date: Date.t()}` — `source` is the id whose own
  deadline actually binds (`effective_source(g, dependent_id) || dependent_id`, since
  `effective_source/2` is `nil` exactly when the dependent's own deadline is the
  binding one). `via == source` in the direct case (T3's first example); when the
  binding deadline is further up the chain, `via != source` (T3's second example) and
  task 43 words it "… waits on it (through 'via') …".

  ## Blocked (`TSK-11`, `TSK-12`)

  A task is blocked while at least one *direct* dependency is not `:done`.
  `unfinished_dependencies/2` names them, ascending by id, for the TSK-12 warning.
  `blocked?/2` and `conflicts/2` are computed for every task regardless of status;
  whether they are *shown* only for not-done tasks is task 43's concern, not this
  module's.

  ## Trees (`TSK-15`)

  `waits_on_tree/2` and `waited_on_by_tree/2` return a forest `[{id, children}]` of a
  task's direct dependencies/dependents, expanded recursively. A diamond (two branches
  converging on the same prerequisite) shows that shared node in full under *each*
  branch — it is not the same node recurring on its own path, so there is nothing to
  cut. A real cycle — a node reappearing among its own ancestors on the current branch —
  is cut: its `children` is the atom `:cut` instead of a list, so the UI can render
  "(shown above)" instead of recursing forever.

  ## Cycle tolerance (`DR-35`)

  The input may already contain a cycle — two people adding edges in separate
  transactions could sneak one in before task 42's own check would catch it on the next
  write. Every traversal here (`reachable/2`'s BFS, `build_tree/3`'s DFS) carries an
  explicit visited set, so nothing loops or blows the stack on cyclic input; on a
  cycle, every node in it (and everything reachable from it) shares one effective
  deadline: the minimum own deadline over that whole reachable set, exactly as the
  non-cyclic definition already implies.

  ## Dates

  Every comparison here goes through `Date.compare/2` or `Date.to_erl/1` (for use as a
  sort/tiebreak key), **never** `<`, `<=`, `Enum.min/1` or `Enum.sort/1` directly on
  `%Date{}` structs — those compare the struct's fields in declaration order
  (`:calendar`, `:day`, `:month`, `:year`), i.e. by *day of month* first, which silently
  mis-orders across month/year boundaries (31 December would sort after 1 January). See
  the identical comment on `WeddingPlanner.Tasks.sort_key/2`, which this module's
  `sort_key/2` mirrors (effective deadline in place of own deadline).
  """

  alias WeddingPlanner.Tasks.Deadline
  alias WeddingPlanner.Tasks.Task

  @type id :: term()
  @type edge :: {id(), id()}
  @type tree_node :: {id(), [tree_node()] | :cut}
  @type conflict :: %{via: id(), source: id(), date: Date.t()}

  @opaque t :: %__MODULE__{
            tasks_by_id: %{optional(id()) => Task.t()},
            deps: %{optional(id()) => [id()]},
            dependents: %{optional(id()) => [id()]},
            own_deadlines: %{optional(id()) => Date.t() | nil},
            effective_deadlines: %{optional(id()) => Date.t() | nil},
            effective_sources: %{optional(id()) => id() | nil}
          }

  defstruct [
    :tasks_by_id,
    :deps,
    :dependents,
    :own_deadlines,
    :effective_deadlines,
    :effective_sources
  ]

  @doc """
  Builds the graph. `tasks` are `%Task{}` structs; `edges` a list of
  `{task_id, depends_on_id}` (`task_id` waits on `depends_on_id`) — edges naming an id
  not present in `tasks` are ignored. `events_by_id` is passed straight through to
  `WeddingPlanner.Tasks.Deadline.resolve/2` for each task's own deadline.

  Precomputes every task's own deadline, effective deadline and effective source, so
  `own_deadline/2`, `effective_deadline/2` and `effective_source/2` are plain map
  lookups afterwards.
  """
  @spec build([Task.t()], [edge()], Deadline.events_by_id()) :: t()
  def build(tasks, edges, events_by_id) do
    tasks_by_id = Map.new(tasks, &{&1.id, &1})
    known_ids = MapSet.new(Map.keys(tasks_by_id))

    filtered_edges =
      Enum.filter(edges, fn {task_id, depends_on_id} ->
        MapSet.member?(known_ids, task_id) and MapSet.member?(known_ids, depends_on_id)
      end)

    deps = adjacency(filtered_edges, known_ids, fn {t, _d} -> t end, fn {_t, d} -> d end)
    dependents = adjacency(filtered_edges, known_ids, fn {_t, d} -> d end, fn {t, _d} -> t end)

    own_deadlines =
      Map.new(tasks_by_id, fn {id, task} -> {id, resolve_own(task, events_by_id)} end)

    {effective_deadlines, effective_sources} =
      Enum.reduce(known_ids, {%{}, %{}}, fn id, {eff, src} ->
        {date, source} = effective_for(id, dependents, own_deadlines)
        {Map.put(eff, id, date), Map.put(src, id, source)}
      end)

    %__MODULE__{
      tasks_by_id: tasks_by_id,
      deps: deps,
      dependents: dependents,
      own_deadlines: own_deadlines,
      effective_deadlines: effective_deadlines,
      effective_sources: effective_sources
    }
  end

  @doc "The task's own resolved deadline (`TSK-02`/`TSK-03`), `nil` if none or unresolved."
  @spec own_deadline(t(), id()) :: Date.t() | nil
  def own_deadline(%__MODULE__{} = g, id), do: Map.get(g.own_deadlines, id)

  @doc "The task's effective deadline (`TSK-13`), `nil` if nothing applies."
  @spec effective_deadline(t(), id()) :: Date.t() | nil
  def effective_deadline(%__MODULE__{} = g, id), do: Map.get(g.effective_deadlines, id)

  @doc """
  The id of the task whose own deadline sets `id`'s effective deadline — `nil` when it
  is `id`'s own deadline (or there is no effective deadline at all).
  """
  @spec effective_source(t(), id()) :: id() | nil
  def effective_source(%__MODULE__{} = g, id), do: Map.get(g.effective_sources, id)

  @doc "`true` while at least one direct dependency of `id` is not `:done` (`TSK-11`)."
  @spec blocked?(t(), id()) :: boolean()
  def blocked?(%__MODULE__{} = g, id), do: unfinished_dependencies(g, id) != []

  @doc "Direct dependencies of `id` that are not `:done`, ascending by id (`TSK-12`)."
  @spec unfinished_dependencies(t(), id()) :: [id()]
  def unfinished_dependencies(%__MODULE__{} = g, id) do
    g.deps
    |> Map.get(id, [])
    |> Enum.filter(fn dep_id ->
      case Map.get(g.tasks_by_id, dep_id) do
        %Task{status: :done} -> false
        _not_done -> true
      end
    end)
  end

  @doc "Direct dependencies of `id` (what it waits on), ascending by id."
  @spec waits_on(t(), id()) :: [id()]
  def waits_on(%__MODULE__{} = g, id), do: Map.get(g.deps, id, [])

  @doc "Direct dependents of `id` (what waits on it), ascending by id."
  @spec waited_on_by(t(), id()) :: [id()]
  def waited_on_by(%__MODULE__{} = g, id), do: Map.get(g.dependents, id, [])

  @doc """
  `id`'s dependency deadline conflicts (`TSK-14`) — one per direct dependent whose
  effective deadline is strictly earlier than `id`'s own deadline. `[]` when `id` has no
  own resolved deadline.
  """
  @spec conflicts(t(), id()) :: [conflict()]
  def conflicts(%__MODULE__{} = g, id) do
    case own_deadline(g, id) do
      nil ->
        []

      own_date ->
        g
        |> waited_on_by(id)
        |> Enum.reduce([], fn dependent_id, acc ->
          case effective_deadline(g, dependent_id) do
            nil ->
              acc

            eff_date ->
              if Date.compare(eff_date, own_date) == :lt do
                source = effective_source(g, dependent_id) || dependent_id
                [%{via: dependent_id, source: source, date: eff_date} | acc]
              else
                acc
              end
          end
        end)
        |> Enum.reverse()
    end
  end

  @doc "Forest of `id`'s dependencies, expanded transitively (`TSK-15`). See moduledoc."
  @spec waits_on_tree(t(), id()) :: [tree_node()]
  def waits_on_tree(%__MODULE__{} = g, id), do: build_tree(g.deps, id, MapSet.new([id]))

  @doc "Forest of `id`'s dependents, expanded transitively (`TSK-15`). See moduledoc."
  @spec waited_on_by_tree(t(), id()) :: [tree_node()]
  def waited_on_by_tree(%__MODULE__{} = g, id), do: build_tree(g.dependents, id, MapSet.new([id]))

  @doc """
  For a proposed edge `{task_id, depends_on_id}`, the cycle it would close, as a path
  starting and ending at `depends_on_id`, or `nil` if it would not close one. Works on
  the raw edge list — see moduledoc. `edges` uses the same `{task_id, depends_on_id}`
  convention as `build/3`.
  """
  @spec cycle_path([edge()], id(), id()) :: [id()] | nil
  def cycle_path(_edges, task_id, task_id), do: [task_id, task_id]

  def cycle_path(edges, task_id, depends_on_id) do
    adjacency =
      Enum.reduce(edges, %{}, fn {t, d}, acc -> Map.update(acc, t, [d], &[d | &1]) end)

    case bfs_shortest_path(adjacency, depends_on_id, task_id) do
      nil -> nil
      path -> path ++ [depends_on_id]
    end
  end

  @doc """
  Sort key: effective deadline ascending (tasks without one last), then title
  case-insensitive, then id — the same tiebreak `WeddingPlanner.Tasks.sort_key/2` uses,
  with effective deadline in place of own deadline (`DR-36`).
  """
  @spec sort_key(t(), Task.t()) :: {0 | 1, tuple() | nil, String.t(), id()}
  def sort_key(%__MODULE__{} = g, %Task{} = task) do
    title_key = task.title |> to_string() |> String.downcase()

    case effective_deadline(g, task.id) do
      nil -> {1, nil, title_key, task.id}
      date -> {0, Date.to_erl(date), title_key, task.id}
    end
  end

  # -- private -----------------------------------------------------------------------

  defp resolve_own(task, events_by_id) do
    case Deadline.resolve(task, events_by_id) do
      {:fixed, date} -> date
      {:relative, date} -> date
      :none -> nil
      {:unresolved, _event} -> nil
    end
  end

  defp adjacency(edges, known_ids, key_fun, val_fun) do
    base = Map.new(known_ids, &{&1, []})

    edges
    |> Enum.reduce(base, fn edge, acc ->
      Map.update!(acc, key_fun.(edge), &[val_fun.(edge) | &1])
    end)
    |> Map.new(fn {k, v} -> {k, v |> Enum.uniq() |> Enum.sort()} end)
  end

  # Effective deadline/source for `id`: the minimum own deadline over `id` and every
  # task reachable from it along the dependents adjacency (i.e. every transitive
  # dependent), with ties preferring `id`'s own deadline, then the lowest id (`DR-35`).
  defp effective_for(id, dependents, own_deadlines) do
    candidates =
      id
      |> reachable(dependents)
      |> Enum.map(&{&1, Map.get(own_deadlines, &1)})
      |> Enum.reject(fn {_id, date} -> is_nil(date) end)

    case candidates do
      [] ->
        {nil, nil}

      _non_empty ->
        {winner_id, winner_date} =
          Enum.min_by(candidates, fn {candidate_id, date} ->
            {Date.to_erl(date), if(candidate_id == id, do: 0, else: 1), candidate_id}
          end)

        source = if winner_id == id, do: nil, else: winner_id
        {winner_date, source}
    end
  end

  # BFS reachability from `start` over `adjacency`, with a per-call visited set — cycle
  # tolerant by construction: a node already in `visited` is never re-queued, so the
  # walk terminates regardless of cycles in `adjacency`.
  defp reachable(start, adjacency) do
    do_reachable([start], MapSet.new([start]), adjacency)
  end

  defp do_reachable([], visited, _adjacency), do: visited

  defp do_reachable([node | rest], visited, adjacency) do
    neighbours = Map.get(adjacency, node, [])

    {new_nodes, visited} =
      Enum.reduce(neighbours, {[], visited}, fn n, {acc, vis} ->
        if MapSet.member?(vis, n) do
          {acc, vis}
        else
          {[n | acc], MapSet.put(vis, n)}
        end
      end)

    do_reachable(new_nodes ++ rest, visited, adjacency)
  end

  # Forest builder shared by `waits_on_tree/2`/`waited_on_by_tree/2`. `path` is the set
  # of ancestors on the *current branch only* (not a global "already shown" set) — a
  # diamond's shared node is therefore expanded in full under each branch it appears in
  # (it is not one of its own ancestors), while a real cycle (a node reappearing among
  # its own ancestors) is cut.
  defp build_tree(adjacency, id, path) do
    adjacency
    |> Map.get(id, [])
    |> Enum.map(fn child_id ->
      if MapSet.member?(path, child_id) do
        {child_id, :cut}
      else
        {child_id, build_tree(adjacency, child_id, MapSet.put(path, child_id))}
      end
    end)
  end

  # Shortest path from `start` to `target` over `adjacency` (BFS, neighbours visited in
  # ascending id order for a deterministic choice among equal-length paths). Returns the
  # path including both endpoints, or `nil` if `target` is unreachable from `start`.
  defp bfs_shortest_path(adjacency, start, target) do
    do_bfs(:queue.from_list([start]), MapSet.new([start]), %{}, adjacency, target)
  end

  defp do_bfs(queue, visited, parent, adjacency, target) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        nil

      {{:value, ^target}, _queue} ->
        reconstruct_path(parent, target)

      {{:value, node}, queue} ->
        neighbours = adjacency |> Map.get(node, []) |> Enum.sort()

        {queue, visited, parent} =
          Enum.reduce(neighbours, {queue, visited, parent}, fn n, {q, vis, par} ->
            if MapSet.member?(vis, n) do
              {q, vis, par}
            else
              {:queue.in(n, q), MapSet.put(vis, n), Map.put(par, n, node)}
            end
          end)

        do_bfs(queue, visited, parent, adjacency, target)
    end
  end

  defp reconstruct_path(parent, node), do: reconstruct_path(parent, node, [node])

  defp reconstruct_path(parent, node, acc) do
    case Map.fetch(parent, node) do
      {:ok, p} -> reconstruct_path(parent, p, [p | acc])
      :error -> acc
    end
  end
end
