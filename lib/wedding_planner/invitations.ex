defmodule WeddingPlanner.Invitations do
  @moduledoc """
  Per-event invitation status for non-+1 persons and per-event opt-outs for +1s
  (`docs/modules/guests-and-events.md` `INVT-01`–`INVT-04`, `PER-13`, `PER-14`,
  `docs/03-domain-model.md` Invitation / Plus-one opt-out, `DR-37`, `DR-38`). A
  standalone context, not folded into `WeddingPlanner.Guests`, so that module's own
  moduledoc no longer has to describe this rule set.

  ## Storage (`DR-37`)

  `WeddingPlanner.Invitations.Invitation` (`invitations`: one row per non-+1 person ×
  event, `status` ∈ `:planned | :invited | :accepted | :declined`) and
  `WeddingPlanner.Invitations.PlusOneOptOut` (`plus_one_opt_outs`: one row per +1 ×
  event it has opted out of — presence alone is the signal). *Not invited* is never a
  stored value: it is the absence of an `Invitation` row, so `set_invitation_status/4`
  **deletes** the row when asked for `:not_invited` rather than writing a fifth status
  string (the column CHECK on `invitations.status` only accepts the real four).

  A +1 can never get an invitation and a non-+1 can never get an opt-out — refused here
  (`{:error, :plus_one}` / `{:error, :not_a_plus_one}`), never in the schemas, because
  the check is `WeddingPlanner.Guests.Person.plus_one?/1` on the struct already in hand.
  `persons.host_id` is immutable (`DR-32`), so this cannot race: a person that is a +1
  now was always a +1.

  Both tables' FKs are `on_delete: :restrict` — this context always deletes the rows it
  owns explicitly (`delete_for_persons/1`, `detach_event/2`), inside the caller's own
  transaction, so each removal gets its own activity entry (`XC-10`); a bare FK cascade
  would silently drop rows with none. Existence of the referenced person/event is
  checked here with a query before a write, for the same reason
  `WeddingPlanner.Guests.change_person/2` checks `group_id`'s existence itself: this
  project's SQLite adapter cannot convert a raw FK violation into a changeset error, so
  a caller handed a stale (concurrently deleted) person or event gets a clear
  `ArgumentError` instead of a raw constraint exception.

  ## Concurrency (`DR-37`)

  Status writes are **upserts** (`on_conflict: {:replace, [:status, :updated_at]}`,
  `conflict_target: [:person_id, :event_id]`) and opt-out inserts use `on_conflict:
  :nothing` — two users setting the same cell at the same instant both succeed and
  exactly one row survives, never a unique-index race (`XC-02`: last write wins, no
  locking). See `test/wedding_planner/invitations_concurrency_test.exs` (real
  connections, not the sandbox) for both.

  ## Effective status (`PER-13`, `PER-14`)

  This module never computes a +1's *effective* status itself — that is the pure
  `WeddingPlanner.Invitations.Effective`, shared with slice G4's headcount engine.
  `statuses_for_person/1` and `opted_out_event_ids/1` return **rows only** (a non-+1's
  own invitations, a +1's own opt-outs) for a caller to feed into `Effective.index/3`.

  ## Activity log (`XC-10`, `XC-11`, `DR-38`)

  Every entry — status change, opt-out, bulk child, deletion-cleanup child — is written
  against the **person** (`{:person, person_id}`); invitations and opt-outs get no
  `WeddingPlanner.Log.EntityRef` type of their own, so this history only ever shows up
  on the person's own page. Setting a status equal to the current one, or opting out an
  already-opted-out +1, is a no-op: `{:ok, ...}`, no entry, no broadcast.

  `bulk_set_invitation_status/4` follows `WeddingPlanner.Guests.bulk_update_persons/4`'s
  `XC-12` pattern exactly (mirrored, not reused, since that helper is private there):
  one `WeddingPlanner.Log.action/3` summary naming the changed count and, when the
  editable (non-+1) persons are exactly one group's members, that group
  ("Wannes set 4 people in 'Family Peeters' to invited for Reception"); a child entry
  per person whose status actually changed, worded exactly like the single-status
  entry. +1s and persons whose status does not change are **skipped silently** — a
  group "select all" routinely includes a group's +1s and already-correct cells.

  ## Deletion (`DR-38`)

  `delete_for_persons/1` is a building block only — **no transaction of its own, no
  logging, no broadcast** — for `WeddingPlanner.Guests`' person-deletion paths, which
  call it (for every id about to be deleted, host and +1s alike) inside their own
  transaction, before deleting the person rows (the `:restrict` FKs would otherwise
  block it). `deletion_counts/1` is the read-only counterpart `person_deletion_effects/1`
  /`bulk_deletion_effects/1` use to name what a deletion additionally removes.

  `detach_event/2` is `WeddingPlanner.Events`' analogue: called inside
  `WeddingPlanner.Events.delete_event_with_references/2`'s own `Log.action/3`, before
  the event row is deleted. Unlike `delete_for_persons/1`, this **does** log — one child
  entry per affected person (their own history needs to show an invitation or opt-out
  disappearing), inside the event's summary — because the event, not the person, is the
  thing being deleted; the persons themselves are untouched. `event_invitation_reference/1`
  and `event_opt_out_reference/1` are the two `EVT-05` providers
  `WeddingPlanner.Events.affected_references/1` calls once `config/config.exs` registers
  them (orchestrator-owned — see this task's report for the exact lines).

  ## PubSub (`XC-01`)

  Two resources, `:invitation` and `:plus_one_opt_out`, whole records on
  create/update, `{:deleted, id}` on delete — the same convention every other context
  follows (`WeddingPlanner.Realtime`).
  """

  import Ecto.Query

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Group
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Invitations.PlusOneOptOut
  alias WeddingPlanner.Log
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo

  @invitation_resource :invitation
  @opt_out_resource :plus_one_opt_out

  @type deletion_counts :: %{invitations: non_neg_integer(), opt_outs: non_neg_integer()}

  # -- reads -----------------------------------------------------------------------------

  @doc "Every invitation row, ordered by id."
  @spec list_invitations() :: [Invitation.t()]
  def list_invitations do
    Invitation |> order_by(asc: :id) |> Repo.all()
  end

  @doc "Every opt-out row, ordered by id."
  @spec list_opt_outs() :: [PlusOneOptOut.t()]
  def list_opt_outs do
    PlusOneOptOut |> order_by(asc: :id) |> Repo.all()
  end

  @doc """
  `person`'s own invitation rows, as `%{event_id => status}` — **rows only**, no
  `PER-13`/`PER-14` reasoning (always `%{}` for a +1, which never has rows of its own).
  Feed into `WeddingPlanner.Invitations.Effective.index/3` for the effective status.
  """
  @spec statuses_for_person(Person.t()) :: %{optional(term()) => Invitation.status()}
  def statuses_for_person(%Person{} = person) do
    Invitation
    |> where([i], i.person_id == ^person.id)
    |> select([i], {i.event_id, i.status})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  `person`'s own opt-out event ids — **rows only** (always `MapSet.new()` for a
  non-+1, which can never have one).
  """
  @spec opted_out_event_ids(Person.t()) :: MapSet.t(term())
  def opted_out_event_ids(%Person{} = person) do
    PlusOneOptOut
    |> where([o], o.person_id == ^person.id)
    |> select([o], o.event_id)
    |> Repo.all()
    |> MapSet.new()
  end

  # -- single-cell writes ------------------------------------------------------------------

  @doc """
  Sets `person`'s invitation status for `event` (`INVT-01`). `:not_invited` deletes the
  row (see the moduledoc's "Storage" section). A no-op (equal to the current status, or
  `:not_invited` with no existing row) is `{:ok, ...}` with no log entry and no
  broadcast. Refused with `{:error, :plus_one}` for a +1 (`PER-13`) — no row is written.

  Logs (`DR-38`) against the person: `"Wannes changed the invitation for 'Anna
  Peeters' to 'Dinner': invited → accepted"`, lowercase labels `not invited | planned |
  invited | accepted | declined`. Broadcasts `{:created | :updated | :deleted, ...}` on
  the `:invitation` resource, once, after the write.
  """
  @spec set_invitation_status(
          Scope.t(),
          Person.t(),
          Event.t(),
          Invitation.status() | :not_invited
        ) ::
          {:ok, Invitation.t() | nil} | {:error, :plus_one}
  def set_invitation_status(%Scope{} = scope, %Person{} = person, %Event{} = event, status) do
    if Person.plus_one?(person) do
      {:error, :plus_one}
    else
      ensure_exists!(Person, person.id, "person")
      ensure_exists!(Event, event.id, "event")
      do_set_invitation_status(scope, person, event, status)
    end
  end

  @doc """
  Sets whether `person` (a +1) has opted out of `event` (`PER-13`). Refused with
  `{:error, :not_a_plus_one}` for a non-+1 — no row is written. Allowed whatever the
  host's own status (`PER-14`: the +1's data is retained). A no-op (opting out an
  already-opted-out +1, or clearing an opt-out that does not exist) is `{:ok, ...}`
  with no log entry and no broadcast.

  Logs (`DR-38`) against the +1: `"Wannes opted '+1 of Anna Peeters' out of
  'Dinner'"` / `"Wannes removed the opt-out of '+1 of Anna Peeters' for 'Dinner'"`.
  Broadcasts `{:created | :deleted, ...}` on the `:plus_one_opt_out` resource, once,
  after the write.
  """
  @spec set_opt_out(Scope.t(), Person.t(), Event.t(), boolean()) ::
          {:ok, PlusOneOptOut.t() | nil} | {:error, :not_a_plus_one}
  def set_opt_out(%Scope{} = scope, %Person{} = person, %Event{} = event, opt_out?)
      when is_boolean(opt_out?) do
    if Person.plus_one?(person) do
      ensure_exists!(Person, person.id, "person")
      ensure_exists!(Event, event.id, "event")
      do_set_opt_out(scope, person, event, opt_out?)
    else
      {:error, :not_a_plus_one}
    end
  end

  # -- bulk (PER-04, XC-12) ---------------------------------------------------------------

  @doc """
  Sets every (non-+1) person in `persons` to `status` for `event` (`PER-04`). +1s are
  **skipped entirely** (`PER-13`: no invitations of their own) and persons already at
  `status` are **skipped silently** — see the moduledoc's "Activity log" section for the
  summary/child wording (mirrors `WeddingPlanner.Guests.bulk_update_persons/4`).
  Returns the persons actually changed.
  """
  @spec bulk_set_invitation_status(
          Scope.t(),
          [Person.t()],
          Event.t(),
          Invitation.status() | :not_invited
        ) :: {:ok, [Person.t()]}
  def bulk_set_invitation_status(%Scope{} = scope, persons, %Event{} = event, status)
      when is_list(persons) do
    ensure_exists!(Event, event.id, "event")

    non_plus_ones = Enum.reject(persons, &Person.plus_one?/1)
    current = current_statuses_map(Enum.map(non_plus_ones, & &1.id), event.id)

    changing =
      Enum.filter(non_plus_ones, fn person ->
        Map.get(current, person.id, :not_invited) != status
      end)

    summary = bulk_summary(scope, non_plus_ones, status, event, length(changing))

    {:ok, {changed, events}} =
      Log.action(scope, summary, fn ->
        results =
          Enum.map(changing, fn person ->
            old_status = Map.get(current, person.id, :not_invited)
            event_tuple = apply_status_write(person.id, event.id, status)
            log_status_change(scope, person, event, old_status, status)
            {person, event_tuple}
          end)

        {Enum.map(results, &elem(&1, 0)), Enum.map(results, &elem(&1, 1))}
      end)

    Enum.each(events, &broadcast_invitation_event/1)
    {:ok, changed}
  end

  @doc """
  A dry-run preview of `bulk_set_invitation_status/4` (task 45's confirmation dialog):
  how many of `persons` would actually change, how many of those are currently
  *accepted*/*declined* (an RSVP the bulk would overwrite), and how many +1s in
  `persons` are skipped outright.
  """
  @spec bulk_status_preview([Person.t()], Event.t(), Invitation.status() | :not_invited) :: %{
          changing: non_neg_integer(),
          overwriting_rsvps: non_neg_integer(),
          skipped_plus_ones: non_neg_integer()
        }
  def bulk_status_preview(persons, %Event{} = event, status) when is_list(persons) do
    {plus_ones, non_plus_ones} = Enum.split_with(persons, &Person.plus_one?/1)
    current = current_statuses_map(Enum.map(non_plus_ones, & &1.id), event.id)

    changing_statuses =
      non_plus_ones
      |> Enum.map(&Map.get(current, &1.id, :not_invited))
      |> Enum.zip(non_plus_ones)
      |> Enum.filter(fn {old_status, _person} -> old_status != status end)

    %{
      changing: length(changing_statuses),
      overwriting_rsvps:
        Enum.count(changing_statuses, fn {old_status, _person} ->
          old_status in [:accepted, :declined]
        end),
      skipped_plus_ones: length(plus_ones)
    }
  end

  # -- EVT-05 providers --------------------------------------------------------------------

  @doc """
  `EVT-05` provider: how many invitations reference `event`, or `nil` if none do.
  Registered via `config :wedding_planner, event_reference_providers:` (orchestrator-
  owned — hand-back lines in this task's report).
  """
  @spec event_invitation_reference(Event.t()) :: %{label: String.t(), count: pos_integer()} | nil
  def event_invitation_reference(%Event{} = event) do
    case count_referencing(Invitation, event.id) do
      0 -> nil
      n -> %{label: "#{n} #{pluralize(n, "invitation")}", count: n}
    end
  end

  @doc """
  `EVT-05` provider: how many +1 opt-outs reference `event`, or `nil` if none do.
  Registered via `config :wedding_planner, event_reference_providers:` (orchestrator-
  owned — hand-back lines in this task's report).
  """
  @spec event_opt_out_reference(Event.t()) :: %{label: String.t(), count: pos_integer()} | nil
  def event_opt_out_reference(%Event{} = event) do
    case count_referencing(PlusOneOptOut, event.id) do
      0 -> nil
      n -> %{label: "#{n} #{pluralize(n, "+1 opt-out")}", count: n}
    end
  end

  # -- deletion (DR-38) --------------------------------------------------------------------

  @doc """
  Removes every invitation/opt-out row anchored on `event` (`EVT-05`) — one child log
  entry per affected person, worded against the person whose row disappeared. **Must be
  called inside the enclosing `WeddingPlanner.Log.action/3`** — like
  `WeddingPlanner.Tasks.detach_event/2`, this starts no transaction of its own and does
  not broadcast; the caller (`WeddingPlanner.Events.delete_event_with_references/2`)
  broadcasts `{:deleted, id}` for each returned row, on the right resource, once the
  transaction commits.
  """
  @spec detach_event(Scope.t(), Event.t()) :: [Invitation.t() | PlusOneOptOut.t()]
  def detach_event(%Scope{} = scope, %Event{} = event) do
    invitations =
      Invitation
      |> where([i], i.event_id == ^event.id)
      |> preload(:person)
      |> Repo.all()

    opt_outs =
      PlusOneOptOut
      |> where([o], o.event_id == ^event.id)
      |> Repo.all()
      |> Repo.preload(person: :host)

    deleted_invitations = Enum.map(invitations, &detach_invitation(scope, &1, event))
    deleted_opt_outs = Enum.map(opt_outs, &detach_opt_out(scope, &1, event))

    deleted_invitations ++ deleted_opt_outs
  end

  @doc """
  Removes every invitation/opt-out row for any person id in `person_ids` — a building
  block only: **no transaction, no logging, no broadcast**. `WeddingPlanner.Guests`
  calls this for every id about to be deleted (host and +1s alike), inside its own
  transaction, before deleting the person rows themselves (the `:restrict` FKs would
  otherwise block it).
  """
  @spec delete_for_persons([term()]) :: deletion_counts()
  def delete_for_persons(person_ids) when is_list(person_ids) do
    {invitations, _} = Invitation |> where([i], i.person_id in ^person_ids) |> Repo.delete_all()

    {opt_outs, _} =
      PlusOneOptOut |> where([o], o.person_id in ^person_ids) |> Repo.delete_all()

    %{invitations: invitations, opt_outs: opt_outs}
  end

  @doc """
  Read-only counterpart of `delete_for_persons/1`: how many invitation/opt-out rows
  exist for any person id in `person_ids` — for
  `WeddingPlanner.Guests.person_deletion_effects/1`/`bulk_deletion_effects/1` to name
  what a person deletion additionally removes.
  """
  @spec deletion_counts([term()]) :: deletion_counts()
  def deletion_counts(person_ids) when is_list(person_ids) do
    invitations = Invitation |> where([i], i.person_id in ^person_ids) |> Repo.aggregate(:count)
    opt_outs = PlusOneOptOut |> where([o], o.person_id in ^person_ids) |> Repo.aggregate(:count)
    %{invitations: invitations, opt_outs: opt_outs}
  end

  # -- private: single-cell writes ---------------------------------------------------------

  defp do_set_invitation_status(scope, person, event, status) do
    existing = get_invitation(person.id, event.id)
    old_status = if existing, do: existing.status, else: :not_invited

    if old_status == status do
      {:ok, existing}
    else
      event_tuple = apply_status_write(person.id, event.id, status)
      log_status_change(scope, person, event, old_status, status)
      broadcast_invitation_event(event_tuple)

      case event_tuple do
        {:deleted, _id} -> {:ok, nil}
        {_kind, invitation} -> {:ok, invitation}
      end
    end
  end

  defp do_set_opt_out(scope, %Person{} = person, %Event{} = event, true) do
    person = Repo.preload(person, :host)

    {:ok, inserted} =
      %PlusOneOptOut{person_id: person.id, event_id: event.id}
      |> PlusOneOptOut.changeset()
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:person_id, :event_id])

    case inserted.id do
      nil ->
        # Lost the race to a concurrent writer (`on_conflict: :nothing`) — the row
        # exists, but this call did not create it, so it neither logs nor broadcasts.
        {:ok, get_opt_out(person.id, event.id)}

      _id ->
        log_opt_out(scope, person, event, :opted_out)
        Realtime.broadcast_change(@opt_out_resource, {:created, inserted})
        {:ok, inserted}
    end
  end

  defp do_set_opt_out(scope, %Person{} = person, %Event{} = event, false) do
    case get_opt_out(person.id, event.id) do
      nil ->
        {:ok, nil}

      opt_out ->
        person = Repo.preload(person, :host)
        {:ok, deleted} = Repo.delete(opt_out)
        log_opt_out(scope, person, event, :removed)
        Realtime.broadcast_change(@opt_out_resource, {:deleted, deleted.id})
        {:ok, nil}
    end
  end

  # Performs the actual row write for one person/event/status combination and reports
  # what happened, for both the single-cell and bulk callers to log/broadcast from —
  # `nil` is never returned to a caller that already knows the status is changing.
  defp apply_status_write(person_id, event_id, :not_invited) do
    case get_invitation(person_id, event_id) do
      nil ->
        nil

      invitation ->
        {:ok, deleted} = Repo.delete(invitation)
        {:deleted, deleted.id}
    end
  end

  defp apply_status_write(person_id, event_id, status) do
    current = get_invitation(person_id, event_id)
    {:ok, upserted} = upsert_invitation(person_id, event_id, status)
    if current, do: {:updated, upserted}, else: {:created, upserted}
  end

  defp upsert_invitation(person_id, event_id, status) do
    %Invitation{person_id: person_id, event_id: event_id}
    |> Invitation.changeset(%{status: status})
    |> Repo.insert(
      on_conflict: {:replace, [:status, :updated_at]},
      conflict_target: [:person_id, :event_id],
      returning: true
    )
  end

  defp broadcast_invitation_event(nil), do: :ok

  defp broadcast_invitation_event({:deleted, id}),
    do: Realtime.broadcast_change(@invitation_resource, {:deleted, id})

  defp broadcast_invitation_event({kind, invitation}) when kind in [:created, :updated],
    do: Realtime.broadcast_change(@invitation_resource, {kind, invitation})

  defp get_invitation(person_id, event_id) do
    Repo.get_by(Invitation, person_id: person_id, event_id: event_id)
  end

  defp get_opt_out(person_id, event_id) do
    Repo.get_by(PlusOneOptOut, person_id: person_id, event_id: event_id)
  end

  defp current_statuses_map(person_ids, event_id) do
    Invitation
    |> where([i], i.event_id == ^event_id and i.person_id in ^person_ids)
    |> select([i], {i.person_id, i.status})
    |> Repo.all()
    |> Map.new()
  end

  # -- private: event deletion --------------------------------------------------------------

  defp detach_invitation(scope, %Invitation{} = invitation, %Event{} = event) do
    {:ok, deleted} = Repo.delete(invitation)

    {:ok, _} =
      Log.entry(
        scope,
        {:person, deleted.person_id},
        "#{actor(scope)} removed the invitation for '#{Person.display_name(invitation.person)}' " <>
          "to '#{event.name}' (#{status_label(invitation.status)}; event deleted)"
      )

    deleted
  end

  defp detach_opt_out(scope, %PlusOneOptOut{} = opt_out, %Event{} = event) do
    {:ok, deleted} = Repo.delete(opt_out)

    {:ok, _} =
      Log.entry(
        scope,
        {:person, deleted.person_id},
        "#{actor(scope)} removed the opt-out of '#{Person.display_name(opt_out.person)}' " <>
          "for '#{event.name}' (event deleted)"
      )

    deleted
  end

  defp count_referencing(queryable, event_id) do
    queryable |> where([r], r.event_id == ^event_id) |> Repo.aggregate(:count)
  end

  # -- private: logging --------------------------------------------------------------------

  defp log_status_change(scope, %Person{} = person, %Event{} = event, old_status, new_status) do
    {:ok, _} =
      Log.entry(
        scope,
        {:person, person.id},
        "#{actor(scope)} changed the invitation for '#{Person.display_name(person)}' to " <>
          "'#{event.name}': #{status_label(old_status)} → #{status_label(new_status)}"
      )

    :ok
  end

  defp log_opt_out(scope, %Person{} = person, %Event{} = event, :opted_out) do
    {:ok, _} =
      Log.entry(
        scope,
        {:person, person.id},
        "#{actor(scope)} opted '#{Person.display_name(person)}' out of '#{event.name}'"
      )

    :ok
  end

  defp log_opt_out(scope, %Person{} = person, %Event{} = event, :removed) do
    {:ok, _} =
      Log.entry(
        scope,
        {:person, person.id},
        "#{actor(scope)} removed the opt-out of '#{Person.display_name(person)}' for '#{event.name}'"
      )

    :ok
  end

  defp status_label(:not_invited), do: "not invited"
  defp status_label(:planned), do: "planned"
  defp status_label(:invited), do: "invited"
  defp status_label(:accepted), do: "accepted"
  defp status_label(:declined), do: "declined"

  defp pluralize(1, word), do: word
  defp pluralize(_n, word), do: word <> "s"

  # -- private: bulk summary (mirrors WeddingPlanner.Guests.bulk_update_persons/4) --------

  defp bulk_summary(scope, persons, status, event, changed_count) do
    base = "#{actor(scope)} set #{changed_count} #{pluralize_person(changed_count)}"

    scope_phrase =
      case sole_group(persons) do
        {:ok, group} -> " in '#{group.name}'"
        :error -> ""
      end

    "#{base}#{scope_phrase} to #{status_label(status)} for #{event.name}"
  end

  defp pluralize_person(1), do: "person"
  defp pluralize_person(_n), do: "people"

  defp sole_group([]), do: :error

  defp sole_group(persons) do
    case persons |> Enum.map(& &1.group_id) |> Enum.uniq() do
      [group_id] when not is_nil(group_id) ->
        case Repo.get(Group, group_id) do
          nil ->
            :error

          group ->
            member_count = Person |> where([p], p.group_id == ^group_id) |> Repo.aggregate(:count)
            if member_count == length(persons), do: {:ok, group}, else: :error
        end

      _ ->
        :error
    end
  end

  # -- private: existence (see moduledoc's "Storage" section) ------------------------------

  defp ensure_exists!(queryable, id, label) do
    if Repo.exists?(where(queryable, [q], q.id == ^id)) do
      :ok
    else
      raise ArgumentError, "#{label} #{inspect(id)} does not exist"
    end
  end

  defp actor(%Scope{user: %User{display_name: name}}), do: name
end
