defmodule WeddingPlanner.Tasks.Deadline do
  @moduledoc """
  Pure resolution of a task's deadline (`docs/modules/tasks-and-timeline.md` TSK-02,
  TSK-03). No `Ecto`, no `Repo`, no side effects — the whole point is that resolving a
  relative deadline is a cheap, repeatable function of *current* data, never something
  written back to the row. That is what makes "changing the event's date moves the
  deadline" and "resolved automatically when the event gets a date" free: nothing has to
  notice the event changed and go fix up stored tasks.

  Slice T2's effective-deadline engine (`TSK-13`) is meant to build on `resolve/2`
  directly, which is why this stays in its own dependency-free module rather than living
  as private functions inside `WeddingPlanner.Tasks`.

  `resolve/2` takes `events_by_id`, a map of every event a caller might need to look up,
  rather than querying itself — the caller (typically `WeddingPlanner.Tasks.list_tasks/0`)
  is expected to have already loaded every event once and reuse that map across every
  task, rather than each task re-querying its own anchor event.
  """

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Tasks.Task

  @type events_by_id :: %{optional(term()) => Event.t()}
  @type resolved :: :none | {:fixed, Date.t()} | {:relative, Date.t()} | {:unresolved, Event.t()}

  @doc """
  Resolves `task`'s deadline against `events_by_id` (id => `Event.t()`, covering at
  least `task.deadline_event_id` when the kind is `:relative`).

  Returns:

    * `:none` — no deadline (`TSK-02`)
    * `{:fixed, date}` — a fixed-date deadline
    * `{:relative, date}` — a relative deadline whose anchor event has a date, resolved
      to a calendar date (weeks × 7 days, `Date.add/2`; `:before` subtracts, `:after`
      adds; an amount of `0` is the event's own date)
    * `{:unresolved, event}` — a relative deadline whose anchor event has no date yet
      (`TSK-03`) — treated as having no deadline for sorting (`WeddingPlanner.Tasks.list_tasks/0`)

  ## Examples — normative example T4 (`docs/07-normative-examples.md`)

      iex> reception = %WeddingPlanner.Events.Event{id: 1, name: "Reception", date: nil}
      iex> task = %WeddingPlanner.Tasks.Task{
      ...>   title: "Send invitations",
      ...>   deadline_kind: :relative,
      ...>   deadline_amount: 12,
      ...>   deadline_unit: :weeks,
      ...>   deadline_direction: :before,
      ...>   deadline_event_id: 1
      ...> }
      iex> WeddingPlanner.Tasks.Deadline.resolve(task, %{1 => reception})
      {:unresolved, reception}

      iex> reception = %WeddingPlanner.Events.Event{id: 1, name: "Reception", date: ~D[2028-05-13]}
      iex> task = %WeddingPlanner.Tasks.Task{
      ...>   title: "Send invitations",
      ...>   deadline_kind: :relative,
      ...>   deadline_amount: 12,
      ...>   deadline_unit: :weeks,
      ...>   deadline_direction: :before,
      ...>   deadline_event_id: 1
      ...> }
      iex> WeddingPlanner.Tasks.Deadline.resolve(task, %{1 => reception})
      {:relative, ~D[2028-02-19]}

      iex> WeddingPlanner.Tasks.Deadline.resolve(%WeddingPlanner.Tasks.Task{deadline_kind: :none}, %{})
      :none

      iex> WeddingPlanner.Tasks.Deadline.resolve(
      ...>   %WeddingPlanner.Tasks.Task{deadline_kind: :fixed, deadline_date: ~D[2028-05-13]},
      ...>   %{}
      ...> )
      {:fixed, ~D[2028-05-13]}

  """
  @spec resolve(Task.t(), events_by_id()) :: resolved()
  def resolve(%Task{deadline_kind: :none}, _events_by_id), do: :none

  def resolve(%Task{deadline_kind: :fixed, deadline_date: %Date{} = date}, _events_by_id) do
    {:fixed, date}
  end

  def resolve(%Task{deadline_kind: :relative} = task, events_by_id) do
    event = Map.get(events_by_id, task.deadline_event_id)

    case event do
      %Event{date: %Date{} = date} ->
        {:relative,
         offset(date, task.deadline_amount, task.deadline_unit, task.deadline_direction)}

      %Event{date: nil} = event ->
        {:unresolved, event}
    end
  end

  defp offset(date, amount, :days, :before), do: Date.add(date, -amount)
  defp offset(date, amount, :days, :after), do: Date.add(date, amount)
  defp offset(date, amount, :weeks, :before), do: Date.add(date, -amount * 7)
  defp offset(date, amount, :weeks, :after), do: Date.add(date, amount * 7)
end
