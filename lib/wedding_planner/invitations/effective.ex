defmodule WeddingPlanner.Invitations.Effective do
  @moduledoc """
  The single, pure implementation of `PER-13`/`PER-14`
  (`docs/modules/guests-and-events.md`, `DR-37`): turning a person's own invitation row
  (or lack of one) and, for a +1, its host's own effective status plus its own
  opt-out, into one *effective* status per person × event.

  No Ecto, no `Repo`, no database access at all — this module is a function of data
  already in hand, so both `WeddingPlanner.Invitations` (over rows freshly loaded from
  the database) and slice G4's headcount engine (over a
  `WeddingPlanner.Valuation.Snapshot`, including a what-if `Snapshot.apply/2` result)
  call the exact same code. `index/3` accepts either: real `Invitation`/`PlusOneOptOut`
  structs and `WeddingPlanner.Guests.Person` structs, or the equivalent maps a snapshot
  collection holds — only `:id`/`:person_id`/`:event_id`/`:status`/`:host_id` are ever
  read.

  Every id is compared with `==` and never assumed to be an integer: a snapshot
  what-if's hypothetical rows carry `make_ref/0` ids (see
  `WeddingPlanner.Valuation.Snapshot`'s moduledoc).

  ## The rule

  For a non-+1 person: its own row's status, or `:not_invited` if it has none.

  For a +1: let `h` be its **host's own effective status** (computed the same way,
  recursively — a host is never itself a +1, `PER-10`, so this never recurses more than
  once in practice).

    * `h == :not_invited` -> `:not_invited` (PER-14: not invited propagates first)
    * `h == :declined` -> `:declined` (PER-14: a decline propagates regardless of any
      opt-out)
    * the +1 has opted out of this event -> `:declined` (PER-13)
    * otherwise -> `h` (PER-13: attends exactly when the host does)
  """

  alias WeddingPlanner.Guests.Person

  @type status :: :not_invited | WeddingPlanner.Invitations.Invitation.status()
  @type event_id :: term()

  @opaque lookup :: %{
            statuses: %{optional({term(), event_id()}) => status()},
            opted_out: MapSet.t({term(), event_id()}),
            persons_by_id: %{optional(term()) => map()}
          }

  @doc """
  Builds the lookup `status/3` and `opted_out?/3` read from `persons` (any mix of hosts
  and +1s), `invitations` (rows/maps with `:person_id`, `:event_id`, `:status`) and
  `opt_outs` (rows/maps with `:person_id`, `:event_id`).

  ## Examples

      iex> alias WeddingPlanner.Invitations.Effective
      iex> anna = %{id: 1, host_id: nil}
      iex> lookup = Effective.index([anna], [%{person_id: 1, event_id: 10, status: :accepted}], [])
      iex> Effective.status(lookup, anna, 10)
      :accepted
  """
  @spec index([map()], [map()], [map()]) :: lookup()
  def index(persons, invitations, opt_outs)
      when is_list(persons) and is_list(invitations) and is_list(opt_outs) do
    %{
      statuses: Map.new(invitations, &{{&1.person_id, &1.event_id}, &1.status}),
      opted_out: MapSet.new(opt_outs, &{&1.person_id, &1.event_id}),
      persons_by_id: Map.new(persons, &{&1.id, &1})
    }
  end

  @doc """
  `person`'s effective status for `event_id` (see the moduledoc's rule).

  ## Examples

  G1 — host accepted, +1 with no opt-out attends:

      iex> alias WeddingPlanner.Invitations.Effective
      iex> anna = %{id: 1, host_id: nil}
      iex> plus_one = %{id: 2, host_id: 1}
      iex> lookup = Effective.index([anna, plus_one], [%{person_id: 1, event_id: 10, status: :accepted}], [])
      iex> Effective.status(lookup, plus_one, 10)
      :accepted

  G2 — G1, plus the +1 opts out:

      iex> alias WeddingPlanner.Invitations.Effective
      iex> anna = %{id: 1, host_id: nil}
      iex> plus_one = %{id: 2, host_id: 1}
      iex> invitations = [%{person_id: 1, event_id: 10, status: :accepted}]
      iex> opt_outs = [%{person_id: 2, event_id: 10}]
      iex> lookup = Effective.index([anna, plus_one], invitations, opt_outs)
      iex> {Effective.status(lookup, anna, 10), Effective.status(lookup, plus_one, 10)}
      {:accepted, :declined}

  G3 — host declined, +1 declined too even with no opt-out:

      iex> alias WeddingPlanner.Invitations.Effective
      iex> anna = %{id: 1, host_id: nil}
      iex> plus_one = %{id: 2, host_id: 1}
      iex> lookup = Effective.index([anna, plus_one], [%{person_id: 1, event_id: 10, status: :declined}], [])
      iex> Effective.status(lookup, plus_one, 10)
      :declined

  Not invited: a host with no row propagates `:not_invited` to the +1 regardless of an
  opt-out (`PER-14` retains the opt-out's data, but it never turns a not-invited +1
  into a *declined* one):

      iex> alias WeddingPlanner.Invitations.Effective
      iex> anna = %{id: 1, host_id: nil}
      iex> plus_one = %{id: 2, host_id: 1}
      iex> lookup = Effective.index([anna, plus_one], [], [%{person_id: 2, event_id: 10}])
      iex> Effective.status(lookup, plus_one, 10)
      :not_invited
  """
  @spec status(lookup(), Person.t() | map(), event_id()) :: status()
  def status(%{} = lookup, %{host_id: nil, id: id}, event_id) do
    Map.get(lookup.statuses, {id, event_id}, :not_invited)
  end

  def status(%{} = lookup, %{host_id: host_id, id: id}, event_id) when not is_nil(host_id) do
    host = Map.fetch!(lookup.persons_by_id, host_id)
    host_status = status(lookup, host, event_id)

    cond do
      host_status == :not_invited -> :not_invited
      host_status == :declined -> :declined
      opted_out?(lookup, %{id: id}, event_id) -> :declined
      true -> host_status
    end
  end

  @doc """
  `true` iff `person` (a +1) has its own opt-out row for `event_id` — regardless of
  whether that opt-out is currently in effect (a host who is not invited already makes
  the +1 `:not_invited`, but the opt-out row itself is retained, `PER-14`).

  ## Examples

      iex> alias WeddingPlanner.Invitations.Effective
      iex> lookup = Effective.index([], [], [%{person_id: 2, event_id: 10}])
      iex> Effective.opted_out?(lookup, %{id: 2}, 10)
      true
      iex> Effective.opted_out?(lookup, %{id: 2}, 99)
      false
  """
  @spec opted_out?(lookup(), Person.t() | map(), event_id()) :: boolean()
  def opted_out?(%{} = lookup, %{id: id}, event_id) do
    MapSet.member?(lookup.opted_out, {id, event_id})
  end
end
