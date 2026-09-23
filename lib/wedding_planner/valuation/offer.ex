defmodule WeddingPlanner.Valuation.Offer do
  @moduledoc """
  The offer cost engine (`docs/modules/offers-and-comparison.md`): an offer's total as a
  labelled `WeddingPlanner.Valuation.Formula` (`CST-34`). **Contract only: slice C3
  implements it.** Until then `total/4` raises rather than return a plausible, wrong
  amount.

  ## What C3 implements behind this signature

  The `CST-36` order of operations, per line, and no other:

    1. **Count** — `WeddingPlanner.Valuation.Headcount.evaluate/3` for the line's event
       (or the `:headcount` test seam below, which defaults to it), restricted to the
       basis's age category (`CST-31`); flat lines count 1.
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

  ## The `headcount:` option — a test seam, never passed by production code

  `total/4` takes an optional keyword list whose one option, `headcount:`, replaces the
  function step 1 obtains every count from. It is a `t:headcount_fun/0` — a 3-arity
  function with exactly `WeddingPlanner.Valuation.Headcount.evaluate/3`'s signature and
  return type — and **defaults to `&WeddingPlanner.Valuation.Headcount.evaluate/3`**.

  It exists so the normative offer examples (O1–O6, `docs/07-normative-examples.md`) can
  be evaluated against their stated headcounts (Likely 72 + 6, Minimum 60 + 4 for Dinner)
  before the headcount engine (slice G4) exists, using
  `WeddingPlanner.NormativeExamples.fixed_headcount/0` (test support). It is not a
  modelling feature:

    * **Production code MUST NOT pass `headcount:`.** The production path is the
      default. A test that uses the seam says so at the call site.
      `WeddingPlanner.Valuation.EnginesTest` scans `lib/` and fails if any file other
      than this one and `WeddingPlanner.Valuation.Budget` mentions the option.
    * It is deliberately **not** a field of `WeddingPlanner.Valuation.Preset`: a preset
      never stores a number (`HC-01`, `D-03`), and stored presets reach production
      through the snapshot loader.
    * It is deliberately **not** a field of `WeddingPlanner.Valuation.Snapshot`: a counts
      override there would survive `Snapshot.apply/2`, so a what-if (`BUD-21`) evaluated
      through it would silently ignore the very change it measures.

  `WeddingPlanner.Valuation.Budget.forecast/3` accepts the same option and passes it
  through to every `total/4` call it makes.
  """

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot

  @typedoc """
  The function the cost engine obtains every headcount from: exactly
  `WeddingPlanner.Valuation.Headcount.evaluate/3`'s signature and return type. The
  default is `&WeddingPlanner.Valuation.Headcount.evaluate/3`; anything else is a test
  seam (see the moduledoc).
  """
  @type headcount_fun ::
          (Snapshot.t(), Preset.t(), Event.t() | :all_events -> Headcount.counts())

  @typedoc """
  Options for `total/4` (and `WeddingPlanner.Valuation.Budget.forecast/3`, which passes
  them through):

    * `:headcount` — a `t:headcount_fun/0`, default
      `&WeddingPlanner.Valuation.Headcount.evaluate/3`. **Tests only.**
  """
  @type opts :: [headcount: headcount_fun()]

  @doc """
  The total of `offer` (an offer from `snapshot.offers`) under `preset`, as a formula.

  `opts` is for tests only (see the moduledoc and `t:opts/0`); production code calls
  `total/3`, which evaluates headcounts through
  `WeddingPlanner.Valuation.Headcount.evaluate/3`.

  Not implemented yet: raises until slice C3.
  """
  @spec total(Snapshot.t(), offer :: struct(), Preset.t(), opts()) :: Formula.t()
  def total(snapshot, offer, preset, opts \\ [])

  def total(%Snapshot{}, _offer, %Preset{}, opts) when is_list(opts) do
    raise "WeddingPlanner.Valuation.Offer.total/3 is not yet implemented (slice C3)"
  end
end
