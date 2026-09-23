defmodule WeddingPlanner.Tasks do
  @moduledoc """
  The couple's shared todo list (`docs/modules/tasks-and-timeline.md`), resource
  `:task`, entity type `"task"`.

  This is slice T1's data layer (plus task 32's category link, `DR-26` Q18): create/
  read/update/delete, owner and deadline storage, the event and category links,
  per-field activity logging (`XC-10`), PubSub (`XC-01`) and the task half of
  `XC-41`/`EVT-05` and of category deletion (`DR-26` Q11/Q18). Task 42 (slice T2) adds
  the other half: task dependencies (`TSK-10` through `TSK-15`) behind
  `WeddingPlanner.Tasks.Graph`, the pure engine task 41 built. The `/tasks` screen itself
  (task 43) and the offer/invoice link targets (slice T4) are still out of scope here.

  ## Dependencies (`TSK-10` through `TSK-15`, `DR-35`, `DR-36`, task 42)

  `WeddingPlanner.Tasks.Dependency` stores one edge per row: `task_id` waits on
  `depends_on_id` — the latter is the prerequisite (`DR-35`'s direction; `→` in a
  rejection message reads "depends on"). `add_dependency/3` runs the existence, duplicate
  and cycle checks inside the same `WeddingPlanner.Log.action/3` transaction as the
  insert, rejecting with the cycle it would close (as `%Task{}` structs, so the caller
  can title them) rather than ever persisting one — see `cycle_message/1`.
  `list_tasks_with_graph/0` is what `list_tasks/0` now delegates to: it loads tasks,
  edges and events each exactly once, builds a `WeddingPlanner.Tasks.Graph`, and sorts by
  effective deadline (`TSK-13`) via `Graph.sort_key/2` — `list_tasks/0`'s own-deadline
  sort from slice T1 is gone, though with no dependencies the two orders coincide.
  Deleting a task others wait on (`delete_task/2`) removes every edge touching it inside
  one `Log.action/3`: the task's own outgoing edges go silently (its own delete entry
  covers them), each waiter's edge to it gets a per-waiter log entry (`XC-10`, mirroring
  `XC-12`'s bulk-action shape even though this isn't a bulk action over externally
  requested entities), and every former waiter is broadcast `{:updated, _}` after commit.
  `task_deletion_effects/1` is the `XC-40` preview of that.

  ## Deadline resolution happens at read time (`TSK-03`)

  `list_tasks/0` never stores a resolved date — see `WeddingPlanner.Tasks.Deadline`.
  This is also why tasks are **not** part of `WeddingPlanner.Valuation.Snapshot`
  (that module's moduledoc explains why): nothing here contributes to a headcount, an
  offer total or the budget.

  ## Owner (`TSK-01`, `D-28`, `DR-22`)

  `WeddingPlanner.Tasks.Task`'s changeset enforces the *shape* (exactly one of user /
  shared / nobody); this module additionally rejects an owner that is not
  `WeddingPlanner.Accounts.Users.assignable?/1` — a user without a registered passkey —
  because that check needs a query the schema changeset cannot make on its own.

  ## Deleting an event that tasks refer to (`XC-41`, `EVT-05`, `DR-26` Q1)

  `detach_event/2` is what `WeddingPlanner.Events.delete_event/2` calls, inside its own
  `WeddingPlanner.Log.action/3`, before it deletes the event row — the `deadline_event_id`
  and `link_event_id` foreign keys are `on_delete: :restrict` precisely so that a caller
  who forgets this ordering gets a loud database error instead of a silent orphan.
  `detach_event/2` itself does not start a transaction and does not broadcast; it is a
  building block for a caller that does both (see its own doc for why).

  `event_deadline_reference/1` and `event_link_reference/1` are the two
  `event_reference_providers` this module registers (via `config/config.exs`,
  orchestrator-owned) so `WeddingPlanner.Events.affected_references/1` can report on
  tasks without `WeddingPlanner.Events` needing to know this module exists.

  ## Deleting a category that tasks link to (`DR-26` Q11/Q18)

  `detach_category/2` is the category analogue of `detach_event/2` — what
  `WeddingPlanner.Categories.delete_category/2` calls, inside its own
  `WeddingPlanner.Log.action/3`, before it deletes the category row. Unlike the event
  side, `WeddingPlanner.Categories` has no provider-config indirection
  (`category_link_reference/1` is called directly from
  `WeddingPlanner.Categories.category_deletion_effects/1` — that module already depends
  on this one, via `tasks.link_category_id`), so there is no `config/config.exs` entry
  to register. Task links are never a deletion **blocker** (`DR-26` Q11), only an
  *effect* — like event links.
  """

  import Ecto.Query

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Accounts.Users
  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Log
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks.Dependency
  alias WeddingPlanner.Tasks.Graph
  alias WeddingPlanner.Tasks.Task
  alias WeddingPlannerWeb.Format

  @resource :task
  @preloads [:owner, :deadline_event, :link_event, :link_category]

  @doc """
  Every task (`TSK-01`), sorted by **effective** deadline ascending (`TSK-13`) — see
  `list_tasks_with_graph/0`, which this delegates to and discards the graph from. With no
  dependencies this is the same order as slice T1's own-deadline sort (`DR-36`).
  """
  @spec list_tasks() :: [Task.t()]
  def list_tasks do
    {tasks, _graph} = list_tasks_with_graph()
    tasks
  end

  @doc """
  Every task, preloaded (`TSK-01`), together with the `WeddingPlanner.Tasks.Graph` built
  from them — tasks, dependency edges and events are each loaded **once** regardless of
  how many tasks or edges exist, so the query count this issues is bounded, not
  proportional to task count. Tasks are sorted by effective deadline ascending
  (`TSK-13`, `Graph.sort_key/2`) — tasks without one sort last, then by title
  (case-insensitive), then by id.
  """
  @spec list_tasks_with_graph() :: {[Task.t()], Graph.t()}
  def list_tasks_with_graph do
    tasks = Task |> preload(^@preloads) |> Repo.all()
    edges = list_dependencies()
    events_by_id = events_by_id()

    graph = Graph.build(tasks, edges, events_by_id)
    sorted = Enum.sort_by(tasks, &Graph.sort_key(graph, &1))

    {sorted, graph}
  end

  @doc "Every dependency edge, as `{task_id, depends_on_id}` (`task_id` waits on `depends_on_id`)."
  @spec list_dependencies() :: [{term(), term()}]
  def list_dependencies do
    Dependency
    |> select([d], {d.task_id, d.depends_on_id})
    |> Repo.all()
  end

  @doc "Fetches one task by id, preloaded. Raises `Ecto.NoResultsError` if it does not exist."
  @spec get_task!(term()) :: Task.t()
  def get_task!(id) do
    Task
    |> preload(^@preloads)
    |> Repo.get!(id)
  end

  @doc """
  A changeset for building/validating a form (create or edit) — never persists on its
  own. Includes the `DR-22` owner-assignable check (not just `Task.changeset/2`'s
  structural rule) so a live form shows that error too, not only a submit-time one.
  """
  @spec change_task(Task.t(), map()) :: Ecto.Changeset.t()
  def change_task(%Task{} = task, attrs \\ %{}) do
    task
    |> Task.changeset(attrs)
    |> validate_owner_assignable()
  end

  @doc """
  Creates a task, logs the create (`XC-10`) and broadcasts `{:created, task}` (`XC-01`).
  Rejects an owner that is not `WeddingPlanner.Accounts.Users.assignable?/1` (`DR-22`).
  """
  @spec create_task(Scope.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def create_task(%Scope{} = scope, attrs) do
    %Task{}
    |> change_task(attrs)
    |> Repo.insert()
    |> case do
      {:ok, task} ->
        {:ok, _} =
          Log.entry(scope, {:task, task.id}, "#{actor(scope)} created task '#{task.title}'")

        task = preload(task)
        Realtime.broadcast_change(@resource, {:created, task})
        {:ok, task}

      error ->
        error
    end
  end

  @doc """
  Updates a task. Logs **one** activity entry per changed user-facing aspect (`XC-10`):
  `title`, `notes` and `status` individually; `owner_id` + `owner_shared` together as
  one "owner" aspect; every `deadline_*` field together as one "deadline" aspect
  (however many of the five columns actually changed); `link_event_id` as one "link"
  aspect. Broadcasts `{:updated, task}` (`XC-01`) once, after every log entry is
  written. Rejects an owner that is not `Users.assignable?/1` (`DR-22`).
  """
  @spec update_task(Scope.t(), Task.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def update_task(%Scope{} = scope, %Task{} = task, attrs) do
    changeset = change_task(task, attrs)

    with {:ok, updated} <- Repo.update(changeset) do
      :ok = log_changes(scope, task, updated, changeset)
      updated = preload(updated)
      Realtime.broadcast_change(@resource, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc """
  Deletes a task, logs the delete (`XC-10`) and broadcasts `{:deleted, id}` (`XC-01`).

  When other tasks wait on `task` (`DR-36`), every edge touching it is removed first —
  otherwise the `:restrict` foreign keys on `task_dependencies` would raise — inside one
  `WeddingPlanner.Log.action/3`: a summary ("Wannes deleted task 'Confirm venue'"), one
  child entry per former waiter ("'Book caterer' no longer waits on 'Confirm venue' (task
  deleted)", entity = that waiter — the edges where `task` was the *waiter* are removed
  silently, since this delete entry already covers them), then `task`'s own delete entry.
  Every former waiter is broadcast `{:updated, _}` (reloaded, preloaded) after commit,
  then `{:deleted, id}` for `task` itself. A task nothing waits on keeps the single-entry
  delete from slice T1.
  """
  @spec delete_task(Scope.t(), Task.t()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def delete_task(%Scope{} = scope, %Task{} = task) do
    case waiters_of(task) do
      [] ->
        # Even with no waiters, `task` may itself wait on other tasks — those edges
        # (task_id == task.id) must go first, silently, or the :restrict FK on
        # `depends_on_id` would refuse the delete.
        result =
          Repo.transaction(fn ->
            Dependency |> where([d], d.task_id == ^task.id) |> Repo.delete_all()

            case Repo.delete(task) do
              {:ok, deleted} -> deleted
              {:error, changeset} -> Repo.rollback(changeset)
            end
          end)

        with {:ok, deleted} <- result do
          {:ok, _} =
            Log.entry(
              scope,
              {:task, deleted.id},
              "#{actor(scope)} deleted task '#{deleted.title}'"
            )

          Realtime.broadcast_change(@resource, {:deleted, deleted.id})
          {:ok, deleted}
        end

      waiters ->
        summary = "#{actor(scope)} deleted task '#{task.title}'"

        {:ok, {deleted, updated_waiters}} =
          Log.action(scope, summary, fn ->
            updated_waiters = Enum.map(waiters, &detach_waiter(scope, &1, task))

            Dependency
            |> where([d], d.task_id == ^task.id)
            |> Repo.delete_all()

            {:ok, deleted} = Repo.delete(task)

            {:ok, _} =
              Log.entry(
                scope,
                {:task, deleted.id},
                "#{actor(scope)} deleted task '#{deleted.title}'"
              )

            {deleted, updated_waiters}
          end)

        Enum.each(updated_waiters, &Realtime.broadcast_change(@resource, {:updated, &1}))
        Realtime.broadcast_change(@resource, {:deleted, deleted.id})
        {:ok, deleted}
    end
  end

  @doc """
  What deleting `task` would affect (`DR-36`, `XC-40`): `[]` when nothing waits on it,
  else one `%{label:, count:}` entry naming every waiting task, e.g. `%{label: "2 tasks
  wait on this: 'Book caterer', 'Print menus' (the dependency is removed)", count: 2}`.
  """
  @spec task_deletion_effects(Task.t()) :: [%{label: String.t(), count: non_neg_integer()}]
  def task_deletion_effects(%Task{} = task) do
    case waiters_of(task) do
      [] ->
        []

      waiters ->
        count = length(waiters)
        names = waiters |> Enum.map_join(", ", &"'#{&1.title}'")

        [
          %{
            label:
              "#{count} #{pluralize(count, "task")} #{wait_verb(count)} on this: #{names} (the dependency is removed)",
            count: count
          }
        ]
    end
  end

  @doc """
  Adds a dependency (`TSK-10`, `DR-35`, `DR-36`): `task` will wait on `prerequisite`.
  Runs entirely inside one `WeddingPlanner.Log.action/3` transaction — existence of both
  tasks (`Repo.exists?/1`, not `foreign_key_constraint/2`, per the reasoning
  `WeddingPlanner.Guests`' moduledoc gives for the identical `group_id` case), the
  duplicate check and the cycle check (`WeddingPlanner.Tasks.Graph.cycle_path/3`, against
  the edges as they stand *inside* the transaction) all run before the insert, so a
  rejection writes nothing — the whole transaction, including the log entry, rolls back.
  A self-dependency (`task.id == prerequisite.id`) is the cycle `[task, task]`, exactly
  as `Graph.cycle_path/3`'s own dedicated clause reports it.

  Returns `{:ok, %Dependency{}}` on success and broadcasts `{:updated, task}` (reloaded,
  preloaded) on `:task` after commit; `{:error, {:cycle, [Task.t()]}}` (see
  `cycle_message/1`), `{:error, :already_exists}` or `{:error, :not_found}` otherwise —
  nothing is persisted or broadcast in any error case.
  """
  @spec add_dependency(Scope.t(), Task.t(), Task.t()) ::
          {:ok, Dependency.t()}
          | {:error, {:cycle, [Task.t()]}}
          | {:error, :already_exists}
          | {:error, :not_found}
  def add_dependency(%Scope{} = scope, %Task{} = task, %Task{} = prerequisite) do
    description = "#{actor(scope)} made '#{task.title}' wait on '#{prerequisite.title}'"

    Log.action(scope, description, fn ->
      cond do
        not (task_exists?(task.id) and task_exists?(prerequisite.id)) ->
          Repo.rollback(:not_found)

        edge_exists?(task.id, prerequisite.id) ->
          Repo.rollback(:already_exists)

        true ->
          case Graph.cycle_path(list_dependencies(), task.id, prerequisite.id) do
            nil ->
              {:ok, dependency} =
                %Dependency{task_id: task.id, depends_on_id: prerequisite.id}
                |> Dependency.changeset()
                |> Repo.insert()

              {:ok, _} = Log.entry(scope, {:task, task.id}, description)

              dependency

            path ->
              Repo.rollback({:cycle, tasks_for_path(path)})
          end
      end
    end)
    |> case do
      {:ok, dependency} ->
        Realtime.broadcast_change(@resource, {:updated, get_task!(task.id)})
        {:ok, dependency}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The rejection message for a cycle a proposed dependency would close (`TSK-10`), e.g.
  `"That would create a dependency cycle: A → B → C → A."` — `tasks` is the path
  `add_dependency/3`'s `{:error, {:cycle, tasks}}` returns, titled and joined with " → ".
  """
  @spec cycle_message([Task.t()]) :: String.t()
  def cycle_message(tasks) do
    "That would create a dependency cycle: #{Enum.map_join(tasks, " → ", & &1.title)}."
  end

  @doc """
  Removes a dependency (`DR-36`): `task` stops waiting on `prerequisite`. Logs one entry
  against `task` ("Wannes removed 'Confirm venue' from what 'Book caterer' waits on") and
  broadcasts `{:updated, task}` (reloaded, preloaded) on `:task`. `{:error, :not_found}`
  when no such edge exists — nothing is written or broadcast.
  """
  @spec remove_dependency(Scope.t(), Task.t(), Task.t()) ::
          {:ok, Dependency.t()} | {:error, :not_found}
  def remove_dependency(%Scope{} = scope, %Task{} = task, %Task{} = prerequisite) do
    case Repo.get_by(Dependency, task_id: task.id, depends_on_id: prerequisite.id) do
      nil ->
        {:error, :not_found}

      dependency ->
        {:ok, dependency} = Repo.delete(dependency)

        {:ok, _} =
          Log.entry(
            scope,
            {:task, task.id},
            "#{actor(scope)} removed '#{prerequisite.title}' from what '#{task.title}' waits on"
          )

        Realtime.broadcast_change(@resource, {:updated, get_task!(task.id)})
        {:ok, dependency}
    end
  end

  @doc """
  `XC-41` / `EVT-05` (task half, `DR-26` Q1): for every task anchoring a deadline on
  `event`, sets that deadline to *none* and logs it; for every task linked to `event`,
  clears the link and logs it. A task that does both gets one combined DB update and
  **two** log entries (one per aspect), matching `update_task/3`'s "one entry per
  aspect" convention.

  `XC-41` itself only talks about the relative-deadline anchor going to *none* — `docs/`
  says nothing about a task's separate *link* to a deleted event. Clearing the link here
  too, logged the same way, is this module's own extension of that same principle
  (`DR-26` Q1); it is not literally in `docs/`, which is why it is spelled out here
  rather than assumed.

  **Must be called inside an enclosing `WeddingPlanner.Log.action/3`** — every
  `Log.entry/3` call here relies on that action's summary/transaction to make the
  entries children of the summary and to make the whole thing atomic with the event
  delete that must follow it. This function does not start its own transaction and does
  not broadcast; the caller (`WeddingPlanner.Events.delete_event/2`) broadcasts
  `{:updated, task}` for each task this returns, once the transaction commits.
  """
  @spec detach_event(Scope.t(), Event.t()) :: [Task.t()]
  def detach_event(%Scope{} = scope, %Event{} = event) do
    Task
    |> where([t], t.deadline_event_id == ^event.id or t.link_event_id == ^event.id)
    |> Repo.all()
    |> Enum.map(&detach_single(scope, &1, event))
  end

  @doc """
  `EVT-05` provider: how many tasks anchor a relative deadline on `event`, or `nil` if
  none do. Registered via `config :wedding_planner, event_reference_providers:`.
  """
  @spec event_deadline_reference(Event.t()) :: %{label: String.t(), count: pos_integer()} | nil
  def event_deadline_reference(%Event{} = event) do
    case count_where(dynamic([t], t.deadline_event_id == ^event.id)) do
      0 ->
        nil

      n ->
        %{
          label:
            "#{n} #{pluralize(n, "task")} with a deadline relative to this event (deadline becomes none)",
          count: n
        }
    end
  end

  @doc """
  `EVT-05` provider: how many tasks are linked to `event`, or `nil` if none are.
  Registered via `config :wedding_planner, event_reference_providers:`.
  """
  @spec event_link_reference(Event.t()) :: %{label: String.t(), count: pos_integer()} | nil
  def event_link_reference(%Event{} = event) do
    case count_where(dynamic([t], t.link_event_id == ^event.id)) do
      0 -> nil
      n -> %{label: "#{n} #{pluralize(n, "task")} linked to this event (link removed)", count: n}
    end
  end

  @doc """
  `DR-26` Q11/Q18 (task half of category deletion): for every task linked to
  `category`, clears the link and logs it — mirrors `detach_event/2`'s role in the
  analogous event-deletion path. This is what `WeddingPlanner.Categories.delete_category/2`
  calls, inside its own `WeddingPlanner.Log.action/3`, before the category row is
  deleted — `link_category_id`'s `on_delete: :restrict` exists precisely so a caller who
  forgets that ordering gets a loud database error instead of a silently orphaned link.

  Like `detach_event/2`, this function does not start its own transaction and does not
  broadcast; the caller broadcasts `{:updated, task}` for each task this returns, once
  the transaction commits.
  """
  @spec detach_category(Scope.t(), Category.t()) :: [Task.t()]
  def detach_category(%Scope{} = scope, %Category{} = category) do
    Task
    |> where([t], t.link_category_id == ^category.id)
    |> Repo.all()
    |> Enum.map(&detach_category_single(scope, &1, category))
  end

  @doc """
  `DR-26` Q11/Q18: how many tasks are linked to `category`, or `nil` if none are.
  Called directly by `WeddingPlanner.Categories.category_deletion_effects/1` —
  `WeddingPlanner.Categories` has no provider-config indirection the way
  `WeddingPlanner.Events.affected_references/1` does (see that module's moduledoc); this
  module is already `Categories`' known dependency (`link_category_id`), so a direct
  call is simplest.
  """
  @spec category_link_reference(Category.t()) :: %{label: String.t(), count: pos_integer()} | nil
  def category_link_reference(%Category{} = category) do
    case count_where(dynamic([t], t.link_category_id == ^category.id)) do
      0 ->
        nil

      n ->
        %{
          label: "#{n} #{pluralize(n, "task")} linked to this category (link removed)",
          count: n
        }
    end
  end

  @doc """
  `WeddingPlanner.Log.EntityRef` resolver for the `"task"` entity type: an existing
  task resolves to its title and `/tasks?open=<id>`; a deleted one is `:error`
  (degrades to plain text, same as every other resolver).
  """
  @spec resolve_log_entity(term()) :: {:ok, String.t(), String.t() | nil} | :error
  def resolve_log_entity(id) do
    case Repo.get(Task, id) do
      nil -> :error
      task -> {:ok, task.title, "/tasks?open=#{task.id}"}
    end
  end

  # -- private -----------------------------------------------------------------------

  defp preload(%Task{} = task), do: Repo.preload(task, @preloads)

  defp events_by_id do
    Event |> Repo.all() |> Map.new(&{&1.id, &1})
  end

  defp waiters_of(%Task{} = task) do
    Dependency
    |> where([d], d.depends_on_id == ^task.id)
    |> join(:inner, [d], t in Task, on: t.id == d.task_id)
    |> order_by([d, t], t.id)
    |> select([d, t], t)
    |> Repo.all()
  end

  defp detach_waiter(scope, %Task{} = waiter, %Task{} = task) do
    Dependency
    |> where([d], d.task_id == ^waiter.id and d.depends_on_id == ^task.id)
    |> Repo.delete_all()

    {:ok, _} =
      Log.entry(
        scope,
        {:task, waiter.id},
        "'#{waiter.title}' no longer waits on '#{task.title}' (task deleted)"
      )

    preload(waiter)
  end

  defp wait_verb(1), do: "waits"
  defp wait_verb(_), do: "wait"

  defp task_exists?(id), do: Repo.exists?(where(Task, [t], t.id == ^id))

  defp edge_exists?(task_id, depends_on_id) do
    Repo.exists?(
      where(Dependency, [d], d.task_id == ^task_id and d.depends_on_id == ^depends_on_id)
    )
  end

  defp tasks_for_path(path) do
    by_id =
      Task
      |> where([t], t.id in ^path)
      |> preload(^@preloads)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(path, &Map.fetch!(by_id, &1))
  end

  defp count_where(dynamic) do
    Task
    |> where(^dynamic)
    |> Repo.aggregate(:count)
  end

  defp pluralize(1, word), do: word
  defp pluralize(_n, word), do: word <> "s"

  defp validate_owner_assignable(changeset) do
    case Ecto.Changeset.get_field(changeset, :owner_id) do
      nil ->
        changeset

      owner_id ->
        if Users.assignable?(owner_id) do
          changeset
        else
          Ecto.Changeset.add_error(
            changeset,
            :owner_id,
            "must be a user with a registered passkey"
          )
        end
    end
  end

  defp log_changes(scope, %Task{} = before, %Task{} = updated, changeset) do
    changed = Map.keys(changeset.changes)

    for field <- [:title, :notes, :status], field in changed do
      log_simple_change(scope, before, updated, field)
    end

    if Enum.any?(changed, &(&1 in [:owner_id, :owner_shared])) do
      log_owner_change(scope, before, updated)
    end

    if Enum.any?(changed, &(&1 in Task.deadline_fields())) do
      log_deadline_change(scope, before, updated)
    end

    if Enum.any?(changed, &(&1 in [:link_event_id, :link_category_id])) do
      log_link_change(scope, before, updated)
    end

    :ok
  end

  defp log_simple_change(scope, %Task{} = before, %Task{} = updated, field) do
    old = field_value(field, Map.fetch!(before, field))
    new = field_value(field, Map.fetch!(updated, field))

    {:ok, _} =
      Log.entry(
        scope,
        {:task, before.id},
        "#{actor(scope)} changed the #{field} of '#{before.title}': #{old} → #{new}"
      )
  end

  defp log_owner_change(scope, %Task{} = before, %Task{} = updated) do
    old = owner_label(before.owner_id, before.owner_shared)
    new = owner_label(updated.owner_id, updated.owner_shared)

    {:ok, _} =
      Log.entry(
        scope,
        {:task, before.id},
        "#{actor(scope)} changed the owner of '#{before.title}': #{old} → #{new}"
      )
  end

  defp log_deadline_change(scope, %Task{} = before, %Task{} = updated) do
    old = deadline_label(before)
    new = deadline_label(updated)

    {:ok, _} =
      Log.entry(
        scope,
        {:task, before.id},
        "#{actor(scope)} changed the deadline of '#{before.title}': #{old} → #{new}"
      )
  end

  defp log_link_change(scope, %Task{} = before, %Task{} = updated) do
    old = link_label(before)
    new = link_label(updated)

    {:ok, _} =
      Log.entry(
        scope,
        {:task, before.id},
        "#{actor(scope)} changed the link of '#{before.title}': #{old} → #{new}"
      )
  end

  defp detach_single(scope, %Task{} = task, %Event{} = event) do
    anchors_deadline? = task.deadline_event_id == event.id
    linked? = task.link_event_id == event.id

    changes =
      []
      |> maybe_clear_deadline(anchors_deadline?)
      |> maybe_clear_link(linked?)

    {:ok, updated} = task |> Ecto.Changeset.change(changes) |> Repo.update()

    if anchors_deadline? do
      old_label = deadline_label(task)

      {:ok, _} =
        Log.entry(
          scope,
          {:task, task.id},
          "#{actor(scope)} cleared the deadline of '#{task.title}': #{old_label} → none (event '#{event.name}' was deleted)"
        )
    end

    if linked? do
      {:ok, _} =
        Log.entry(
          scope,
          {:task, task.id},
          "#{actor(scope)} cleared the link of '#{task.title}': event '#{event.name}' → none (event '#{event.name}' was deleted)"
        )
    end

    preload(updated)
  end

  defp detach_category_single(scope, %Task{} = task, %Category{} = category) do
    {:ok, updated} = task |> Ecto.Changeset.change(link_category_id: nil) |> Repo.update()

    {:ok, _} =
      Log.entry(
        scope,
        {:task, task.id},
        "#{actor(scope)} removed the link from '#{task.title}' to category '#{category.name}' (category deleted)"
      )

    preload(updated)
  end

  defp maybe_clear_deadline(changes, false), do: changes

  defp maybe_clear_deadline(changes, true) do
    changes ++
      [
        deadline_kind: :none,
        deadline_date: nil,
        deadline_amount: nil,
        deadline_unit: nil,
        deadline_direction: nil,
        deadline_event_id: nil
      ]
  end

  defp maybe_clear_link(changes, false), do: changes
  defp maybe_clear_link(changes, true), do: changes ++ [link_event_id: nil]

  defp status_label(:to_do), do: "to do"
  defp status_label(:in_progress), do: "in progress"
  defp status_label(:done), do: "done"

  defp field_value(:status, value), do: status_label(value)
  defp field_value(_field, nil), do: "none"
  defp field_value(_field, value), do: value

  defp owner_label(_owner_id, true), do: "Both"
  defp owner_label(nil, false), do: "Nobody"

  defp owner_label(owner_id, false) do
    case Repo.get(User, owner_id) do
      nil -> "Nobody"
      user -> user.display_name
    end
  end

  defp deadline_label(%Task{deadline_kind: :none}), do: "none"
  defp deadline_label(%Task{deadline_kind: :fixed, deadline_date: date}), do: Format.date(date)

  defp deadline_label(%Task{deadline_kind: :relative} = task) do
    event = Repo.get(Event, task.deadline_event_id)
    relative_label(task.deadline_amount, task.deadline_unit, task.deadline_direction, event)
  end

  defp relative_label(0, _unit, _direction, event), do: "on the day of #{event_name(event)}"

  defp relative_label(amount, unit, direction, event) do
    "#{amount} #{unit_word(unit, amount)} #{direction_word(direction)} #{event_name(event)}"
  end

  defp unit_word(:days, 1), do: "day"
  defp unit_word(:days, _), do: "days"
  defp unit_word(:weeks, 1), do: "week"
  defp unit_word(:weeks, _), do: "weeks"

  defp direction_word(:before), do: "before"
  defp direction_word(:after), do: "after"

  defp event_name(nil), do: "a deleted event"
  defp event_name(%Event{name: name}), do: name

  defp link_label(%Task{link_event_id: nil, link_category_id: nil}), do: "none"

  defp link_label(%Task{link_event_id: id}) when not is_nil(id) do
    "event '#{event_name(Repo.get(Event, id))}'"
  end

  defp link_label(%Task{link_category_id: id}) do
    "category '#{category_name(Repo.get(Category, id))}'"
  end

  defp category_name(nil), do: "a deleted category"
  defp category_name(%Category{name: name}), do: name

  defp actor(%Scope{user: %User{display_name: name}}), do: name
end
