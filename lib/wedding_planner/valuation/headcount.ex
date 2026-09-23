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

  ## Who, and why: `counted/3` and `explain/3` (`NFR-32`, `HC-08`, `DR-55`)

  Every computed number, headcount included, must be traceable to its inputs in at most
  one interaction (`NFR-32`). Two functions expose the evaluation behind a count:

    * `counted/3` — **who** is counted. For an event: each counted person with the
      effective status and effective certainty the engine used, in `snapshot.persons`
      order. For `:all_events`: each distinct person once, with the ids of the events
      (in `snapshot.events` order) they are counted for.
    * `explain/3` — the same count as a `WeddingPlanner.Valuation.Formula` of counts
      (never money), which `WeddingPlannerWeb.FormulaPresenter` renders like any other.
      Its first step always names the preset used (`HC-08`). For an event, one step
      follows per effective status with at least one counted person (accepted, invited,
      planned — each "N adults + N children"); for `:all_events`, one step per event with
      that event's total, then — only when some person is counted for more than one
      event — the overlap that `HC-03`'s de-duplication removes.

  One private function decides, per person × event, whether a person is counted and
  under which status and certainty. `counted/3` is its only caller, and `evaluate/3` and
  `explain/3` are both computed from `counted/3`'s result, so the three can never
  disagree (`DR-55`).
  """

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Guests.PlusOne
  alias WeddingPlanner.Invitations.Effective
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Formula.Step
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot

  @typedoc "Headcount for one event (or distinct persons across all events): `total = adults + children`."
  @type counts :: %{
          adults: non_neg_integer(),
          children: non_neg_integer(),
          total: non_neg_integer()
        }

  @typedoc "An effective status that makes a person a candidate (`DR-48`)."
  @type counted_status :: :planned | :invited | :accepted

  @typedoc """
  One person counted for an event: the effective status and effective certainty
  (`HC-04`, `HC-05`) the engine evaluated the preset against.
  """
  @type counted_person :: %{
          person: Person.t(),
          status: counted_status(),
          certainty: Preset.certainty()
        }

  @typedoc "One distinct person counted for at least one event, with those events' ids."
  @type counted_across :: %{person: Person.t(), event_ids: [term(), ...]}

  # DR-48: the only effective statuses that make a person a candidate at all.
  @candidate_statuses [:planned, :invited, :accepted]

  # DR-55: explain/3's per-status steps, in this order.
  @status_steps [accepted: "Accepted", invited: "Invited", planned: "Planned"]

  @doc """
  Evaluates `preset` for `event` (an event from `snapshot.events`), or for
  `:all_events` (`HC-03`), returning adults, children and total. See the moduledoc for
  the rules.

  This is exactly the tally of `counted/3` for the same arguments.
  """
  @spec evaluate(Snapshot.t(), Preset.t(), Event.t() | :all_events) :: counts()
  def evaluate(%Snapshot{} = snapshot, %Preset{} = preset, target) do
    snapshot |> counted(preset, target) |> tally()
  end

  @doc """
  Who `preset` counts for `event`, or for `:all_events` (`NFR-32`, `DR-55`).

  For an event: `[%{person: person, status: status, certainty: certainty}]`, one entry
  per counted person in `snapshot.persons` order, carrying the **effective** status and
  **effective** certainty the preset was evaluated against (never the stored certainty).

  For `:all_events`: `[%{person: person, event_ids: ids}]`, each distinct person counted
  for at least one event in `snapshot.events` once (`HC-03`), in `snapshot.persons`
  order, with the ids of those events in `snapshot.events` order.
  """
  @spec counted(Snapshot.t(), Preset.t(), Event.t()) :: [counted_person()]
  @spec counted(Snapshot.t(), Preset.t(), :all_events) :: [counted_across()]
  def counted(%Snapshot{} = snapshot, %Preset{} = preset, :all_events) do
    context = context(snapshot)
    event_ids = Enum.map(snapshot.events, & &1.id)

    for person <- context.persons,
        ids <- [for(id <- event_ids, decide(context, preset, person, id) != nil, do: id)],
        ids != [] do
      %{person: person, event_ids: ids}
    end
  end

  def counted(%Snapshot{} = snapshot, %Preset{} = preset, %Event{id: event_id}) do
    context = context(snapshot)

    for person <- context.persons,
        {status, certainty} <- [decide(context, preset, person, event_id)] do
      %{person: person, status: status, certainty: certainty}
    end
  end

  @doc """
  The count `evaluate/3` gives, as a `WeddingPlanner.Valuation.Formula` of counts
  (`NFR-32`, `HC-08`, `DR-55`).

  For an event: label `"Headcount"`; steps are the preset used
  (`{:preset, preset.name}`, always), then one step per effective status with at least
  one counted person, in the order accepted, invited, planned —
  `["Accepted — ", {:count, adults}, " adults + ", {:count, children}, " children"]`
  valued `{:count, adults + children}`; total `{:count, total}`.

  For `:all_events`: label `"Distinct persons"`; steps are the preset used, one step per
  event in `snapshot.events` order (the event's name, valued that event's total), then
  `"Counted for more than one event (each counted once)"` valued the sum of the event
  totals minus the distinct total — only when that is positive; total `{:count,
  distinct}`.
  """
  @spec explain(Snapshot.t(), Preset.t(), Event.t() | :all_events) :: Formula.t()
  def explain(%Snapshot{} = snapshot, %Preset{} = preset, :all_events) do
    counted = counted(snapshot, preset, :all_events)
    distinct = length(counted)
    frequencies = counted |> Enum.flat_map(& &1.event_ids) |> Enum.frequencies()

    event_steps =
      for %Event{id: id, name: name} <- snapshot.events do
        %Step{label: name, value: {:count, Map.get(frequencies, id, 0)}}
      end

    overlap = Enum.sum(Map.values(frequencies)) - distinct

    overlap_steps =
      if overlap > 0,
        do: [
          %Step{
            label: "Counted for more than one event (each counted once)",
            value: {:count, overlap}
          }
        ],
        else: []

    %Formula{
      label: "Distinct persons",
      steps: [preset_step(preset)] ++ event_steps ++ overlap_steps,
      total: {:count, distinct}
    }
  end

  def explain(%Snapshot{} = snapshot, %Preset{} = preset, %Event{} = event) do
    counted = counted(snapshot, preset, event)

    status_steps =
      for {status, name} <- @status_steps,
          %{adults: adults, children: children, total: total} <- [
            counted |> Enum.filter(&(&1.status == status)) |> tally()
          ],
          total > 0 do
        %Step{
          label: [name <> " — ", {:count, adults}, " adults + ", {:count, children}, " children"],
          value: {:count, total}
        }
      end

    %Formula{
      label: "Headcount",
      steps: [preset_step(preset) | status_steps],
      total: {:count, length(counted)}
    }
  end

  # HC-08: the preset used is always named, as the formula's first step.
  defp preset_step(%Preset{name: name}),
    do: %Step{label: "Headcount preset", value: {:preset, name}}

  # Built once per call (DR-48), never per person.
  defp context(%Snapshot{} = snapshot) do
    %{
      persons: snapshot.persons,
      persons_by_id: Map.new(snapshot.persons, &{&1.id, &1}),
      lookup: Effective.index(snapshot.persons, snapshot.invitations, snapshot.plus_one_opt_outs)
    }
  end

  # The one decision (DR-48, DR-55): `{effective_status, effective_certainty}` when
  # `preset` counts `person` for `event_id`, `nil` otherwise. The cheap checks come first
  # so that a non-candidate never has its host looked up.
  defp decide(context, preset, person, event_id) do
    status = Effective.status(context.lookup, person, event_id)

    if status in @candidate_statuses and allowed?(preset.invitation_statuses, status) and
         allowed?(preset.age_categories, person.age_category) do
      host = host_of(context, person)
      certainty = effective_certainty(person, host, status)

      if allowed?(preset.certainties, certainty) and
           allowed?(preset.want_tiers, PlusOne.want_tier(person, host)) and
           allowed?(preset.group_ids, PlusOne.group_id(person, host)),
         do: {status, certainty}
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

  # Split by each counted person's own age category; works on either counted/3 shape.
  defp tally(entries) do
    {adults, children} =
      Enum.reduce(entries, {0, 0}, fn %{person: %Person{age_category: age}}, {adults, children} ->
        case age do
          :adult -> {adults + 1, children}
          :child -> {adults, children + 1}
        end
      end)

    %{adults: adults, children: children, total: adults + children}
  end
end
