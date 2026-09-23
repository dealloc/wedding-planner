defmodule WeddingPlanner.Valuation.Offer do
  @moduledoc """
  The offer cost engine (`docs/modules/offers-and-comparison.md` `CST-30`…`CST-36`,
  `DR-50`): an offer's total under one headcount preset, as a labelled
  `WeddingPlanner.Valuation.Formula` (`CST-34`) — `total/4` — and the same computation
  line by line — `breakdown/4`. Pure (`NFR-41`): everything is read from a
  `WeddingPlanner.Valuation.Snapshot`.

  `total/4` is built **only** from `breakdown/4`: one computation, two views. The
  comparison matrix (C4) reads `breakdown/4` for its cells and totals row; the budget
  (B3) reads it for `BUD-07`'s by-event attribution and `total/4` for committed figures.

  ## Which lines count

  `WeddingPlanner.Valuation.Selection.counted_lines/2` decides, and its order is the
  order here (`CST-21`, `CST-22`, `CST-24`, `DR-41`, `DR-49`). Lines that do not count —
  not selected, *included*, *not offered*, *unknown* — are neither priced nor shown.
  Gaps (`WeddingPlanner.Valuation.Gaps`) never change a total.

  ## The order of operations (`CST-36`), and no other

  Per counted line:

    1. **Count** — flat lines count 1. A per-person line's count is the headcount
       function (`WeddingPlanner.Valuation.Headcount.evaluate/3`, or the `:headcount`
       test seam below) for the line's event, restricted to the basis's age category
       (`CST-31`): per adult → `adults`, per child → `children`, per attendee → `total`.
       The function is called **once per distinct event per call**.
    2. **Included quantity** — `billable = max(0, count − included)`; no included
       quantity counts as 0 (`CST-32`).
    3. **Extend** — `computed = amount × billable` (`WeddingPlanner.Money.multiply/2`).
    4. **Minimum charge** — `subtotal = max(computed, minimum charge)`, both in the
       offer's own VAT basis (`WeddingPlanner.Money.max/2`). It is *applied* iff
       `computed < minimum charge` — equal is not applied.
    5. **VAT** — VAT-exclusive offer: `line total = subtotal × (1 + rate)`, each line
       grossed up **separately** on its own rate — the line's override if it has one,
       else the offer's default (`WeddingPlanner.Money.gross_up/2`; `CST-33`, `D-21`).
       VAT-inclusive offer: `line total = subtotal`, no gross-up — a line rate retained
       from when the offer was exclusive is ignored (`DR-41`).

  then over the offer:

    6. **Minimum spend** — `total = max(sum of line totals, minimum spend)`, VAT
       inclusive on both sides. *Applied* iff the sum is below it.

  An **invalid** counted line (`WeddingPlanner.Offers.OfferLine.invalid?/1`: per-person,
  its event deleted) contributes €0 and is flagged, never silently dropped (`XC-42`,
  `D-26`).

  Nothing here rounds (`NFR-14`, `CST-35`): every figure, the total included, is the
  unrounded chain. All arithmetic goes through `WeddingPlanner.Money` (`NFR-12`).

  ## The formula (`DR-50`)

  `%Formula{label: "Total", steps: steps, total: {:money, total}}`. The steps, exactly,
  in this order (`name` is the service's name for a service line, the line's `label` for
  an ad hoc line; `noun` is `"adult"`/`"adults"`, `"child"`/`"children"` or
  `"attendee"`/`"attendees"` by basis, singular iff the count is 1):

    1. iff at least one counted, valid line is per-person, first: `"Headcount preset"` →
       `{:preset, preset.name}` (`HC-08`);
    2. per counted line, in order —
       * valid flat: `name` → `{:money, computed}`;
       * valid per-person without an included quantity:
         `[name, " — ", {:count, count}, " <noun> at <event name> × ", {:money, amount}]`
         → `{:money, computed}`;
       * valid per-person with an included quantity (even 0):
         `[name, " — (", {:count, count}, " <noun> at <event name> − ",
         {:count, included}, " included) × ", {:money, amount}]` → `{:money, computed}`;
       * then, iff the minimum charge applied: `"<name> — minimum charge applied"` →
         `{:money, minimum charge}`;
       * then, iff the offer is VAT exclusive: `[name, " — incl. ", {:rate, rate}, " VAT"]`
         → `{:money, line total}`;
       * an invalid line instead: exactly one step,
         `"<name> — invalid (its event was deleted), not counted"` → `{:money, €0}`;
    3. iff the minimum spend applied: `"Sum of lines"` → `{:money, sum of line totals}`,
       then `"Minimum spend applied"` → `{:money, minimum spend}`.

  So O1 (`docs/07-normative-examples.md`) is: `Headcount preset: Likely`;
  `Seating — (78 attendees at Dinner − 50 included) × €12` = €336;
  `Catering — 72 adults at Dinner × €85` = €6,120; `Catering — minimum charge applied` =
  €6,800; `Catering — 6 children at Dinner × €40` = €240; `Base price` = €4,000;
  `Cleaning fee` = €350; total €11,726.

  Every step value is unrounded. The total is computed from the unrounded chain, never
  from rounded steps, and no step is ever added, removed or adjusted to make the
  displayed steps sum to the displayed total (`NFR-14`).

  ## The `headcount:` option — a test seam, never passed by production code

  `total/4` takes an optional keyword list whose one option, `headcount:`, replaces the
  function step 1 obtains every count from. It is a `t:headcount_fun/0` — a 3-arity
  function with exactly `WeddingPlanner.Valuation.Headcount.evaluate/3`'s signature and
  return type — and **defaults to `&WeddingPlanner.Valuation.Headcount.evaluate/3`**.
  `breakdown/4` takes the same option.

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
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Formula.Step
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Selection
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
  Options for `total/4` and `breakdown/4` (and
  `WeddingPlanner.Valuation.Budget.forecast/3`, which passes them through):

    * `:headcount` — a `t:headcount_fun/0`, default
      `&WeddingPlanner.Valuation.Headcount.evaluate/3`. **Tests only.**
  """
  @type opts :: [headcount: headcount_fun()]

  @typedoc """
  One counted line, priced (`DR-50`). `count`, `included` and `billable` are the inputs
  of `CST-36` steps 1–2 (`billable == max(0, count − included)`); `included` is the
  quantity actually subtracted — 0 for a per-person line without one — and `nil` for a
  flat line, which has `count: 1, billable: 1, event: nil`. `rate` is the rate the line
  was grossed up at, `nil` on a VAT-inclusive offer. An invalid line has
  `invalid: true`, `event`/`count`/`included`/`billable`/`rate` `nil`, no minimum
  applied, and every amount €0.
  """
  @type line_result :: %{
          line: OfferLine.t(),
          name: String.t(),
          event: Event.t() | nil,
          invalid: boolean(),
          count: non_neg_integer() | nil,
          included: non_neg_integer() | nil,
          billable: non_neg_integer() | nil,
          computed: Money.t(),
          minimum_charge_applied: boolean(),
          subtotal: Money.t(),
          rate: Decimal.t() | nil,
          total: Money.t()
        }

  @typedoc """
  An offer priced line by line (`DR-50`): `lines` in
  `WeddingPlanner.Valuation.Selection.counted_lines/2`'s order, `line_sum` the sum of
  their totals, `minimum_spend` the offer's (or `nil`), and `total` after `CST-36`
  step 6. Every amount is unrounded and VAT inclusive except `computed`/`subtotal`, which
  are in the offer's own basis.
  """
  @type breakdown :: %{
          lines: [line_result()],
          line_sum: Money.t(),
          minimum_spend: Money.t() | nil,
          minimum_spend_applied: boolean(),
          total: Money.t()
        }

  @doc """
  The total of `offer` (an offer from `snapshot.offers`) under `preset`, as a formula
  whose steps are exactly those listed in the moduledoc (`CST-34`, `DR-50`). Built only
  from `breakdown/4`.

  `opts` is for tests only (see the moduledoc and `t:opts/0`); production code calls
  `total/3`, which evaluates headcounts through
  `WeddingPlanner.Valuation.Headcount.evaluate/3`.
  """
  @spec total(Snapshot.t(), offer :: struct(), Preset.t(), opts()) :: Formula.t()
  def total(snapshot, offer, preset, opts \\ [])

  def total(%Snapshot{} = snapshot, %Offers.Offer{} = offer, %Preset{} = preset, opts)
      when is_list(opts) do
    result = breakdown(snapshot, offer, preset, opts)

    %Formula{
      label: "Total",
      steps: steps(result, offer, preset),
      total: {:money, result.total}
    }
  end

  @doc """
  `offer` (an offer from `snapshot.offers`) under `preset`, line by line: one
  `t:line_result/0` per counted line in `Selection.counted_lines/2`'s order, the sum of
  their totals, whether the minimum spend applied, and the total (`CST-36`, `DR-50`).

  `opts` is for tests only, exactly as for `total/4`. Raises for a per-person line whose
  `event_id` is not in `snapshot.events`, and for a VAT-exclusive offer with neither a
  line nor an offer rate — both impossible for loaded data.
  """
  @spec breakdown(Snapshot.t(), Offers.Offer.t(), Preset.t(), opts()) :: breakdown()
  def breakdown(snapshot, offer, preset, opts \\ [])

  def breakdown(%Snapshot{} = snapshot, %Offers.Offer{} = offer, %Preset{} = preset, opts)
      when is_list(opts) do
    [headcount: headcount] = Keyword.validate!(opts, headcount: &Headcount.evaluate/3)
    count_fun = &headcount.(snapshot, preset, &1)

    {lines, _counts_by_event} =
      snapshot
      |> Selection.counted_lines(offer)
      |> Enum.map_reduce(%{}, &price_line(snapshot, offer, count_fun, &1, &2))

    line_sum = lines |> Enum.map(& &1.total) |> WeddingPlanner.Money.sum()

    {total, minimum_spend_applied} =
      case offer.minimum_spend do
        nil ->
          {line_sum, false}

        %Money{} = minimum_spend ->
          {WeddingPlanner.Money.max(line_sum, minimum_spend),
           Money.compare!(line_sum, minimum_spend) == :lt}
      end

    %{
      lines: lines,
      line_sum: line_sum,
      minimum_spend: offer.minimum_spend,
      minimum_spend_applied: minimum_spend_applied,
      total: total
    }
  end

  # -- one line (CST-36 steps 1–5) ------------------------------------------------------------

  defp price_line(snapshot, offer, count_fun, %OfferLine{} = line, counts_by_event) do
    name = line_name(snapshot, line)

    if OfferLine.invalid?(line) do
      {invalid_result(line, name), counts_by_event}
    else
      {event, count, included, counts_by_event} =
        count_line(snapshot, count_fun, line, counts_by_event)

      # 2. included quantity
      billable = max(0, count - (included || 0))
      # 3. extend
      computed = WeddingPlanner.Money.multiply(line.amount, billable)
      # 4. minimum charge
      {subtotal, minimum_charge_applied} = minimum_charge(computed, line.minimum_charge)
      # 5. VAT
      rate = rate(offer, line)
      line_total = if rate, do: WeddingPlanner.Money.gross_up(subtotal, rate), else: subtotal

      result = %{
        line: line,
        name: name,
        event: event,
        invalid: false,
        count: count,
        included: included,
        billable: billable,
        computed: computed,
        minimum_charge_applied: minimum_charge_applied,
        subtotal: subtotal,
        rate: rate,
        total: line_total
      }

      {result, counts_by_event}
    end
  end

  # 1. count — flat lines count 1; per-person lines read the headcount function, once per
  # distinct event per call (memoised in `counts_by_event`).
  defp count_line(_snapshot, _count_fun, %OfferLine{basis: :flat}, counts_by_event),
    do: {nil, 1, nil, counts_by_event}

  defp count_line(snapshot, count_fun, %OfferLine{event_id: event_id} = line, counts_by_event) do
    event = event!(snapshot, line)

    {counts, counts_by_event} =
      case Map.fetch(counts_by_event, event_id) do
        {:ok, counts} ->
          {counts, counts_by_event}

        :error ->
          counts = count_fun.(event)
          {counts, Map.put(counts_by_event, event_id, counts)}
      end

    {event, restrict(counts, line.basis), line.included_quantity || 0, counts_by_event}
  end

  defp restrict(%{adults: adults}, :per_adult), do: adults
  defp restrict(%{children: children}, :per_child), do: children
  defp restrict(%{total: total}, :per_attendee), do: total

  defp minimum_charge(computed, nil), do: {computed, false}

  defp minimum_charge(computed, %Money{} = minimum_charge) do
    {WeddingPlanner.Money.max(computed, minimum_charge),
     Money.compare!(computed, minimum_charge) == :lt}
  end

  # The rate a line is grossed up at, or nil for no gross-up (VAT-inclusive offer, whose
  # retained line overrides are ignored — DR-41, CST-36 step 5).
  defp rate(%Offers.Offer{vat_basis: :inclusive}, %OfferLine{}), do: nil

  defp rate(%Offers.Offer{vat_basis: :exclusive} = offer, %OfferLine{} = line) do
    OfferLine.vat_rate(line) || Offers.Offer.vat_rate(offer) ||
      raise ArgumentError,
            "VAT-exclusive offer #{inspect(offer.id)} has no rate for line #{inspect(line.id)} " <>
              "(neither a line override nor an offer default — the database forbids this)"
  end

  defp invalid_result(line, name) do
    zero = WeddingPlanner.Money.new(0)

    %{
      line: line,
      name: name,
      event: nil,
      invalid: true,
      count: nil,
      included: nil,
      billable: nil,
      computed: zero,
      minimum_charge_applied: false,
      subtotal: zero,
      rate: nil,
      total: zero
    }
  end

  # -- the formula (DR-50) --------------------------------------------------------------------

  defp steps(%{lines: lines} = result, offer, preset) do
    preset_steps =
      if Enum.any?(lines, &(not &1.invalid and OfferLine.per_person?(&1.line.basis))),
        do: [%Step{label: "Headcount preset", value: {:preset, preset.name}}],
        else: []

    minimum_spend_steps =
      if result.minimum_spend_applied,
        do: [
          %Step{label: "Sum of lines", value: {:money, result.line_sum}},
          %Step{label: "Minimum spend applied", value: {:money, result.minimum_spend}}
        ],
        else: []

    preset_steps ++ Enum.flat_map(lines, &line_steps(&1, offer)) ++ minimum_spend_steps
  end

  defp line_steps(%{invalid: true, name: name, total: zero}, _offer) do
    [
      %Step{
        label: "#{name} — invalid (its event was deleted), not counted",
        value: {:money, zero}
      }
    ]
  end

  defp line_steps(%{name: name, line: line} = result, offer) do
    extend = %Step{label: extend_label(result), value: {:money, result.computed}}

    minimum =
      if result.minimum_charge_applied,
        do: [
          %Step{label: "#{name} — minimum charge applied", value: {:money, line.minimum_charge}}
        ],
        else: []

    vat =
      if offer.vat_basis == :exclusive,
        do: [
          %Step{
            label: [name, " — incl. ", {:rate, result.rate}, " VAT"],
            value: {:money, result.total}
          }
        ],
        else: []

    [extend | minimum] ++ vat
  end

  defp extend_label(%{line: %OfferLine{basis: :flat}, name: name}), do: name

  defp extend_label(%{line: %OfferLine{included_quantity: nil} = line} = result) do
    [
      result.name,
      " — ",
      {:count, result.count},
      " #{noun(line.basis, result.count)} at #{result.event.name} × ",
      {:money, line.amount}
    ]
  end

  defp extend_label(%{line: line} = result) do
    [
      result.name,
      " — (",
      {:count, result.count},
      " #{noun(line.basis, result.count)} at #{result.event.name} − ",
      {:count, result.included},
      " included) × ",
      {:money, line.amount}
    ]
  end

  defp noun(:per_adult, 1), do: "adult"
  defp noun(:per_adult, _count), do: "adults"
  defp noun(:per_child, 1), do: "child"
  defp noun(:per_child, _count), do: "children"
  defp noun(:per_attendee, 1), do: "attendee"
  defp noun(:per_attendee, _count), do: "attendees"

  # -- lookups ----------------------------------------------------------------------------------

  defp line_name(_snapshot, %OfferLine{service_id: nil, label: label}), do: label

  defp line_name(%Snapshot{services: services}, %OfferLine{service_id: service_id} = line) do
    case Enum.find(services, &(&1.id == service_id)) do
      nil ->
        raise ArgumentError,
              "offer line #{inspect(line.id)} refers to service #{inspect(service_id)}, " <>
                "which is not in the snapshot"

      service ->
        service.name
    end
  end

  defp event!(%Snapshot{events: events}, %OfferLine{event_id: event_id} = line) do
    Enum.find(events, &(&1.id == event_id)) ||
      raise ArgumentError,
            "offer line #{inspect(line.id)} refers to event #{inspect(event_id)}, which is " <>
              "not in the snapshot (a what-if deleting an event must also detach its lines)"
  end
end
