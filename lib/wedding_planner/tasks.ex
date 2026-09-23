defmodule WeddingPlanner.Tasks do
  @moduledoc """
  The couple's shared todo list (`docs/modules/tasks-and-timeline.md`), resource
  `:task`, entity type `"task"`.

  This is slice T1's data layer (plus task 32's category link, `DR-26` Q18): create/
  read/update/delete, owner and deadline storage, the event and category links,
  per-field activity logging (`XC-10`), PubSub (`XC-01`) and the task half of
  `XC-41`/`EVT-05` and of category deletion (`DR-26` Q11/Q18). Dependencies/blocked/
  effective-deadline (`TSK-10` through `TSK-15`, slice T2), the `/tasks` screen itself
  (task 31) and the offer/invoice link targets (slice T4) are all out of scope here.

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
  alias WeddingPlanner.Tasks.Deadline
  alias WeddingPlanner.Tasks.Task
  alias WeddingPlannerWeb.Format

  @resource :task
  @preloads [:owner, :deadline_event, :link_event, :link_category]

  @doc """
  Every task (`TSK-01`), preloaded with owner/deadline event/link event, sorted by
  **resolved** own deadline ascending — tasks with no deadline or an unresolved relative
  deadline sort last (`TSK-03`) — then by title (case-insensitive), then by id as a
  stable tiebreak. Resolution happens in Elixir via `WeddingPlanner.Tasks.Deadline`,
  never stored.
  """
  @spec list_tasks() :: [Task.t()]
  def list_tasks do
    events_by_id = events_by_id()

    Task
    |> preload(^@preloads)
    |> Repo.all()
    |> Enum.sort_by(&sort_key(&1, events_by_id))
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
  """
  @spec delete_task(Scope.t(), Task.t()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def delete_task(%Scope{} = scope, %Task{} = task) do
    with {:ok, deleted} <- Repo.delete(task) do
      {:ok, _} =
        Log.entry(scope, {:task, deleted.id}, "#{actor(scope)} deleted task '#{deleted.title}'")

      Realtime.broadcast_change(@resource, {:deleted, deleted.id})
      {:ok, deleted}
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

  # `Date.to_erl/1` turns a resolved date into a plain `{year, month, day}` tuple so the
  # default term ordering `Enum.sort_by/2` uses compares chronologically. Comparing
  # `%Date{}` structs directly with `<=` would compare their *field* order
  # (`:calendar`, `:day`, `:month`, `:year`) instead — silently sorting by day-of-month
  # first, which happens to agree with chronological order only by coincidence for
  # nearby dates and is wrong in general (e.g. 2025-12-31 would sort after 2026-01-01).
  defp sort_key(%Task{} = task, events_by_id) do
    title_key = task.title |> to_string() |> String.downcase()

    case Deadline.resolve(task, events_by_id) do
      {:fixed, date} -> {0, Date.to_erl(date), title_key, task.id}
      {:relative, date} -> {0, Date.to_erl(date), title_key, task.id}
      :none -> {1, nil, title_key, task.id}
      {:unresolved, _event} -> {1, nil, title_key, task.id}
    end
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
