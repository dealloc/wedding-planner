defmodule WeddingPlanner.Valuation.Budget do
  @moduledoc """
  The budget engine (`docs/modules/invoices-and-budget.md` `BUD-01`…`BUD-05`, `BUD-08`,
  `D-20`, `D-22`, `D-23`; `DR-70`, `DR-71`, `DR-72`, `DR-78`): per category, the `BUD-02`
  layers with `BUD-03`'s forecast in every branch (`forecast/3`); the `BUD-05` overall
  figures (`overall/3`); and `BUD-04`'s three role-preset evaluations (`for_roles/2`).
  Pure (`NFR-41`): everything is read from a `WeddingPlanner.Valuation.Snapshot`, related
  rows are resolved by id with `==` (what-if ids are `make_ref/0`).

  This is the single implementation of `BUD-03`. Breakdowns, charts, the budget screen,
  what-if (B4), CSV (X1) and the dashboard (X2) read these results; none recomputes them.

  ## Never re-derived here

    * a confirmed offer's committed total and its line-by-line breakdown —
      `WeddingPlanner.Valuation.Offer.total/4` and `breakdown/4` (which follow the frozen
      selection through `WeddingPlanner.Valuation.Selection`, `CST-40`, and the live guest
      list through the headcount, `CST-41`);
    * invoice totals, paid, an offer's invoiced / paid / outstanding and its linked
      invoices — `WeddingPlanner.Valuation.Invoices` (`total/2`, `paid?/1`,
      `offer_figures/2`, `for_offer/2`);
    * which presets hold the three roles — `WeddingPlanner.Valuation.PresetChoice`.

  Arithmetic goes only through `WeddingPlanner.Money` (`NFR-12`); nothing rounds
  (`NFR-14`) — every figure, step and total is the unrounded chain.

  ## One category (`forecast/3`, `DR-70`)

  Every category of `snapshot.categories` is listed, in that order — an empty one
  included (`BUD-03`: "forecasts zero rather than being excluded").

    * **The category's invoices** are the invoices whose `category_id` is the category's,
      in `snapshot.invoices` order. An invoice belongs to exactly one category, so every
      invoice is counted in exactly one category's layers. Per-offer figures are taken
      over the category's invoices only (`Invoices.offer_figures/2` and
      `Invoices.for_offer/2` evaluated on the snapshot restricted to them), so an invoice
      linked to an offer of *another* category — impossible under `DR-58` — is counted
      once, in its own category, as unlinked.
    * **Confirmed offers** are the category's offers with `status == :confirmed`, in
      `snapshot.offers` order (`D-20`: several are allowed). Each one's contribution:
      `committed` = `Offer.total/4`, `breakdown` = `Offer.breakdown/4` (both with this
      call's `opts`), its invoiced / paid / outstanding and linked invoices, and its
      `forecast` with the `source` it came from (`D-23`):
        * *invoicing complete* → its invoiced total, even below committed
          (`source: :invoicing_complete`);
        * otherwise the larger of committed and invoiced — `source: :committed` when
          committed ≥ invoiced (a tie is `:committed`), else `:invoiced`.
    * **Unlinked invoices** are the category's invoices whose `offer_id` is `nil` **or
      names no confirmed offer of this category** (an invoice linked to a shortlisted
      offer — impossible under `DR-58`/`DR-65` — still counts: money never disappears
      silently, `D-26`).
    * **Branch.** Any confirmed offer → `:confirmed`: forecast = Σ offer forecasts +
      Σ unlinked invoices; a `planning_pick` flag in such a category is ignored
      (`DR-66` makes it impossible) and `planning_pick` is `nil`. Otherwise the **base**
      is the planning pick's `Offer.total/4` (`:planning_pick`, `CST-44` — it replaces
      the target) when an offer of the category that is neither rejected nor confirmed
      has `planning_pick` set (the first such in `snapshot.offers` order; the unique
      index allows one), else the target (`:target`), else €0 (`:no_target`: an unset
      target counts as zero); forecast = max(base, Σ unlinked invoices) and
      `fallback_winner` says which side won — `:base` on a tie.
    * **Committed** = Σ confirmed offers' committed totals; **Invoiced** = every invoice
      of the category; **Paid** = the paid ones (`Invoices.paid?/1`); **Outstanding** =
      Invoiced − Paid.

  Invariant (property-tested, relied on by the charts, `DR-77`): **forecast ≥ invoiced**
  in every category.

  ## Overall (`overall/3`, `DR-72`)

  Every total is the sum of the category layers: Target (the targets that are set),
  Committed, Invoiced, Paid, Outstanding (= total unpaid) and Forecast. **Spent** = total
  Paid. **Available** = overall budget − forecast (`BUD-01`: `snapshot.settings.
  overall_budget`), unrounded and possibly negative; `over_budget` = forecast − budget
  when that is positive, else `nil`, so no caller ever subtracts. An unset budget gives
  `available: :no_budget` and `over_budget: nil`.

  ## Role presets (`for_roles/2`, `BUD-04`, `DR-71`)

  `BUD-04`'s range is `overall/3` evaluated once per **role** preset (minimum, likely,
  maximum — `PresetChoice.role_presets/1`, identity by role, never by name), never a
  separate code path. `:missing` when a role is unassigned.

  ## Formulas (`BUD-08`, `NFR-32`)

  Every committed, forecast and available figure is a `WeddingPlanner.Valuation.Formula`
  whose `total` is the figure. Below, *preset step* is
  `%Step{label: "Headcount preset", value: {:preset, preset.name}}` — the same label
  `Offer.total/4` uses (`HC-08`) — and it appears **iff** a contributing `Offer.total/4`
  formula has one (`DR-50` precedent). The steps, exactly, in order:

  **Category Committed** — label `"Committed"`:

    1. the preset step iff any confirmed offer's committed formula has one;
    2. per confirmed offer: `vendor_name` → `{:money, committed}`;
    3. with no confirmed offer instead exactly one step: `"No confirmed offer"` →
       `{:money, €0}`.

  **Category Forecast** — label `"Forecast"`. The contributing `Offer.total/4` formulas
  are the committed formulas of the confirmed offers that are **not** invoicing complete
  (their committed total appears in a step) and, in the `:planning_pick` branch, the
  pick's total. Branch `:confirmed`:

    1. the preset step iff a contributing formula has one;
    2. per confirmed offer —
       * invoicing complete: `[vendor, " — invoicing complete, invoiced total"]` →
         `{:money, invoiced}`;
       * otherwise: `[vendor, " — larger of committed ", {:money, committed},
         " and invoiced so far ", {:money, invoiced}]` → `{:money, offer forecast}`;
    3. per unlinked invoice: `[invoice label, " — not linked to an offer"]` →
       `{:money, its total}`.

  Branches `:planning_pick`, `:target`, `:no_target`:

    1. the preset step iff the pick's formula has one (`:planning_pick` only);
    2. the base: `["Planning pick — ", vendor]` → `{:money, pick total}` /
       `"Target"` → `{:money, target}` / `"No target set — counts as zero"` →
       `{:money, €0}`;
    3. iff there are unlinked invoices: one step per unlinked invoice as above, then
       `"Larger of the two"` → `{:money, forecast}`.

  **Overall Committed** / **Overall Forecast** — labels `"Committed"` / `"Forecast"`: the
  preset step iff any category's Committed / Forecast formula has one, then one step per
  category: its `name` → `{:money, its committed / forecast}`.

  **Available** — label `"Available"`: the preset step iff the overall Forecast has one,
  `"Overall budget"` → `{:money, budget}`, `"Forecast"` → `{:money, forecast}`; total
  budget − forecast.

  ## Needs attention (`XC-42`, `D-26`, `DR-84`)

  A category needs attention when a **confirmed** offer of it has any invalid line,
  counted or not — exactly `WeddingPlanner.Valuation.Comparison`'s matrix-column
  condition (`DR-57`), read through `WeddingPlanner.Valuation.Offer.needs_attention?/2`
  so the two markers can never disagree — plus, when the category's `branch` is
  `:planning_pick`, the pick that the forecast is built on (`D-26`: money must never
  disappear from the budget silently for the figure a forecast rests on). `category_
  layers.needs_attention` lists one entry per affected offer, in `snapshot.offers` order,
  each with its `role` (`:confirmed` or `:planning_pick`) and its
  `WeddingPlanner.Valuation.Offer.invalid_lines/2`; `[]` when none. The money itself is
  already visible in the committed/forecast formulas' "… — invalid (its event was
  deleted), not counted" steps.

  ## What-if (`BUD-21`, `BUD-22`)

  A what-if delta is `forecast(Snapshot.apply(snapshot, change), preset)` minus
  `forecast(snapshot, preset)`: the full forecast evaluated twice, so included
  quantities, minimum charges and minimum spends are respected. Never a sum of
  per-person rates.

  ## The `headcount:` option — a test seam, never passed by production code

  `forecast/3`, `overall/3` and `for_roles/2` take the same optional keyword list as
  `WeddingPlanner.Valuation.Offer.total/4` (`t:WeddingPlanner.Valuation.Offer.opts/0`)
  and pass it through, unchanged, to **every** `Offer.total/4` and `Offer.breakdown/4`
  call they make, so one evaluation uses one headcount function throughout. Its one
  option, `headcount:`, is a `t:WeddingPlanner.Valuation.Offer.headcount_fun/0` and
  **defaults to `&WeddingPlanner.Valuation.Headcount.evaluate/3`**.

  It exists so the normative budget examples (B1–B4, `docs/07-normative-examples.md`)
  can be evaluated against their stated headcounts, through
  `WeddingPlanner.NormativeExamples.fixed_headcount/0` (test support). **Production code
  MUST NOT pass `headcount:`** — the production path is the default, and
  `WeddingPlanner.Valuation.EnginesTest` fails if any file under `lib/` other than this
  one and `WeddingPlanner.Valuation.Offer` mentions the option. Why it is an argument
  rather than a preset or snapshot field is set out in `WeddingPlanner.Valuation.Offer`'s
  moduledoc; in short, a counts override inside the snapshot would survive
  `Snapshot.apply/2` and make every what-if above measure nothing.
  """

  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Formula.Step
  alias WeddingPlanner.Valuation.Invoices
  alias WeddingPlanner.Valuation.Offer
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.PresetChoice
  alias WeddingPlanner.Valuation.Snapshot

  @typedoc """
  Which `BUD-03` branch produced a category's forecast: a confirmed offer exists
  (`:confirmed`); else the planning pick's total (`:planning_pick`), the target
  (`:target`) or zero for an unset target (`:no_target`) was the base.
  """
  @type branch :: :confirmed | :planning_pick | :target | :no_target

  @typedoc """
  Which figure a confirmed offer's forecast took (`D-23`): its committed total
  (`:committed`, also on a tie), its larger invoiced total (`:invoiced`), or its invoiced
  total because invoicing is complete (`:invoicing_complete`).
  """
  @type source :: :committed | :invoiced | :invoicing_complete

  @typedoc """
  One confirmed offer's part of its category (`DR-70`). `committed` is
  `Offer.total/4`'s formula and `breakdown` `Offer.breakdown/4`'s result (same opts —
  `DR-78`: its lines carry `invalid: true` for C6); `invoiced`/`paid`/`outstanding` are
  `Invoices.offer_figures/2` and `invoices` `Invoices.for_offer/2`, both over the
  category's invoices; `forecast` is what it adds to the category forecast and `source`
  where that came from.
  """
  @type offer_contribution :: %{
          offer: Offers.Offer.t(),
          committed: Formula.t(),
          breakdown: Offer.breakdown(),
          invoiced: Money.t(),
          paid: Money.t(),
          outstanding: Money.t(),
          invoices: [Invoice.t()],
          forecast: Money.t(),
          source: source()
        }

  @typedoc """
  The planning pick used as a category's base (`CST-44`): the offer, its `Offer.total/4`
  formula and `Offer.breakdown/4` result.
  """
  @type planning_pick :: %{
          offer: Offers.Offer.t(),
          total: Formula.t(),
          breakdown: Offer.breakdown()
        }

  @typedoc "An unlinked invoice of a category (`DR-70`) with its total."
  @type unlinked_invoice :: %{invoice: Invoice.t(), total: Money.t()}

  @typedoc """
  The `BUD-02` layers of one category under one preset (`DR-70`).

    * `target` — `nil` when unset (shown as not set; `BUD-03` counts it as zero);
    * `committed`, `forecast` — formulas (see the moduledoc for their steps);
    * `invoiced`, `paid`, `outstanding` — over every invoice of the category;
    * `confirmed_offers` — in `snapshot.offers` order, empty unless `branch == :confirmed`;
    * `planning_pick` — non-`nil` iff `branch == :planning_pick`;
    * `unlinked_invoices` / `unlinked_invoiced` — the unlinked invoices (in
      `snapshot.invoices` order) and the sum of their totals;
    * `fallback_winner` — which side of max(base, unlinked) won (`:base` on a tie);
      `nil` iff `branch == :confirmed`;
    * `invoices` — every invoice of the category, in `snapshot.invoices` order;
    * `needs_attention` — the category's offers needing attention (`XC-42`, `D-26`,
      `DR-84`, see the moduledoc): confirmed offers with an invalid line, plus the
      planning pick when `branch == :planning_pick` and it has one; `[]` when none, in
      `snapshot.offers` order.
  """
  @type category_layers :: %{
          category: Category.t(),
          branch: branch(),
          target: Money.t() | nil,
          committed: Formula.t(),
          invoiced: Money.t(),
          paid: Money.t(),
          outstanding: Money.t(),
          forecast: Formula.t(),
          confirmed_offers: [offer_contribution()],
          planning_pick: planning_pick() | nil,
          unlinked_invoices: [unlinked_invoice()],
          unlinked_invoiced: Money.t(),
          fallback_winner: :base | :unlinked_invoices | nil,
          invoices: [Invoice.t()],
          needs_attention: [
            %{
              offer: Offers.Offer.t(),
              role: :confirmed | :planning_pick,
              invalid_lines: [OfferLine.t()]
            }
          ]
        }

  @typedoc """
  The `BUD-05` overall figures under `preset` (`DR-72`). `categories` is `forecast/3`'s
  list; every total is the sum of its layers (`target` over the targets that are set).
  `spent == paid`. `available` is budget − forecast (may be negative) or `:no_budget`
  when `overall_budget` is `nil`; `over_budget` is forecast − budget when positive,
  else `nil`.
  """
  @type overall :: %{
          preset: Preset.t(),
          categories: [category_layers()],
          overall_budget: Money.t() | nil,
          target: Money.t(),
          committed: Formula.t(),
          invoiced: Money.t(),
          paid: Money.t(),
          outstanding: Money.t(),
          spent: Money.t(),
          forecast: Formula.t(),
          available: Formula.t() | :no_budget,
          over_budget: Money.t() | nil
        }

  @typedoc "`overall/3` under each of the three role presets (`BUD-04`, `DR-71`)."
  @type by_role :: %{minimum: overall(), likely: overall(), maximum: overall()}

  @doc """
  The `BUD-02` layers of every category in `snapshot` (in `snapshot.categories` order,
  empty categories included) under `preset`, with `BUD-03`'s forecast — see the
  moduledoc for the rules and the formulas' steps.

  `opts` is for tests only and is passed through unchanged to every
  `WeddingPlanner.Valuation.Offer.total/4` and `Offer.breakdown/4` call (see the
  moduledoc and `t:WeddingPlanner.Valuation.Offer.opts/0`); production code calls
  `forecast/2`.
  """
  @spec forecast(Snapshot.t(), Preset.t(), Offer.opts()) :: [category_layers()]
  def forecast(snapshot, preset, opts \\ [])

  def forecast(%Snapshot{} = snapshot, %Preset{} = preset, opts) when is_list(opts) do
    Enum.map(snapshot.categories, &category_layers(snapshot, &1, preset, opts))
  end

  @doc """
  The `BUD-05` overall figures under `preset` (`DR-72`): `forecast/3`'s categories, the
  totals of every layer, Spent, Available against `snapshot.settings.overall_budget`
  (`BUD-01`) and `over_budget`. See the moduledoc.

  `opts` is for tests only, exactly as for `forecast/3`; production code calls
  `overall/2`.
  """
  @spec overall(Snapshot.t(), Preset.t(), Offer.opts()) :: overall()
  def overall(snapshot, preset, opts \\ [])

  def overall(%Snapshot{} = snapshot, %Preset{} = preset, opts) when is_list(opts) do
    categories = forecast(snapshot, preset, opts)
    budget = snapshot.settings.overall_budget

    committed = total_formula("Committed", categories, & &1.committed, preset)
    forecast = total_formula("Forecast", categories, & &1.forecast, preset)
    paid = sum_layer(categories, & &1.paid)

    %{
      preset: preset,
      categories: categories,
      overall_budget: budget,
      target: categories |> Enum.map(& &1.target) |> Enum.reject(&is_nil/1) |> money_sum(),
      committed: committed,
      invoiced: sum_layer(categories, & &1.invoiced),
      paid: paid,
      outstanding: sum_layer(categories, & &1.outstanding),
      spent: paid,
      forecast: forecast,
      available: available(budget, forecast, preset),
      over_budget: over_budget(budget, money(forecast))
    }
  end

  @doc """
  `overall/3` once per role preset of `snapshot.headcount_presets` (`BUD-04`, `DR-71`),
  found by role through `PresetChoice.role_presets/1`: `{:ok, %{minimum: overall,
  likely: overall, maximum: overall}}`, or `:missing` when a role is unassigned.

  `opts` is for tests only, exactly as for `forecast/3`; production code calls
  `for_roles/1`.
  """
  @spec for_roles(Snapshot.t(), Offer.opts()) :: {:ok, by_role()} | :missing
  def for_roles(snapshot, opts \\ [])

  def for_roles(%Snapshot{} = snapshot, opts) when is_list(opts) do
    case PresetChoice.role_presets(snapshot.headcount_presets) do
      {:ok, presets} ->
        {:ok, Map.new(presets, fn {role, p} -> {role, overall(snapshot, p, opts)} end)}

      :missing ->
        :missing
    end
  end

  # -- one category --------------------------------------------------------------------------

  defp category_layers(snapshot, %Category{id: category_id} = category, preset, opts) do
    invoices = Enum.filter(snapshot.invoices, &(&1.category_id == category_id))
    # Per-offer figures over this category's invoices only: each invoice counts once, in
    # its own category (see the moduledoc).
    scoped = %{snapshot | invoices: invoices}
    offers = Enum.filter(snapshot.offers, &(&1.category_id == category_id))
    confirmed = Enum.filter(offers, &(&1.status == :confirmed))
    confirmed_ids = Enum.map(confirmed, & &1.id)

    invoice_totals = Enum.map(invoices, &{&1, Invoices.total(scoped, &1)})
    invoiced = invoice_totals |> Enum.map(&elem(&1, 1)) |> money_sum()

    unlinked =
      for {invoice, total} <- invoice_totals,
          is_nil(invoice.offer_id) or invoice.offer_id not in confirmed_ids,
          do: %{invoice: invoice, total: total}

    unlinked_invoiced = unlinked |> Enum.map(& &1.total) |> money_sum()
    contributions = Enum.map(confirmed, &contribution(scoped, &1, preset, opts))

    paid =
      invoice_totals
      |> Enum.filter(fn {invoice, _total} -> Invoices.paid?(invoice) end)
      |> Enum.map(&elem(&1, 1))
      |> money_sum()

    base = %{
      category: category,
      target: category.target,
      committed: committed_formula(contributions, preset),
      invoiced: invoiced,
      paid: paid,
      outstanding: WeddingPlanner.Money.subtract(invoiced, paid),
      confirmed_offers: contributions,
      unlinked_invoices: unlinked,
      unlinked_invoiced: unlinked_invoiced,
      invoices: invoices
    }

    fallback = %{snapshot: scoped, category: category, offers: offers, preset: preset, opts: opts}

    layers =
      Map.merge(base, forecast_layers(contributions, unlinked, unlinked_invoiced, fallback))

    Map.put(layers, :needs_attention, needs_attention(scoped, contributions, layers))
  end

  # XC-42, D-26, DR-84: the same "needs attention" condition as the matrix column
  # (`Offer.needs_attention?/2`, DR-57), for every confirmed offer of the category — plus
  # the planning pick, isolated in `planning_pick_needs_attention/2` below (FP-88b: delete
  # that clause alone and only the pick's test fails).
  defp needs_attention(scoped, contributions, layers) do
    confirmed =
      for %{offer: offer} <- contributions,
          invalid_lines = Offer.invalid_lines(scoped, offer),
          invalid_lines != [],
          do: %{offer: offer, role: :confirmed, invalid_lines: invalid_lines}

    confirmed ++ planning_pick_needs_attention(scoped, layers)
  end

  # DR-84 (Q-XC42, settled by the orchestrator, adopted in full): the planning pick marks
  # its category too, exactly when it is the forecast's base — D-26's "money must never
  # disappear from the budget silently" applies equally to the figure a forecast rests on.
  # Kept in its own function with its own test (`budget_test.exs`) so dropping it is a
  # one-clause change (FP-88b).
  defp planning_pick_needs_attention(_scoped, %{branch: branch}) when branch != :planning_pick,
    do: []

  defp planning_pick_needs_attention(scoped, %{planning_pick: %{offer: offer}}) do
    case Offer.invalid_lines(scoped, offer) do
      [] -> []
      invalid_lines -> [%{offer: offer, role: :planning_pick, invalid_lines: invalid_lines}]
    end
  end

  defp contribution(scoped, %Offers.Offer{} = offer, preset, opts) do
    committed = Offer.total(scoped, offer, preset, opts)
    figures = Invoices.offer_figures(scoped, offer)
    committed_money = money(committed)

    {forecast, source} =
      cond do
        offer.invoicing_complete ->
          {figures.invoiced, :invoicing_complete}

        WeddingPlanner.Money.compare(committed_money, figures.invoiced) == :lt ->
          {figures.invoiced, :invoiced}

        true ->
          {committed_money, :committed}
      end

    %{
      offer: offer,
      committed: committed,
      breakdown: Offer.breakdown(scoped, offer, preset, opts),
      invoiced: figures.invoiced,
      paid: figures.paid,
      outstanding: figures.outstanding,
      invoices: Invoices.for_offer(scoped, offer),
      forecast: forecast,
      source: source
    }
  end

  # Branch :confirmed — Σ offer forecasts + Σ unlinked invoices.
  defp forecast_layers([_ | _] = contributions, unlinked, unlinked_invoiced, %{preset: preset}) do
    contributing =
      for %{source: source, committed: committed} <- contributions,
          source != :invoicing_complete,
          do: committed

    total = money_sum(Enum.map(contributions, & &1.forecast) ++ [unlinked_invoiced])

    steps =
      preset_steps(contributing, preset) ++
        Enum.map(contributions, &offer_forecast_step/1) ++
        Enum.map(unlinked, &unlinked_step/1)

    %{
      branch: :confirmed,
      forecast: %Formula{label: "Forecast", steps: steps, total: {:money, total}},
      planning_pick: nil,
      fallback_winner: nil
    }
  end

  # No confirmed offer — max(base, Σ unlinked), base = pick total / target / €0.
  defp forecast_layers([], unlinked, unlinked_invoiced, %{preset: preset} = fallback) do
    {branch, pick, base_money, base_step, contributing} = fallback_base(fallback)

    {total, winner} =
      case WeddingPlanner.Money.compare(base_money, unlinked_invoiced) do
        :lt -> {unlinked_invoiced, :unlinked_invoices}
        _ -> {base_money, :base}
      end

    unlinked_steps =
      case unlinked do
        [] ->
          []

        [_ | _] ->
          Enum.map(unlinked, &unlinked_step/1) ++
            [%Step{label: "Larger of the two", value: {:money, total}}]
      end

    %{
      branch: branch,
      forecast: %Formula{
        label: "Forecast",
        steps: preset_steps(contributing, preset) ++ [base_step] ++ unlinked_steps,
        total: {:money, total}
      },
      planning_pick: pick,
      fallback_winner: winner
    }
  end

  # The fallback base (CST-44, BUD-03): the planning pick's total, else the target, else €0.
  defp fallback_base(%{snapshot: snapshot, category: category, offers: offers} = fallback) do
    case Enum.find(offers, &(&1.planning_pick and &1.status not in [:rejected, :confirmed])) do
      %Offers.Offer{} = offer ->
        total = Offer.total(snapshot, offer, fallback.preset, fallback.opts)
        breakdown = Offer.breakdown(snapshot, offer, fallback.preset, fallback.opts)
        pick = %{offer: offer, total: total, breakdown: breakdown}

        step = %Step{
          label: ["Planning pick — ", offer.vendor_name],
          value: {:money, money(total)}
        }

        {:planning_pick, pick, money(total), step, [total]}

      nil ->
        case category.target do
          %Money{} = target ->
            {:target, nil, target, %Step{label: "Target", value: {:money, target}}, []}

          nil ->
            zero = zero()
            step = %Step{label: "No target set — counts as zero", value: {:money, zero}}
            {:no_target, nil, zero, step, []}
        end
    end
  end

  defp offer_forecast_step(%{source: :invoicing_complete, offer: offer, invoiced: invoiced}) do
    %Step{
      label: [offer.vendor_name, " — invoicing complete, invoiced total"],
      value: {:money, invoiced}
    }
  end

  defp offer_forecast_step(%{offer: offer, committed: committed, invoiced: invoiced} = c) do
    %Step{
      label: [
        offer.vendor_name,
        " — larger of committed ",
        {:money, money(committed)},
        " and invoiced so far ",
        {:money, invoiced}
      ],
      value: {:money, c.forecast}
    }
  end

  defp unlinked_step(%{invoice: invoice, total: total}) do
    %Step{label: [invoice.label, " — not linked to an offer"], value: {:money, total}}
  end

  defp committed_formula([], _preset) do
    zero = zero()

    %Formula{
      label: "Committed",
      steps: [%Step{label: "No confirmed offer", value: {:money, zero}}],
      total: {:money, zero}
    }
  end

  defp committed_formula(contributions, preset) do
    offer_steps =
      Enum.map(contributions, fn %{offer: offer, committed: committed} ->
        %Step{label: offer.vendor_name, value: {:money, money(committed)}}
      end)

    %Formula{
      label: "Committed",
      steps: preset_steps(Enum.map(contributions, & &1.committed), preset) ++ offer_steps,
      total: {:money, contributions |> Enum.map(&money(&1.committed)) |> money_sum()}
    }
  end

  # -- overall ---------------------------------------------------------------------------------

  defp total_formula(label, categories, formula_fun, preset) do
    formulas = Enum.map(categories, formula_fun)

    category_steps =
      Enum.zip_with(categories, formulas, fn %{category: category}, formula ->
        %Step{label: category.name, value: {:money, money(formula)}}
      end)

    %Formula{
      label: label,
      steps: preset_steps(formulas, preset) ++ category_steps,
      total: {:money, formulas |> Enum.map(&money/1) |> money_sum()}
    }
  end

  defp available(nil, _forecast, _preset), do: :no_budget

  defp available(%Money{} = budget, %Formula{} = forecast, preset) do
    forecast_money = money(forecast)

    %Formula{
      label: "Available",
      steps:
        preset_steps([forecast], preset) ++
          [
            %Step{label: "Overall budget", value: {:money, budget}},
            %Step{label: "Forecast", value: {:money, forecast_money}}
          ],
      total: {:money, WeddingPlanner.Money.subtract(budget, forecast_money)}
    }
  end

  defp over_budget(nil, _forecast), do: nil

  defp over_budget(%Money{} = budget, %Money{} = forecast) do
    case WeddingPlanner.Money.compare(forecast, budget) do
      :gt -> WeddingPlanner.Money.subtract(forecast, budget)
      _ -> nil
    end
  end

  defp sum_layer(categories, fun), do: categories |> Enum.map(fun) |> money_sum()

  # -- helpers ---------------------------------------------------------------------------------

  # The preset step iff any of `formulas` carries one (DR-50 precedent).
  defp preset_steps(formulas, %Preset{name: name}) do
    if Enum.any?(formulas, &preset_step?/1),
      do: [%Step{label: "Headcount preset", value: {:preset, name}}],
      else: []
  end

  defp preset_step?(%Formula{steps: steps}),
    do: Enum.any?(steps, &match?(%Step{value: {:preset, _}}, &1))

  defp money(%Formula{total: {:money, %Money{} = money}}), do: money

  defp money_sum(amounts), do: WeddingPlanner.Money.sum(amounts)

  defp zero, do: WeddingPlanner.Money.new(0)
end
