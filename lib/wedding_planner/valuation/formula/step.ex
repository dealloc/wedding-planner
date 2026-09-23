defmodule WeddingPlanner.Valuation.Formula.Step do
  @moduledoc """
  One labelled step of a `WeddingPlanner.Valuation.Formula` (`CST-34`, `BUD-08`,
  `NFR-32`).

  ## Typed, unrounded values (`NFR-14`)

  A step's `:value` is a **tagged, typed value**, never a display string:

    * `{:money, Money.t()}` — an amount at full, unrounded precision. It is rounded
      exactly once, at render, by `WeddingPlannerWeb.Format.money/1`.
    * `{:count, non_neg_integer()}` — a headcount, an included quantity, a billable
      count.
    * `{:rate, Decimal.t()}` — a VAT rate as a fraction (`Decimal.new("0.21")` is 21%),
      the same representation `WeddingPlanner.Money.gross_up/2` takes (`CST-33`,
      `CST-36`).
    * `{:preset, String.t()}` — the name of the headcount preset the formula was
      evaluated with (`HC-08`). The preset used is an ordinary step, not a separate
      field on the formula, so one renderer serves every engine.

  That is the complete list. A *minimum applied* (`CST-32`) is not a kind of its own: it
  is an ordinary `{:money, _}` step whose label says which minimum applied, at the
  position in the chain where it applies. Add a kind here only when a rule needs a value
  none of these can express — every kind added is a clause every renderer must handle.

  ## Labels may carry typed values too

  A label is either a plain string or a list of **segments**, each a string or a typed
  value from the list above:

      ["Seating (", {:count, 78}, " − ", {:count, 50}, " included) × ", {:money, twelve_euro}]

  This is what keeps a formula's *inputs* (`CST-34`: "each counted line, its inputs and
  its result") out of the domain layer's hands as formatted text: the engine never
  formats money, so nothing in `WeddingPlanner.Valuation` can round early or
  bypass `WeddingPlannerWeb.Format`. The web-layer presenter
  (`WeddingPlannerWeb.FormulaPresenter`) renders every segment the same way it renders a
  value.

  ## Never reconcile

  Step values are never rounded so that the displayed steps add up to the displayed
  total. A displayed step may differ from the displayed total by a cent; that is expected
  (`NFR-14`) and the formula component states it in a standing caption.
  """

  @enforce_keys [:label, :value]
  defstruct [:label, :value]

  @typedoc "A typed, unrounded value — see the moduledoc for what each kind means."
  @type value ::
          {:money, Money.t()}
          | {:count, non_neg_integer()}
          | {:rate, Decimal.t()}
          | {:preset, String.t()}

  @typedoc "One piece of a label: literal text, or a typed value rendered in place."
  @type segment :: String.t() | value()

  @typedoc "A plain string, or segments concatenated in order at render."
  @type label :: String.t() | [segment()]

  @type t :: %__MODULE__{label: label(), value: value()}
end
