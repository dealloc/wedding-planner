defmodule WeddingPlanner.Valuation.Offer do
  @moduledoc """
  The offer cost engine (`docs/modules/offers-and-comparison.md`): an offer's total as a
  labelled `WeddingPlanner.Valuation.Formula` (`CST-34`). **Contract only: slice C3
  implements it.** Until then `total/3` raises rather than return a plausible, wrong
  amount.

  ## What C3 implements behind this signature

  The `CST-36` order of operations, per line, and no other:

    1. **Count** — `WeddingPlanner.Valuation.Headcount.evaluate/3` for the line's event,
       restricted to the basis's age category (`CST-31`); flat lines count 1.
    2. **Included quantity** — `billable = max(0, count − included)`.
    3. **Extend** — `computed = amount × billable` (`WeddingPlanner.Money.multiply/2`).
    4. **Minimum charge** — `max(computed, minimum charge)` in the offer's own VAT basis
       (`WeddingPlanner.Money.max/2`).
    5. **VAT** — each line grossed up on **its own** rate before anything is summed
       (`WeddingPlanner.Money.gross_up/2`; `D-21`, `D-25`).

  then over the offer:

    6. **Minimum spend** — `max(sum of line totals, minimum spend)`, VAT inclusive on
       both sides.

  Which lines count at all is the effective selection (`CST-24`, with overrides), or the
  frozen selection for a confirmed offer (`CST-40`, `CST-43`); an invalid line
  contributes nothing (`XC-42`).

  ## The formula it returns

  `CST-34` fixes what it must show; C3 fixes the exact labels:

    * the preset used, as a `{:preset, preset.name}` step (`HC-08`);
    * each counted line with its result, its inputs carried in the label as typed
      segments (`{:count, _}`, `{:money, _}`, `{:rate, _}`) rather than formatted text;
    * each minimum applied (charge or spend), as a step where it applies in the chain;
    * `total` is `{:money, offer_total}`.

  Every value is **unrounded** (`NFR-14`, `CST-35`). The total is computed from the
  unrounded chain, never from rounded steps, and no step is added or adjusted to make
  the displayed steps sum to the displayed total.
  """

  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot

  @doc """
  The total of `offer` (an offer from `snapshot.offers`) under `preset`, as a formula.

  Not implemented yet: raises until slice C3.
  """
  @spec total(Snapshot.t(), offer :: struct(), Preset.t()) :: Formula.t()
  def total(%Snapshot{}, _offer, %Preset{}) do
    raise "WeddingPlanner.Valuation.Offer.total/3 is not yet implemented (slice C3)"
  end
end
