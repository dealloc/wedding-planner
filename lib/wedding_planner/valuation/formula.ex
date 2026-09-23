defmodule WeddingPlanner.Valuation.Formula do
  @moduledoc """
  A computed figure together with the labelled calculation that produced it (`CST-34`,
  `BUD-08`, `NFR-32`). Every engine in `WeddingPlanner.Valuation` that produces a figure
  a user may ask about returns one of these, never a bare `Money.t()`.

  ## Shape

    * `:label` — what the total is ("Total", "Forecast", "Committed"). A
      `t:WeddingPlanner.Valuation.Formula.Step.label/0`, so it may carry typed segments.
    * `:steps` — **one ordered list** of `WeddingPlanner.Valuation.Formula.Step`s, in
      calculation order. The preset used (`{:preset, name}`) and any minimum applied
      (`CST-32`) are ordinary steps at the position where they apply — never separate
      fields a renderer would have to reassemble.
    * `:total` — the result, `{:money, Money.t()}` or `{:count, non_neg_integer()}`,
      **unrounded** (`NFR-14`).

  This mirrors the input of `WeddingPlannerWeb.DisplayComponents.formula/1` one-to-one,
  except that every value here is typed and unrounded where the component takes display
  strings. `WeddingPlannerWeb.FormulaPresenter.present/1` is the one place that turns the
  former into the latter; the component is never taught about these types.

  ## The total is computed, not summed from the steps

  The engine computes `:total` from the unrounded chain (`CST-36`). It is not, and must
  never be made to be, the sum of the rounded step values: a displayed step may differ
  from the displayed total by a cent (`NFR-14`), which the component states in a
  standing caption. Rounding a step early to make the numbers agree is the bug `NFR-14`
  exists to prevent, and no reconciling step or affordance is ever added.
  """

  alias WeddingPlanner.Valuation.Formula.Step

  @enforce_keys [:steps, :total]
  defstruct [:steps, :total, label: "Total"]

  @typedoc "A formula's result: an amount or a count, unrounded."
  @type total :: {:money, Money.t()} | {:count, non_neg_integer()}

  @type t :: %__MODULE__{label: Step.label(), steps: [Step.t()], total: total()}
end
