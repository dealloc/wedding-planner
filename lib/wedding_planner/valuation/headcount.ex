defmodule WeddingPlanner.Valuation.Headcount do
  @moduledoc """
  The headcount engine (`docs/modules/headcount.md`): evaluates a headcount preset
  against a snapshot, live, every time. Nothing is ever stored (`HC-01`, `D-03`); the
  same snapshot and preset always give the same counts, and a what-if is simply this
  function over `WeddingPlanner.Valuation.Snapshot.apply/2`'s result. Pure and
  UI-independent (`NFR-41`): no database, no web layer.

  ## Who is counted for an event (`DR-48`)

    1. **Candidates.** A person's *effective* status for the event comes from
       `WeddingPlanner.Invitations.Effective` (the single implementation of `PER-13`/
       `PER-14`, `DR-37`): their own invitation, or for a +1 its host's status unless the
       +1 opted out. Only *planned*, *invited* and *accepted* make a candidate. *Declined*
       is never counted, whatever the preset says (`HC-04`), and *not invited* is never
       counted either — even by a preset whose status criterion is empty, because a
       preset is a filter over invitations (glossary; `INVT-01`, `H4`).
    2. **Effective certainty**, in this order: a *possible* +1 is *uncertain*, always —
       even when its host accepted (`HC-05`'s cap, `D-17`); otherwise an *accepted*
       effective status makes the person *certain* (`HC-04`; for a *confirmed* +1 its
       effective status is its host's, so this is "HC-04 through the host"); otherwise the
       certainty `WeddingPlanner.Guests.PlusOne.certainty/2` gives (the person's own, or
       the host's for a confirmed +1, `PER-15`).
    3. **The other criteria** read the want tier and group through
       `WeddingPlanner.Guests.PlusOne` — a +1 is evaluated under its host's (`HC-05`,
       `DR-32`; a +1's own want tier and certainty columns are never read) — the person's
       **own** age category, and the effective status.
    4. A candidate is counted when it passes every **non-empty** criterion of the preset;
       an empty criterion does not restrict (`HC-02`).

  Counts are split into adults and children by each counted person's own age category;
  `total = adults + children`.

  For `:all_events` (`HC-03`) the result is the number of **distinct** persons counted
  for at least one event in `snapshot.events`, split the same way: a person counted for
  three events contributes 1.

  Everything is read from the snapshot's `persons`, `invitations` and
  `plus_one_opt_outs` (and `events`, for `:all_events`), joined by id with `==`
  semantics — ids may be `make_ref/0` values in a what-if. A +1 whose host is absent
  from `persons` is a caller bug (a what-if that deleted a host without its +1s,
  `PER-16`) and raises.

  The offer engine (`WeddingPlanner.Valuation.Offer`, `CST-31`) obtains every
  per-person count through this function and never recomputes one.
  """

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Guests.PlusOne
  alias WeddingPlanner.Invitations.Effective
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot

  @typedoc "Headcount for one event (or distinct persons across all events): `total = adults + children`."
  @type counts :: %{
          adults: non_neg_integer(),
          children: non_neg_integer(),
          total: non_neg_integer()
        }

  # DR-48: the only effective statuses that make a person a candidate at all.
  @candidate_statuses [:planned, :invited, :accepted]

  @doc """
  Evaluates `preset` for `event` (an event from `snapshot.events`), or for
  `:all_events` (`HC-03`), returning adults, children and total. See the moduledoc for
  the rules.
  """
  @spec evaluate(Snapshot.t(), Preset.t(), Event.t() | :all_events) :: counts()
  def evaluate(%Snapshot{} = snapshot, %Preset{} = preset, :all_events) do
    context = context(snapshot)

    snapshot.events
    |> Enum.flat_map(&counted_persons(context, preset, &1.id))
    |> Enum.uniq_by(& &1.id)
    |> tally()
  end

  def evaluate(%Snapshot{} = snapshot, %Preset{} = preset, %Event{id: event_id}) do
    snapshot
    |> context()
    |> counted_persons(preset, event_id)
    |> tally()
  end

  # Built once per `evaluate/3` call (DR-48), never per person.
  defp context(%Snapshot{} = snapshot) do
    %{
      persons: snapshot.persons,
      persons_by_id: Map.new(snapshot.persons, &{&1.id, &1}),
      lookup: Effective.index(snapshot.persons, snapshot.invitations, snapshot.plus_one_opt_outs)
    }
  end

  defp counted_persons(context, preset, event_id) do
    Enum.filter(context.persons, &counted?(context, preset, &1, event_id))
  end

  defp counted?(context, preset, person, event_id) do
    status = Effective.status(context.lookup, person, event_id)

    if status in @candidate_statuses do
      host = host_of(context, person)

      allowed?(preset.invitation_statuses, status) and
        allowed?(preset.certainties, effective_certainty(person, host, status)) and
        allowed?(preset.want_tiers, PlusOne.want_tier(person, host)) and
        allowed?(preset.age_categories, person.age_category) and
        allowed?(preset.group_ids, PlusOne.group_id(person, host))
    else
      false
    end
  end

  # The `PlusOne` functions ignore the host argument for a non-+1, so a non-+1 is its own.
  defp host_of(_context, %Person{host_id: nil} = person), do: person
  defp host_of(context, %Person{host_id: host_id}), do: Map.fetch!(context.persons_by_id, host_id)

  # DR-48's order: HC-05's cap first, then HC-04, then PER-15.
  defp effective_certainty(%Person{host_id: host_id, plus_one_status: :possible}, _host, _status)
       when not is_nil(host_id),
       do: :uncertain

  defp effective_certainty(%Person{}, _host, :accepted), do: :certain
  defp effective_certainty(%Person{} = person, host, _status), do: PlusOne.certainty(person, host)

  # HC-02: an empty criterion does not restrict.
  defp allowed?(allowed, value), do: MapSet.size(allowed) == 0 or MapSet.member?(allowed, value)

  defp tally(persons) do
    Enum.reduce(persons, %{adults: 0, children: 0, total: 0}, fn person, acc ->
      key =
        case person.age_category do
          :adult -> :adults
          :child -> :children
        end

      acc |> Map.update!(key, &(&1 + 1)) |> Map.update!(:total, &(&1 + 1))
    end)
  end
end
