defmodule WeddingPlanner.Tasks.TodoList do
  @moduledoc """
  Pure todo-list engine (`docs/modules/tasks-and-timeline.md` **TSK-20**, **TSK-23**;
  `.claude/plans/roadmap.md` **DR-44**). No `Repo`, no Ecto, no Phoenix — a function of a
  plain list of `%WeddingPlanner.Tasks.Task{}` structs, a built
  `WeddingPlanner.Tasks.Graph.t()`, a `filter_state()` and a `today :: Date.t()`, so every
  rule here is exhaustively example- and property-testable without a LiveView (`NFR-41`).

  ## Today (`NFR-22`, `DR-44`)

  `today/1` takes the *viewer's* time zone (`TimeZoneHook`'s `@time_zone` assign,
  falling back to `"Europe/Brussels"` upstream — this module does not pick that
  fallback, it just takes whatever zone it is handed) and returns
  `DateTime.now!(time_zone) |> DateTime.to_date()`. Every other function here takes
  `today` as a plain argument instead of computing it, so tests stay deterministic
  across real calendar boundaries without faking the clock.

  ## Sections (`DR-44`)

  `section_of/3` buckets a task by its *effective* deadline
  (`WeddingPlanner.Tasks.Graph.effective_deadline/2`, `TSK-13`) relative to `today`:

    * `:overdue` — effective deadline strictly before `today` (`TSK-23`).
    * `:this_week` — `today` through `today + 6` inclusive (a rolling seven-day window,
      not "this calendar week", so Sunday is never a cliff).
    * `:later` — after `today + 6`.
    * `:no_deadline` — no effective deadline at all (none set, or an unresolved relative
      deadline — `TSK-03`, which `Graph.effective_deadline/2` already folds into `nil`).

  `build/4` sections only not-done tasks; done tasks never appear in `sections` (they are
  returned separately, unfiltered, as `done`). An empty section is omitted from the
  result rather than shown with a zero count. Within a section, task order is whatever
  order `tasks` arrived in — the caller is expected to pass
  `WeddingPlanner.Tasks.list_tasks_with_graph/0`'s already-effective-deadline-sorted
  list, so sectioning only ever *partitions*, never re-sorts (`DR-36`).

  Every date comparison here goes through `Date.compare/2`, **never** `<`/`<=`/
  `Enum.min/1` directly on `%Date{}` structs — see `WeddingPlanner.Tasks.Graph`'s
  moduledoc for why that silently mis-sorts across a month or year boundary.

  ## Filters (`TSK-20`, `DR-44`)

  A `filter_state()` holds a `MapSet` of chips plus an owner selection. All active
  filters AND-combine, and apply to not-done tasks only — a done task is never hidden
  by a filter (it lives in `done`, outside `sections` entirely, always).

    * `:actionable` (not blocked, `Graph.blocked?/2`) and `:blocked` are **mutually
      exclusive** — enabling one via `toggle_chip/2` disables the other.
    * `:overdue` (in the `:overdue` section) and `:this_week` (in the `:this_week`
      section) are likewise mutually exclusive.
    * The owner filter (`TSK-01`) is `:everyone` (default, matches everyone) |
      `{:user, user_id}` (owned by that user **or** shared — TSK-01: shared means every
      user, so a shared task always matches every specific-user filter) | `:unassigned`
      (no owner and not shared).

  ## URL round-trip (`DR-44`)

  `to_params/1` and `from_params/1` are the two halves of keeping filter state in the
  query string (task 48's job to actually push it there). `to_params/1` omits
  defaults, so an unfiltered view keeps a clean URL. `from_params/1` never raises on a
  malformed or unknown value — the URL is user-editable — it falls back to the default
  for whatever it cannot make sense of. Neither side ever calls `String.to_atom/1` on
  external input; known strings are mapped to atoms explicitly.
  """

  alias WeddingPlanner.Tasks.Graph
  alias WeddingPlanner.Tasks.Task

  @type chip :: :actionable | :blocked | :overdue | :this_week
  @type owner :: :everyone | :unassigned | {:user, term()}
  @type filter_state :: %{chips: MapSet.t(chip()), owner: owner()}
  @type section_id :: :overdue | :this_week | :later | :no_deadline
  @type section :: %{id: section_id(), label: String.t(), tasks: [Task.t()]}
  @type result :: %{
          sections: [section()],
          shown: non_neg_integer(),
          total_not_done: non_neg_integer(),
          done: [Task.t()]
        }

  @chips [:actionable, :blocked, :overdue, :this_week]
  @exclusive_partner %{
    actionable: :blocked,
    blocked: :actionable,
    overdue: :this_week,
    this_week: :overdue
  }

  @section_order [:overdue, :this_week, :later, :no_deadline]
  @section_labels %{
    overdue: "Overdue",
    this_week: "This week",
    later: "Later",
    no_deadline: "No deadline"
  }

  @chip_from_string Map.new(@chips, &{Atom.to_string(&1), &1})

  @doc "The default filter state: no chips active, every owner shown."
  @spec default_filters() :: filter_state()
  def default_filters, do: %{chips: MapSet.new(), owner: :everyone}

  @doc """
  Today's calendar date in `time_zone` (`NFR-22`, `DR-44`) — the viewer's time zone, not
  the server's.
  """
  @spec today(String.t()) :: Date.t()
  def today(time_zone) do
    time_zone
    |> DateTime.now!()
    |> DateTime.to_date()
  end

  @doc """
  Which urgency section `task` falls in, relative to `today` (`TSK-23`, `DR-44`).
  `graph` supplies the *effective* deadline (`TSK-13`), not the task's own.
  """
  @spec section_of(Graph.t(), Task.t(), Date.t()) :: section_id()
  def section_of(%Graph{} = graph, %Task{} = task, %Date{} = today) do
    case Graph.effective_deadline(graph, task.id) do
      nil ->
        :no_deadline

      date ->
        this_week_end = Date.add(today, 6)

        cond do
          Date.compare(date, today) == :lt -> :overdue
          Date.compare(date, this_week_end) != :gt -> :this_week
          true -> :later
        end
    end
  end

  @doc """
  Toggles `chip` in `state`: on if it was off, off if it was on. Turning on
  `:actionable` turns off `:blocked` (and vice versa); same for `:overdue`/`:this_week`
  — the two mutually-exclusive pairs (`DR-44`). Unknown chips are ignored, `state`
  unchanged.
  """
  @spec toggle_chip(filter_state(), chip()) :: filter_state()
  def toggle_chip(%{chips: chips} = state, chip) when chip in @chips do
    new_chips =
      if MapSet.member?(chips, chip) do
        MapSet.delete(chips, chip)
      else
        enable_chip(chips, chip)
      end

    %{state | chips: new_chips}
  end

  def toggle_chip(state, _unknown_chip), do: state

  @doc "Sets the owner filter, replacing whatever it was."
  @spec put_owner(filter_state(), owner()) :: filter_state()
  def put_owner(state, owner), do: %{state | owner: owner}

  @doc """
  Builds the todo list's shape (`TSK-20`): `tasks` sectioned by urgency after every
  active filter in `filter_state` is applied, plus the done tasks (always present,
  never filtered). `graph` must have been built from (a superset of) `tasks`. `shown` is
  how many not-done tasks passed the filters (the sum of every section's tasks);
  `total_not_done` is how many not-done tasks there were before filtering, for a
  "N of M shown" caption.
  """
  @spec build([Task.t()], Graph.t(), filter_state(), Date.t()) :: result()
  def build(tasks, %Graph{} = graph, %{} = filter_state, %Date{} = today) do
    {done, not_done} = Enum.split_with(tasks, &(&1.status == :done))

    filtered = Enum.filter(not_done, &matches?(graph, &1, filter_state, today))
    sections = sections_for(graph, filtered, today)
    shown = Enum.reduce(sections, 0, fn section, acc -> acc + length(section.tasks) end)

    %{sections: sections, shown: shown, total_not_done: length(not_done), done: done}
  end

  @doc """
  Parses a `filter_state()` out of raw (string-keyed, string-valued) URL params —
  `"filter" => "actionable,overdue"`, `"owner" => "everyone" | "unassigned" | "<id>"`.
  Unknown chip tokens are dropped; an unrecognised or malformed owner value falls back
  to `:everyone`. Never raises — `params` is user-editable via the address bar.
  """
  @spec from_params(map()) :: filter_state()
  def from_params(params) when is_map(params) do
    %{
      chips: chips_from_param(Map.get(params, "filter")),
      owner: owner_from_param(Map.get(params, "owner"))
    }
  end

  @doc """
  The inverse of `from_params/1`, as a string-keyed map suitable for a query string.
  Omits a key entirely when it holds the default value, so an unfiltered view produces
  a clean URL (no `?filter=&owner=everyone`).
  """
  @spec to_params(filter_state()) :: map()
  def to_params(%{chips: chips, owner: owner}) do
    %{}
    |> put_chips_param(chips)
    |> put_owner_param(owner)
  end

  # -- private -----------------------------------------------------------------------

  defp enable_chip(chips, chip) do
    chips
    |> MapSet.delete(Map.fetch!(@exclusive_partner, chip))
    |> MapSet.put(chip)
  end

  defp matches?(graph, task, %{chips: chips, owner: owner}, today) do
    matches_chips?(graph, task, chips, today) and matches_owner?(task, owner)
  end

  defp matches_chips?(graph, task, chips, today) do
    chip_ok?(chips, :actionable, fn -> not Graph.blocked?(graph, task.id) end) and
      chip_ok?(chips, :blocked, fn -> Graph.blocked?(graph, task.id) end) and
      chip_ok?(chips, :overdue, fn -> section_of(graph, task, today) == :overdue end) and
      chip_ok?(chips, :this_week, fn -> section_of(graph, task, today) == :this_week end)
  end

  defp chip_ok?(chips, chip, predicate) do
    if MapSet.member?(chips, chip), do: predicate.(), else: true
  end

  defp matches_owner?(%Task{}, :everyone), do: true

  defp matches_owner?(%Task{owner_id: owner_id, owner_shared: shared?}, :unassigned) do
    is_nil(owner_id) and not shared?
  end

  defp matches_owner?(%Task{owner_id: owner_id, owner_shared: shared?}, {:user, user_id}) do
    shared? or owner_id == user_id
  end

  defp sections_for(graph, tasks, today) do
    grouped = Enum.group_by(tasks, &section_of(graph, &1, today))

    @section_order
    |> Enum.map(&{&1, Map.get(grouped, &1, [])})
    |> Enum.reject(fn {_id, tasks} -> tasks == [] end)
    |> Enum.map(fn {id, tasks} ->
      %{id: id, label: Map.fetch!(@section_labels, id), tasks: tasks}
    end)
  end

  defp chips_from_param(nil), do: MapSet.new()

  defp chips_from_param(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn token ->
      case Map.fetch(@chip_from_string, token) do
        {:ok, chip} -> [chip]
        :error -> []
      end
    end)
    |> Enum.reduce(MapSet.new(), &enable_chip(&2, &1))
  end

  defp chips_from_param(_malformed), do: MapSet.new()

  defp owner_from_param(nil), do: :everyone
  defp owner_from_param("everyone"), do: :everyone
  defp owner_from_param("unassigned"), do: :unassigned

  defp owner_from_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> {:user, id}
      _not_an_id -> :everyone
    end
  end

  defp owner_from_param(_malformed), do: :everyone

  defp put_chips_param(params, chips) do
    if MapSet.size(chips) == 0 do
      params
    else
      value = chips |> Enum.map(&Atom.to_string/1) |> Enum.sort() |> Enum.join(",")
      Map.put(params, "filter", value)
    end
  end

  defp put_owner_param(params, :everyone), do: params
  defp put_owner_param(params, :unassigned), do: Map.put(params, "owner", "unassigned")
  defp put_owner_param(params, {:user, id}), do: Map.put(params, "owner", to_string(id))
end
