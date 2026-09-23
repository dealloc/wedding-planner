defmodule WeddingPlanner.Valuation.Headcount do
  @moduledoc """
  The headcount engine (`docs/modules/headcount.md`): evaluates a headcount preset
  against a snapshot, live, every time (`HC-01`, `D-03`). **Contract only: slice G4
  implements it.** Until then `evaluate/3` raises rather than return a plausible, wrong
  count.

  ## What G4 implements behind this signature

    * `HC-02` — a person is counted when they pass every non-empty criterion of the
      preset; an empty criterion does not restrict.
    * `HC-04` — *accepted* makes a person effectively *certain* for that event;
      *declined* is never counted, whatever the preset says.
    * `HC-05` — a +1 is evaluated with its host's invitation status and want tier, its
      own age category, and its host's effective certainty, capped at *uncertain* for a
      *possible* +1; an opted-out +1 is not counted for that event (`PER-13`, `PER-14`).
    * `HC-03` — for `:all_events`, the number of **distinct** persons counted for at
      least one event, split the same way.

  Everything is read from the snapshot's `persons`, `invitations`, `plus_one_opt_outs`
  and `groups` collections, joined by id; nothing is ever stored.

  The offer engine (`WeddingPlanner.Valuation.Offer.total/3`, `CST-31`) obtains every
  per-person count through this function and never recomputes one.
  """

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot

  @typedoc "Headcount for one event (or distinct persons across all events): `total = adults + children`."
  @type counts :: %{
          adults: non_neg_integer(),
          children: non_neg_integer(),
          total: non_neg_integer()
        }

  @doc """
  Evaluates `preset` for `event` (an event from `snapshot.events`), or for
  `:all_events` (`HC-03`), returning adults, children and total.

  Not implemented yet: raises until slice G4.
  """
  @spec evaluate(Snapshot.t(), Preset.t(), Event.t() | :all_events) :: counts()
  def evaluate(%Snapshot{}, %Preset{}, _event) do
    raise "WeddingPlanner.Valuation.Headcount.evaluate/3 is not yet implemented (slice G4)"
  end
end
