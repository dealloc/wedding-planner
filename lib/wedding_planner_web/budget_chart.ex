defmodule WeddingPlannerWeb.BudgetChart do
  @moduledoc """
  Pure presenter for the two budget charts (design record §7 v2, `DR-77`): the overall-budget
  composition bar and the per-category breakdown bars. Turns plain `%Money{}` figures into bar
  segments expressed in **basis points** (integers `0..10_000`, hundredths of a percent — the same
  convention `WeddingPlanner.Tasks.Timeline` uses for its axis) so `WeddingPlannerWeb.BudgetChartComponents`
  never has to do money arithmetic of its own.

  This module never calls `WeddingPlanner.Valuation.Budget` or touches an Ecto schema — every input is
  a plain `%Money{}` (or a plain list of maps carrying one), so it is testable and reusable independent
  of the engine's shape (task 84 is the only caller, and it hands over already-computed figures for one
  selected preset).

  ## Widths sum exactly (`NFR-12`, `DR-77`)

  A segment's `basis_points` is derived from `WeddingPlanner.Money.share/2` — the **one** sanctioned
  money→ratio conversion — and a set of segments that together represent one whole (the composition
  bar's scale, or one category row's own forecast + range ghost) is rounded via the **largest-remainder
  method**: each segment's raw share is truncated down to an integer basis-point count, and the leftover
  points (at most one per segment) go to the segments with the largest truncated-away remainder, ties
  broken by position. Rounding each segment independently (`round(share × 10_000)`) can under- or
  over-shoot 10 000 by a few points when several segments round the same way — the largest-remainder
  method is the standard fix and is the only thing in this module that touches `Decimal.round/3`
  directly; every other basis-point figure here is exact.

  ## Edge cases (`DR-77`)

  * **Over budget** — forecast exceeds the overall budget: the scale becomes the forecast itself (never
    negative), there is no `:available` segment, and `over_budget` carries the amount by which the
    forecast exceeds the budget.
  * **No budget set** — `overall_budget: nil`: `no_budget?: true`, the scale is the forecast, and there
    is no `:available` segment (there is nothing to compare against).
  * **A scale of €0** — every input is zero (no budget, no forecast, nothing paid or owed): `segments`
    is `[]` rather than a set of zero-width segments (dividing by a zero scale would be meaningless, not
    just zero — `Money.share/2` would return 0 for every segment, so this is a deliberate short-circuit,
    not something that would otherwise crash).
  * **A `€0` category** — `empty?: true`, `segments: []`, `length_basis_points: 0`; the component renders
    the dashed "nothing yet" placeholder row instead of a zero-width bar (design record).
  * **The range ghost** — a category's dashed extension from its selected forecast to its maximum
    possible forecast — is only present (`:range_ghost` in `segments`) when the maximum genuinely exceeds
    the forecast; a category with no such range (an already-flattened, invoicing-complete forecast, or a
    fixed target) never gets one.

  ## Defensive clamping

  `not_yet_billed = forecast − paid − outstanding` is, by task 80's own invariant, never negative (the
  engine never lets invoiced + paid exceed its own forecast). This module clamps it to `€0` anyway rather
  than trust that invariant blindly across a module boundary — a negative segment width is a rendering
  bug waiting to happen, not just an assertion violation. See `WeddingPlannerWeb.BudgetChartTest`'s
  dedicated clamp test.
  """

  # Deliberately no `alias WeddingPlanner.Money` here: this module pattern-matches `%Money{}` (the
  # struct `Money`, ex_money's own top-level module, defines) throughout, and aliasing
  # `WeddingPlanner.Money` to the bare name `Money` would shadow that — `%Money{}` would then look for
  # a (nonexistent) struct on `WeddingPlanner.Money` itself. Every `WeddingPlanner.Money` function call
  # below is therefore fully qualified, matching the convention already used in
  # `WeddingPlanner.Valuation.Invoices`.

  @typedoc "Which layer of the budget a bar segment represents."
  @type segment_kind :: :paid | :outstanding | :not_yet_billed | :available | :range_ghost

  @typedoc "One coloured (or textured, or dashed) slice of a bar."
  @type segment :: %{kind: segment_kind(), amount: Money.t(), basis_points: non_neg_integer()}

  @typedoc "One row of the per-category breakdown chart."
  @type category_row :: %{
          id: term(),
          name: String.t(),
          forecast: Money.t(),
          empty?: boolean(),
          length_basis_points: non_neg_integer(),
          segments: [segment()]
        }

  @basis_points_scale 10_000

  @doc """
  Builds the overall-budget composition bar's segments (`BUD-05`, `BUD-02`, design §7 v2).

  Input is the four plain figures the chart needs, all for the one selected preset:

    * `:overall_budget` — the stored budget, or `nil` when none is set yet.
    * `:paid` — total paid across every invoice (`Invoice.paid?/1`, summed).
    * `:outstanding` — total unpaid invoices (Invoiced − Paid).
    * `:forecast` — the overall forecast at the selected preset (`Valuation.Budget.overall/3`).

  Returns the bar's `:scale` (what 100% of the track represents), its `:segments` (see the moduledoc for
  how the widths are rounded), `:over_budget` (`nil` unless the forecast exceeds the budget) and
  `:no_budget?` (whether `:overall_budget` was `nil`).

  ## Examples

      iex> result = WeddingPlannerWeb.BudgetChart.composition(%{
      ...>   overall_budget: WeddingPlanner.Money.new(45_000),
      ...>   paid: WeddingPlanner.Money.new(3_800),
      ...>   outstanding: WeddingPlanner.Money.new(4_926),
      ...>   forecast: WeddingPlanner.Money.new(21_352)
      ...> })
      iex> Money.to_string!(result.scale)
      "€ 45.000,00"
      iex> result.no_budget?
      false
      iex> result.over_budget
      nil
      iex> Enum.map(result.segments, & &1.kind)
      [:paid, :outstanding, :not_yet_billed, :available]
      iex> Enum.sum(Enum.map(result.segments, & &1.basis_points))
      10000

  """
  @spec composition(%{
          overall_budget: Money.t() | nil,
          paid: Money.t(),
          outstanding: Money.t(),
          forecast: Money.t()
        }) :: %{
          scale: Money.t(),
          segments: [segment()],
          over_budget: Money.t() | nil,
          no_budget?: boolean()
        }
  def composition(%{
        overall_budget: budget,
        paid: paid,
        outstanding: outstanding,
        forecast: forecast
      }) do
    currency = forecast.currency
    zero = WeddingPlanner.Money.new(0, currency)

    not_yet_billed =
      forecast
      |> WeddingPlanner.Money.subtract(paid)
      |> WeddingPlanner.Money.subtract(outstanding)
      |> clamp_nonnegative(zero)

    {scale, over_budget, no_budget?, available} = composition_scale(budget, forecast)

    base_items = [{:paid, paid}, {:outstanding, outstanding}, {:not_yet_billed, not_yet_billed}]
    items = if available, do: base_items ++ [{:available, available}], else: base_items

    segments =
      if WeddingPlanner.Money.compare(scale, zero) == :eq do
        []
      else
        allocate_segments(items, scale)
      end

    %{scale: scale, segments: segments, over_budget: over_budget, no_budget?: no_budget?}
  end

  defp composition_scale(nil, forecast), do: {forecast, nil, true, nil}

  defp composition_scale(%Money{} = budget, forecast) do
    case WeddingPlanner.Money.compare(budget, forecast) do
      :lt -> {forecast, WeddingPlanner.Money.subtract(forecast, budget), false, nil}
      _ -> {budget, nil, false, WeddingPlanner.Money.subtract(budget, forecast)}
    end
  end

  @doc """
  Builds one bar per category for the per-category breakdown chart (design §7 v2's "where is the money
  going, and how does it compare to reality" merged chart).

  `rows` is `[%{id, name, paid, outstanding, forecast, maximum_forecast}]` — one entry per category, in
  the order the bars should render, for the one selected preset. `overall_budget` is the same figure
  `composition/1` was given (or `nil`).

  The chart's scale is `max(overall_budget, Σ forecasts)` (or just `Σ forecasts` with no budget set) —
  every category bar's `:length_basis_points` is that category's `forecast + range ghost` as a share of
  that one scale, so bars are comparable to each other and to the overall picture.

  A `€0`-forecast category (`BUD-03`'s "counts as zero rather than being excluded") is `empty?: true`
  with no segments — the component renders it as a dashed "nothing yet" placeholder rather than a
  zero-width bar.

  ## Examples

      iex> alias WeddingPlanner.Money
      iex> [venue, flowers] = WeddingPlannerWeb.BudgetChart.categories(
      ...>   [
      ...>     %{id: :venue, name: "Venue", paid: Money.new(3_000), outstanding: Money.new(0),
      ...>       forecast: Money.new(11_726), maximum_forecast: Money.new(11_981)},
      ...>     %{id: :flowers, name: "Flowers", paid: Money.new(0), outstanding: Money.new(0),
      ...>       forecast: Money.new(0), maximum_forecast: Money.new(0)}
      ...>   ],
      ...>   Money.new(45_000)
      ...> )
      iex> venue.empty?
      false
      iex> Enum.map(venue.segments, & &1.kind)
      [:paid, :outstanding, :not_yet_billed, :range_ghost]
      iex> flowers.empty?
      true
      iex> flowers.segments
      []

  """
  @spec categories(
          [
            %{
              id: term(),
              name: String.t(),
              paid: Money.t(),
              outstanding: Money.t(),
              forecast: Money.t(),
              maximum_forecast: Money.t()
            }
          ],
          Money.t() | nil
        ) :: [category_row()]
  def categories(rows, overall_budget) do
    total_forecast = WeddingPlanner.Money.sum(Enum.map(rows, & &1.forecast))

    scale =
      case overall_budget do
        nil -> total_forecast
        %Money{} = budget -> WeddingPlanner.Money.max(budget, total_forecast)
      end

    Enum.map(rows, &category_row(&1, scale))
  end

  defp category_row(row, scale) do
    currency = row.forecast.currency
    zero = WeddingPlanner.Money.new(0, currency)

    if WeddingPlanner.Money.compare(row.forecast, zero) == :eq do
      %{
        id: row.id,
        name: row.name,
        forecast: row.forecast,
        empty?: true,
        length_basis_points: 0,
        segments: []
      }
    else
      not_yet_billed =
        row.forecast
        |> WeddingPlanner.Money.subtract(row.paid)
        |> WeddingPlanner.Money.subtract(row.outstanding)
        |> clamp_nonnegative(zero)

      has_ghost? = WeddingPlanner.Money.compare(row.maximum_forecast, row.forecast) == :gt

      ghost_amount =
        if has_ghost?, do: WeddingPlanner.Money.subtract(row.maximum_forecast, row.forecast)

      base_items = [
        {:paid, row.paid},
        {:outstanding, row.outstanding},
        {:not_yet_billed, not_yet_billed}
      ]

      items = if has_ghost?, do: base_items ++ [{:range_ghost, ghost_amount}], else: base_items

      row_total =
        if has_ghost?,
          do: WeddingPlanner.Money.sum([row.forecast, ghost_amount]),
          else: row.forecast

      %{
        id: row.id,
        name: row.name,
        forecast: row.forecast,
        empty?: false,
        length_basis_points: single_basis_points(WeddingPlanner.Money.share(row_total, scale)),
        segments: allocate_segments(items, row_total)
      }
    end
  end

  defp clamp_nonnegative(%Money{} = amount, %Money{} = zero) do
    case WeddingPlanner.Money.compare(amount, zero) do
      :lt -> zero
      _ -> amount
    end
  end

  # -- basis-point allocation (largest-remainder method, see moduledoc) -----------------------------

  defp allocate_segments(items, scale) do
    items
    |> Enum.with_index()
    |> Enum.map(fn {{kind, amount}, index} ->
      exact =
        Decimal.mult(WeddingPlanner.Money.share(amount, scale), Decimal.new(@basis_points_scale))

      floor = Decimal.round(exact, 0, :down)

      %{
        kind: kind,
        amount: amount,
        index: index,
        floor: Decimal.to_integer(floor),
        remainder: Decimal.sub(exact, floor)
      }
    end)
    |> distribute_remainder()
    |> Enum.sort_by(& &1.index)
    |> Enum.map(&%{kind: &1.kind, amount: &1.amount, basis_points: &1.basis_points})
  end

  defp distribute_remainder(entries) do
    used = Enum.sum(Enum.map(entries, & &1.floor))
    leftover = max(@basis_points_scale - used, 0)

    bonus_indices =
      entries
      |> Enum.sort(&remainder_priority?/2)
      |> Enum.take(leftover)
      |> MapSet.new(& &1.index)

    Enum.map(entries, fn entry ->
      bp = if MapSet.member?(bonus_indices, entry.index), do: entry.floor + 1, else: entry.floor
      Map.put(entry, :basis_points, bp)
    end)
  end

  # Larger truncated-away remainder first; ties keep original (left-to-right) order, so the
  # allocation is deterministic rather than depending on `Enum.sort/2`'s stability guarantees alone.
  defp remainder_priority?(a, b) do
    case Decimal.compare(a.remainder, b.remainder) do
      :gt -> true
      :lt -> false
      :eq -> a.index <= b.index
    end
  end

  # A single ratio → basis points, for a category bar's overall length (not part of a set that must
  # itself sum to 10 000 — only every other category's length is independent, so plain half-up
  # rounding is enough here). Clamped defensively to `0..10_000`: a category's own forecast + ghost can
  # in principle exceed `max(budget, Σ forecasts)` (a very large `maximum_forecast` on a category whose
  # *current* forecast is small relative to the rest), which would otherwise round to a bar longer than
  # the track itself.
  defp single_basis_points(ratio) do
    ratio
    |> Decimal.mult(Decimal.new(@basis_points_scale))
    |> Decimal.round(0, :half_up)
    |> Decimal.to_integer()
    |> max(0)
    |> min(@basis_points_scale)
  end
end
