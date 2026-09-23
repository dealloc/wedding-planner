defmodule WeddingPlanner.Events do
  @moduledoc """
  Events CRUD plus manual reordering (`docs/modules/guests-and-events.md` EVT-01
  through EVT-05). This is the **exemplar** vertical slice every later domain module
  copies: context -> LiveView -> activity log -> PubSub -> tests.

  ## Manual sort order, never date order (EVT-04)

  `list_events/0` is the only supported read order: `sort_order`, then `id` as a stable
  tiebreak. Nothing in this module ever orders by `date` — EVT-02 says events may be on
  different days and nothing may assume they share one, so a date-ordered list would be
  a genuine bug, not a style choice.

  ## "No date yet" (EVT-03)

  `date` is nilable everywhere in this module and in `WeddingPlanner.Events.Event`.
  Nothing here defaults it, rejects `nil`, or treats a missing date as an error.
  `WeddingPlannerWeb.Format.date/1` is what renders the explicit placeholder — this
  module just never converts a `nil` into anything else.

  ## Deletion and EVT-05

  `affected_references/1` returns what deleting `event` would affect, as a list of
  `%{label: String.t(), count: non_neg_integer()}` maps — one per reference *type* that
  currently references it, via

      config :wedding_planner,
        event_reference_providers: [&MyModule.event_reference/1, ...]

  where each provider is a 1-arity function `event -> %{label:, count:} | nil` (`nil`
  meaning "this type doesn't reference this event"). `WeddingPlanner.Tasks` registers
  the first two providers (task deadlines anchored on the event, task links to it —
  `TSK-01`/`XC-41`, `DR-26` Q1, which gives the *task* half of `EVT-05` to slice T1
  rather than waiting for C6). **Slice C6** still owns the *offer line* half
  (`XC-41`/`XC-42` for invalid lines) and adds its own provider later.

  `delete_event/2` itself branches on whether anything references the event
  (`affected_references/1 == []`): with no references it behaves exactly as before —
  one log entry, one transaction-free delete. With references, it runs the whole thing
  through one `WeddingPlanner.Log.action/3`: `WeddingPlanner.Tasks.detach_event/2` first
  (clearing every anchored deadline and link, each logged as its own child entry) *then*
  the event row is deleted (now safe — the `:restrict` foreign keys on
  `tasks.deadline_event_id`/`tasks.link_event_id` would otherwise block it) *then* the
  event's own "deleted event" entry is written. Every detached task's `{:updated, task}`
  and the event's `{:deleted, id}` broadcast only after that transaction commits.

  ## Activity log (`XC-10`) and PubSub (`XC-01`, `XC-02`)

  Every mutation writes through `WeddingPlanner.Log` and broadcasts the whole resulting
  record via `WeddingPlanner.Realtime` (resource `:event`) only after its write
  succeeds. `move_event/3` touches two rows, so — per `WeddingPlanner.Log`'s own
  guidance — it goes through `Log.action/3` (one summarising entry plus one child entry
  per affected event, `XC-12`) rather than two independent `Log.entry/3` calls.
  """

  import Ecto.Query

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Log
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlannerWeb.Format

  @resource :event
  @loggable_fields [:name, :date, :location, :notes]

  @doc "EVT-04: every event, in manual sort order — never by date."
  @spec list_events() :: [Event.t()]
  def list_events do
    Event
    |> order_by([e], asc: e.sort_order, asc: e.id)
    |> Repo.all()
  end

  @doc "Fetches one event by id. Raises `Ecto.NoResultsError` if it does not exist."
  @spec get_event!(term()) :: Event.t()
  def get_event!(id), do: Repo.get!(Event, id)

  @doc """
  A changeset for building/validating a form (create or edit) — never persists on its
  own.
  """
  @spec change_event(Event.t(), map()) :: Ecto.Changeset.t()
  def change_event(%Event{} = event, attrs \\ %{}), do: Event.changeset(event, attrs)

  @doc """
  Creates an event, appended after the current last one (EVT-04 — new events never
  reorder existing ones), logs the create (`XC-10`) and broadcasts `{:created, event}`
  (`XC-01`).
  """
  @spec create_event(Scope.t(), map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def create_event(%Scope{} = scope, attrs) do
    %Event{sort_order: next_sort_order()}
    |> Event.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, event} ->
        {:ok, _} =
          Log.entry(scope, {:event, event.id}, "#{actor(scope)} created event '#{event.name}'")

        Realtime.broadcast_change(@resource, {:created, event})
        {:ok, event}

      error ->
        error
    end
  end

  @doc """
  Updates an event's name/date/location/notes. Logs one activity entry per user-facing
  field that actually changed (`XC-10`), e.g. "Wannes changed the date of 'Dinner':
  No date yet → 13/05/2028" — old/new values go through `WeddingPlannerWeb.Format` the
  same way the UI displays them, so the log and the screen never disagree on wording.
  Broadcasts `{:updated, event}` (`XC-01`) once, after every log entry is written.
  """
  @spec update_event(Scope.t(), Event.t(), map()) ::
          {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def update_event(%Scope{} = scope, %Event{} = event, attrs) do
    changeset = Event.changeset(event, attrs)

    with {:ok, updated} <- Repo.update(changeset) do
      :ok = log_field_changes(scope, event, updated, changeset)
      Realtime.broadcast_change(@resource, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc """
  Deletes an event, logs the delete (`XC-10` — the entry still renders afterwards,
  degraded to plain text, via `WeddingPlanner.Log.EntityRef`'s `"event"` resolver) and
  broadcasts `{:deleted, id}` (`XC-01`).

  When nothing references the event (`affected_references/1 == []`) this is a single
  delete plus a single log entry, exactly as before. When something does (today, only
  `WeddingPlanner.Tasks` can), see the moduledoc's "Deletion and EVT-05" section for the
  transactional path.
  """
  @spec delete_event(Scope.t(), Event.t()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def delete_event(%Scope{} = scope, %Event{} = event) do
    if affected_references(event) == [] do
      delete_event_without_references(scope, event)
    else
      delete_event_with_references(scope, event)
    end
  end

  @doc """
  `EVT-05`: the references that would be affected by deleting `event`, one
  `%{label:, count:}` map per non-empty reference type (currently: tasks anchoring a
  deadline on it, and tasks linked to it — see `WeddingPlanner.Tasks`). `[]` when
  nothing references the event.
  """
  @spec affected_references(Event.t()) :: [%{label: String.t(), count: non_neg_integer()}]
  def affected_references(%Event{} = event) do
    :wedding_planner
    |> Application.get_env(:event_reference_providers, [])
    |> Enum.map(& &1.(event))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  EVT-04: moves `event` one position `:up` or `:down` in the manual sort order,
  swapping `sort_order` with its neighbour. A no-op at either end of the list (returns
  `:ok` without writing or logging anything).

  Race-safe per `XC-02` (last write wins, no locking, no version check): two users
  moving different events at the same time each independently swap whatever
  `sort_order` values they read: a stale read at worst re-orders relative to a move
  that already happened, never corrupts data or raises.

  Touches two rows, so this is logged as one `WeddingPlanner.Log.action/3` summary plus
  one child entry per affected event (`XC-12`), not two independent `Log.entry/3` calls.
  """
  @spec move_event(Scope.t(), Event.t(), :up | :down) :: :ok
  def move_event(%Scope{} = scope, %Event{} = event, direction) when direction in [:up, :down] do
    events = list_events()

    case neighbor(events, event, direction) do
      :boundary ->
        :ok

      {:ok, neighbor} ->
        {:ok, {moved, moved_neighbor}} =
          Log.action(
            scope,
            "#{actor(scope)} moved '#{event.name}' #{direction_word(direction)} in the event order",
            fn -> swap_and_log(scope, event, neighbor, direction) end
          )

        Realtime.broadcast_change(@resource, {:updated, moved})
        Realtime.broadcast_change(@resource, {:updated, moved_neighbor})
        :ok
    end
  end

  # -- private ---------------------------------------------------------------

  defp delete_event_without_references(scope, event) do
    with {:ok, deleted} <- Repo.delete(event) do
      {:ok, _} =
        Log.entry(scope, {:event, deleted.id}, "#{actor(scope)} deleted event '#{deleted.name}'")

      Realtime.broadcast_change(@resource, {:deleted, deleted.id})
      {:ok, deleted}
    end
  end

  # XC-41/EVT-05 (task half, DR-26 Q1): detach every task first (inside the same
  # transaction as the summary entry), *then* delete the event — deleting first would
  # hit the :restrict foreign keys on tasks.deadline_event_id/link_event_id while tasks
  # still reference it.
  defp delete_event_with_references(scope, event) do
    {:ok, {deleted, detached_tasks}} =
      Log.action(scope, "#{actor(scope)} deleted event '#{event.name}'", fn ->
        detached_tasks = WeddingPlanner.Tasks.detach_event(scope, event)
        {:ok, deleted} = Repo.delete(event)

        {:ok, _} =
          Log.entry(
            scope,
            {:event, deleted.id},
            "#{actor(scope)} deleted event '#{deleted.name}'"
          )

        {deleted, detached_tasks}
      end)

    Enum.each(detached_tasks, &Realtime.broadcast_change(:task, {:updated, &1}))
    Realtime.broadcast_change(@resource, {:deleted, deleted.id})
    {:ok, deleted}
  end

  defp next_sort_order do
    case Repo.aggregate(Event, :max, :sort_order) do
      nil -> 0
      max -> max + 1
    end
  end

  defp neighbor(events, %Event{id: id}, :up) do
    case Enum.find_index(events, &(&1.id == id)) do
      nil -> :boundary
      0 -> :boundary
      idx -> {:ok, Enum.at(events, idx - 1)}
    end
  end

  defp neighbor(events, %Event{id: id}, :down) do
    last_index = length(events) - 1

    case Enum.find_index(events, &(&1.id == id)) do
      nil -> :boundary
      ^last_index -> :boundary
      idx -> {:ok, Enum.at(events, idx + 1)}
    end
  end

  defp swap_and_log(scope, event, neighbor, direction) do
    {:ok, moved} = event |> Event.sort_order_changeset(neighbor.sort_order) |> Repo.update()

    {:ok, moved_neighbor} =
      neighbor |> Event.sort_order_changeset(event.sort_order) |> Repo.update()

    {:ok, _} =
      Log.entry(
        scope,
        {:event, moved.id},
        "#{actor(scope)} moved '#{moved.name}' #{direction_word(direction)}"
      )

    {:ok, _} =
      Log.entry(
        scope,
        {:event, moved_neighbor.id},
        "#{actor(scope)} moved '#{moved_neighbor.name}' #{direction_word(opposite(direction))} (swapped with '#{moved.name}')"
      )

    {moved, moved_neighbor}
  end

  defp direction_word(:up), do: "up"
  defp direction_word(:down), do: "down"

  defp opposite(:up), do: :down
  defp opposite(:down), do: :up

  defp log_field_changes(scope, %Event{} = before, %Event{} = updated, changeset) do
    changeset.changes
    |> Map.keys()
    |> Enum.filter(&(&1 in @loggable_fields))
    |> Enum.each(fn field ->
      old = display_value(field, Map.fetch!(before, field))
      new = display_value(field, Map.fetch!(updated, field))

      {:ok, _} =
        Log.entry(
          scope,
          {:event, updated.id},
          "#{actor(scope)} changed the #{field} of '#{before.name}': #{old} → #{new}"
        )
    end)

    :ok
  end

  defp display_value(:date, value), do: Format.date(value)
  defp display_value(_field, nil), do: "none"
  defp display_value(_field, value), do: value

  defp actor(%Scope{user: %User{display_name: name}}), do: name
end
