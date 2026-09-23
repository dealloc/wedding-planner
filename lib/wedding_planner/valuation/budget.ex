defmodule WeddingPlanner.Valuation.Budget do
  @moduledoc """
  The budget engine (`docs/modules/invoices-and-budget.md`): the per-category budget
  layers of `BUD-02` under one headcount preset. **Contract only: slice B3 implements
  it.** Until then `forecast/2` raises rather than return plausible, wrong figures.

  ## What B3 implements behind this signature

    * **committed** — the sum of the committed totals of the category's confirmed offers
      (frozen selection, live formula; `CST-40`, `CST-41`), each from
      `WeddingPlanner.Valuation.Offer.total/3`;
    * **invoiced / paid / outstanding** — static sums of the category's invoices
      (`BIL-03`), outstanding = invoiced − paid;
    * **forecast** — `BUD-03` in all its branches: per confirmed offer, its invoiced total
      once invoicing is complete, else the larger of committed and invoiced so far
      (`D-23`); plus invoices linked to no offer; and for a category with no confirmed
      offer, the larger of (planning pick total if set, else target — an unset target
      counting as zero) and those unlinked invoices.

  Headcount-dependent layers come back as `WeddingPlanner.Valuation.Formula`s so each
  expands into its calculation (`BUD-08`, `NFR-32`). `BUD-04`'s range is this function
  called once per default preset, never a separate code path.

  ## What-if (`BUD-21`, `BUD-22`)

  A what-if delta is `forecast(Snapshot.apply(snapshot, change), preset)` minus
  `forecast(snapshot, preset)`: the full forecast evaluated twice, so included
  quantities, minimum charges and minimum spends are respected. Never a sum of
  per-person rates.
  """

  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot

  @typedoc """
  The `BUD-02` layers of one category. `target` is `nil` when the category has none
  (displayed as not set; `BUD-03` counts it as zero inside `forecast`).
  """
  @type category_layers :: %{
          category: struct(),
          target: Money.t() | nil,
          committed: Formula.t(),
          invoiced: Money.t(),
          paid: Money.t(),
          outstanding: Money.t(),
          forecast: Formula.t()
        }

  @doc """
  The `BUD-02` layers of every category in `snapshot`, in the categories' sort order,
  under `preset`.

  Not implemented yet: raises until slice B3.
  """
  @spec forecast(Snapshot.t(), Preset.t()) :: [category_layers()]
  def forecast(%Snapshot{}, %Preset{}) do
    raise "WeddingPlanner.Valuation.Budget.forecast/2 is not yet implemented (slice B3)"
  end
end
