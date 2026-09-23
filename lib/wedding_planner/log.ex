defmodule WeddingPlanner.Log do
  @moduledoc """
  Write-through activity log service (`docs/04-cross-cutting.md` `XC-10` through
  `XC-13`). Every create, update and delete of domain data MUST produce an entry through
  this module — it is deliberately built before the first domain slice so nothing gets
  retrofitted later.

      Log.entry(scope, {:invoice, invoice.id}, "Wannes marked invoice 'Venue deposit' as paid")

      Log.action(scope, "Wannes set 4 people in 'Family Peeters' to invited for Reception", fn ->
        for person <- people, do: Log.entry(scope, {:person, person.id}, "...")
      end)

  `XC-13`: the log is read-only. This module exposes no update or delete function, and
  never will — it is not an undo mechanism.

  ## Live updates (`XC-01`)

  Every entry this module writes is broadcast via `WeddingPlanner.Realtime`, resource
  atom `:activity_entry`, event `{:created, entry}` — subscribe with
  `Realtime.subscribe(:activity_entry)` (or `subscribe(:activity_entry, entry_id)` for
  one entry's own topic). Per `DR-21` there is no "this changed" indicator of any kind;
  the broadcast just carries data, same as every other resource on this convention.

  Timing matters more here than for most resources, because `action/3` writes several
  rows in one transaction:

    * `entry/3` called on its own (no surrounding `action/3`) broadcasts immediately
      after its single insert succeeds — that insert is its own implicit transaction, so
      "after the insert" and "after commit" are the same moment.
    * `entry/3` calls made **inside** an `action/3` callback are queued, not broadcast
      immediately. Once `action/3`'s transaction **commits**, the queued entries are
      broadcast in write order: the summary first, then each child. If the transaction
      rolls back (the callback raises, or returns `{:error, _}` via `Repo.rollback/1`),
      the queue is discarded and nothing is broadcast — a reader must never see a
      broadcast for a row that turned out not to exist.
    * **Known limitation:** `entry/3` called inside a caller's *own* `Repo.transaction`
      (i.e. not via `action/3`) still broadcasts immediately, before that surrounding
      transaction commits — there is no generic way for this module to hook an arbitrary
      caller's transaction lifecycle. Use `action/3` for any multi-write transactional
      unit that logs; it is the only combinator that gets this right.
  """

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Log.EntityRef
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo

  @type entity_ref :: {type :: atom() | String.t(), id :: term()}

  @parent_key {__MODULE__, :current_summary_id}
  @queue_key {__MODULE__, :pending_broadcasts}

  @doc """
  Records a single activity entry for `entity` (`XC-10`).

  `entity` is a `{type, id}` pair, e.g. `{:invoice, invoice.id}`. `description` is the
  full human-readable sentence, including a transition's old and new value where that
  applies ("invited → accepted") — this module stores it verbatim, it does not model
  transitions specially.

  If called from inside a `action/3` callback, the resulting entry's `parent_id` is
  automatically set to that action's summary entry (`XC-12`) — the caller does not pass
  it explicitly.
  """
  @spec entry(Scope.t(), entity_ref(), String.t()) ::
          {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def entry(%Scope{user: %User{id: user_id}}, {type, id}, description)
      when is_binary(description) do
    %Entry{user_id: user_id, parent_id: current_summary_id()}
    |> Entry.entry_changeset(%{
      entity_type: to_string(type),
      entity_id: id,
      description: description
    })
    |> write()
  end

  @doc """
  Runs `fun` (arity 0) inside a transaction, writes one summarising entry for `summary`
  first, then runs `fun`. Every entry written by `entry/3` (directly or transitively)
  while `fun` runs is automatically associated with the summary via `parent_id`
  (`XC-12`).

  If `fun` raises or the transaction is otherwise aborted, the summary entry and every
  child written so far are rolled back together — the bulk action is all-or-nothing.

  Returns `{:ok, fun.()'s return value}` on success. `fun`'s return value is the
  transaction's value, mirroring `Repo.transaction/1`; the summary entry itself is
  already persisted and does not need to be threaded back out.
  """
  @spec action(Scope.t(), String.t(), (-> result)) :: {:ok, result} | {:error, term()}
        when result: term()
  def action(%Scope{user: %User{id: user_id}}, summary, fun)
      when is_binary(summary) and is_function(fun, 0) do
    # Only the outermost action call owns the broadcast queue: a nested action (not
    # exercised today, but not forbidden either) shares its physical DB transaction with
    # the outer one, so only the outer commit is the moment that matters.
    outermost? = is_nil(Process.get(@queue_key))
    if outermost?, do: Process.put(@queue_key, [])

    try do
      result =
        Repo.transaction(fn ->
          {:ok, parent} =
            %Entry{user_id: user_id}
            |> Entry.summary_changeset(%{description: summary})
            |> write()

          previous_summary_id = current_summary_id()
          Process.put(@parent_key, parent.id)

          try do
            fun.()
          after
            restore_summary_id(previous_summary_id)
          end
        end)

      if outermost? do
        pending = Process.delete(@queue_key) || []
        if match?({:ok, _}, result), do: Enum.each(pending, &broadcast/1)
      end

      result
    rescue
      exception ->
        if outermost?, do: Process.delete(@queue_key)
        reraise exception, __STACKTRACE__
    end
  end

  @doc """
  Resolves an entry's entity reference to something renderable (`XC-10`): a navigable
  link, plain text, or `nil` for a summarising entry, which has no entity of its own.
  See `WeddingPlanner.Log.EntityRef` for how a type becomes navigable.
  """
  @spec resolve(Entry.t()) :: EntityRef.resolved() | nil
  def resolve(%Entry{entity_type: nil}), do: nil

  def resolve(%Entry{entity_type: type, entity_id: id}) do
    EntityRef.resolve(type, id)
  end

  defp current_summary_id, do: Process.get(@parent_key)

  defp restore_summary_id(nil), do: Process.delete(@parent_key)
  defp restore_summary_id(id), do: Process.put(@parent_key, id)

  # Single insertion point for every entry this module writes (plain entries and
  # summarising entries alike). Inside an action/3 transaction the entry is queued
  # instead of broadcast immediately — see the moduledoc's "Live updates" section for
  # why (a reader must never see a broadcast for a row that might still roll back).
  defp write(changeset) do
    case Repo.insert(changeset) do
      {:ok, entry} ->
        case Process.get(@queue_key) do
          nil -> broadcast(entry)
          queue -> Process.put(@queue_key, queue ++ [entry])
        end

        {:ok, entry}

      error ->
        error
    end
  end

  defp broadcast(%Entry{} = entry) do
    Realtime.broadcast_change(:activity_entry, {:created, entry})
  end
end
