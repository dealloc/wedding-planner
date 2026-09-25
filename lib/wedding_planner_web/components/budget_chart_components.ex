defmodule WeddingPlannerWeb.BudgetChartComponents do
  @moduledoc """
  Renders `WeddingPlannerWeb.BudgetChart`'s output as inline HTML/CSS stacked bars — no SVG, no JS, no
  new dependency (design record §7 v2, `DR-77`). Both components are pure functions of the presenter's
  output plus the preset name currently in view; neither does money arithmetic, computes a segment, or
  reaches into `WeddingPlanner.Valuation` — that separation is the whole point of splitting the
  presenter (`BudgetChart`) from this rendering layer.

  ## Nested percentages, not absolute positioning

  A basis-point width becomes `style="width: N.NN%"` (see `width_pct/1`) via plain integer `div`/`rem`
  (the same technique `WeddingPlannerWeb.TimelineComponents.x_pct/1` uses for its axis) — never a float
  division, which could round a width like `33.333…%` into a visibly wrong-looking string.

  The per-category bar nests two levels of percentage width rather than positioning anything
  absolutely: an outer track (`bg-surface`, always the chart's full row width) contains an inner `flex`
  wrapper sized to the category's `:length_basis_points` (its share of the *chart*), and that wrapper's
  own children (the segments) are sized to their own `:basis_points` (their share of *that category's
  own bar*, out of 10 000, per `BudgetChart.categories/2`'s moduledoc). CSS resolves a child's percentage
  width against its immediate parent, so this nesting alone produces the right rendered pixel widths with
  no JavaScript and no absolute positioning — which also sidesteps this codebase's own "an absolutely
  positioned `sr-only` element needs a `relative` ancestor" trap (W10) by simply not using one, other than
  the "nothing yet" placeholder label, whose own ancestor carries `relative` (see `category_bars/1`).

  ## Tokens only, no categorical hue (`DR-77`, design record §2)

  Every segment kind maps to exactly one tone, per the design record's semantic table — never a
  category-specific colour (there is deliberately no palette of 5 hues for 5 categories; identity is
  carried by row position and the name column, not colour):

    * `:paid` → `bg-good`
    * `:outstanding` → `bg-warn`
    * `:not_yet_billed` → a diagonal stripe texture over `--color-ink-soft` (not a new solid colour)
    * `:available` / `:range_ghost` → dashed `border-line-strong`, no fill (absence, not a severity)

  ## Accessibility (`HC-08`)

  Both a bar's overall figure and the preset it was computed under are exposed together via one
  `aria-label` on the bar's own container (`role="img"`) — individual segment `<span>`s are
  `aria-hidden`, since the container's label already states every amount. `HC-08` requires the preset
  used to stay visible wherever a preset-driven figure is shown; since every figure on both charts here
  is for the one selected preset, `:preset_name` is rendered both in the visible caption (`composition_bar/1`'s
  caption, `category_bars/1`'s "By category (<preset>)" caption) and in each `aria-label`, so removing
  either one is a genuine regression (see `WeddingPlannerWeb.Components.BudgetChartComponentsTest`'s
  `FP-83d`-style coverage: a version that only names the preset in the legend fails the `aria-label`
  assertion).
  """

  use Phoenix.Component

  alias WeddingPlannerWeb.Format

  @basis_points_scale 10_000

  @doc """
  The overall-budget composition bar (`BUD-05`, `BUD-02`, design §7 v2): `:chart` is
  `WeddingPlannerWeb.BudgetChart.composition/1`'s result, `:preset_name` the selected preset's display
  name (`HC-08`).

  ## Examples

      <.composition_bar id="budget-composition" chart={chart} preset_name="Likely" />
  """
  attr :id, :string, required: true
  attr :chart, :map, required: true, doc: "WeddingPlannerWeb.BudgetChart.composition/1's result"
  attr :preset_name, :string, required: true

  def composition_bar(assigns) do
    assigns =
      assigns
      |> assign(:caption, composition_caption(assigns.chart, assigns.preset_name))
      |> assign(:over_budget_text, over_budget_text(assigns.chart.over_budget))
      |> assign(:aria_label, composition_aria_label(assigns.chart, assigns.preset_name))

    ~H"""
    <div id={@id}>
      <p id={"#{@id}-caption"} class="text-sm text-ink-soft">{@caption}</p>

      <div
        id={"#{@id}-track"}
        role="img"
        aria-label={@aria_label}
        class="mt-2 flex h-6 w-full overflow-hidden rounded-field bg-surface"
      >
        <span
          :for={{segment, index} <- Enum.with_index(@chart.segments)}
          id={"#{@id}-segment-#{index}"}
          data-kind={segment.kind}
          aria-hidden="true"
          class={segment_class(segment.kind)}
          style={"width: #{width_pct(segment.basis_points)}"}
        ></span>
      </div>

      <p :if={@over_budget_text} id={"#{@id}-over-budget"} class="mt-2 text-sm font-medium text-bad">
        {@over_budget_text}
      </p>
    </div>
    """
  end

  @doc """
  The per-category breakdown bars, plus the shared legend below them (design §7 v2's merged
  "where is the money going, and how does it compare to reality" chart). `:chart` is
  `WeddingPlannerWeb.BudgetChart.categories/2`'s result (one entry per category, in order),
  `:preset_name` the selected preset's display name (`HC-08`).

  A `€0` category (`:empty?`) renders the dashed "nothing yet" placeholder row (design record) instead
  of a zero-width bar.

  ## Examples

      <.category_bars id="budget-categories" chart={rows} preset_name="Likely" />
  """
  attr :id, :string, required: true
  attr :chart, :list, required: true, doc: "WeddingPlannerWeb.BudgetChart.categories/2's result"
  attr :preset_name, :string, required: true

  def category_bars(assigns) do
    assigns = assign(assigns, :caption, "By category (#{assigns.preset_name})")

    ~H"""
    <div id={@id}>
      <p id={"#{@id}-caption"} class="text-sm text-ink-soft">{@caption}</p>

      <div id={"#{@id}-rows"} class="mt-2 space-y-2">
        <.category_row
          :for={row <- @chart}
          id={"#{@id}-row-#{row_dom_id(row)}"}
          row={row}
          preset_name={@preset_name}
        />
      </div>

      <ul
        id={"#{@id}-legend"}
        class="mt-3 flex flex-wrap gap-x-4 gap-y-1.5 text-xs text-ink-soft"
      >
        <li :for={{kind, label} <- legend_items()} class="flex items-center gap-1.5">
          <span class={["inline-block size-2.5 rounded-full", legend_swatch_class(kind)]}></span>
          {label}
        </li>
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :row, :map, required: true
  attr :preset_name, :string, required: true

  defp category_row(assigns) do
    assigns =
      assigns
      |> assign(:aria_label, category_row_aria_label(assigns.row, assigns.preset_name))
      |> assign(:amount_text, Format.money(assigns.row.forecast))

    ~H"""
    <div id={@id} class="flex items-center gap-3">
      <span
        id={"#{@id}-name"}
        title={@row.name}
        class="w-20 shrink-0 truncate text-sm text-ink sm:w-28"
      >
        {@row.name}
      </span>

      <div
        :if={@row.empty?}
        id={"#{@id}-empty"}
        role="img"
        aria-label={@aria_label}
        class="relative h-3 min-w-0 flex-1 rounded-field border border-dashed border-line-strong"
      >
        <span class="absolute inset-0 flex items-center truncate px-2 text-xs text-ink-faint">
          nothing yet
        </span>
      </div>

      <div
        :if={not @row.empty?}
        id={"#{@id}-track"}
        role="img"
        aria-label={@aria_label}
        class="h-3 min-w-0 flex-1 rounded-field bg-surface"
      >
        <div class="flex h-full" style={"width: #{width_pct(@row.length_basis_points)}"}>
          <span
            :for={{segment, index} <- Enum.with_index(@row.segments)}
            id={"#{@id}-segment-#{index}"}
            data-kind={segment.kind}
            aria-hidden="true"
            class={segment_class(segment.kind)}
            style={"width: #{width_pct(segment.basis_points)}"}
          ></span>
        </div>
      </div>

      <span
        id={"#{@id}-amount"}
        class="tabular-nums w-24 shrink-0 truncate text-right text-sm text-ink"
      >
        {@amount_text}
      </span>
    </div>
    """
  end

  # -- tone classes (design record §2 — Budget chart rows) --------------------------------------

  defp segment_class(:paid), do: "bg-good"
  defp segment_class(:outstanding), do: "bg-warn"

  defp segment_class(:not_yet_billed),
    do: "bg-[repeating-linear-gradient(135deg,var(--color-ink-soft)_0_2px,transparent_2px_6px)]"

  defp segment_class(:available), do: "border border-dashed border-line-strong"
  defp segment_class(:range_ghost), do: "border border-dashed border-line-strong"

  defp legend_swatch_class(:paid), do: "bg-good"
  defp legend_swatch_class(:outstanding), do: "bg-warn"

  defp legend_swatch_class(:not_yet_billed),
    do: "bg-[repeating-linear-gradient(135deg,var(--color-ink-soft)_0_2px,transparent_2px_6px)]"

  defp legend_swatch_class(:available), do: "border border-dashed border-line-strong"
  defp legend_swatch_class(:range_ghost), do: "border border-dashed border-line-strong"

  defp legend_items do
    [
      {:paid, "Paid"},
      {:outstanding, "Outstanding (unpaid)"},
      {:not_yet_billed, "Forecast, not yet billed"},
      {:available, "Available"},
      {:range_ghost, "Possible range to Maximum"}
    ]
  end

  # -- captions and accessible labels ------------------------------------------------------------

  defp composition_caption(%{no_budget?: true, scale: scale}, preset_name) do
    "Forecast · #{Format.money(scale)} (no overall budget set) · #{preset_name}"
  end

  defp composition_caption(%{scale: scale}, preset_name) do
    "Overall budget · #{Format.money(scale)} · #{preset_name}"
  end

  defp over_budget_text(nil), do: nil
  defp over_budget_text(amount), do: "Over budget by #{Format.money(amount)}"

  defp composition_aria_label(chart, preset_name) do
    amounts = Enum.map_join(chart.segments, ", ", &segment_phrase/1)
    base = "#{preset_name} — #{amounts}"

    case chart.over_budget do
      nil -> base
      amount -> "#{base}, over budget by #{Format.money(amount)}"
    end
  end

  defp category_row_aria_label(%{empty?: true, name: name}, preset_name) do
    "#{name} — nothing yet (#{preset_name})"
  end

  defp category_row_aria_label(row, preset_name) do
    amounts = Enum.map_join(row.segments, ", ", &segment_phrase/1)
    "#{row.name} — #{Format.money(row.forecast)} (#{preset_name}) — #{amounts}"
  end

  defp segment_phrase(%{kind: kind, amount: amount}) do
    "#{segment_label(kind)} #{Format.money(amount)}"
  end

  defp segment_label(:paid), do: "Paid"
  defp segment_label(:outstanding), do: "Outstanding (unpaid)"
  defp segment_label(:not_yet_billed), do: "Forecast, not yet billed"
  defp segment_label(:available), do: "Available"
  defp segment_label(:range_ghost), do: "Possible range to Maximum"

  # -- DOM ids and widths -------------------------------------------------------------------------

  defp row_dom_id(%{id: id}), do: to_string(id)

  # A basis-point count (0..10_000, hundredths of a percent) as a CSS percentage string, by integer
  # `div`/`rem` — never a float division (`NFR-12`'s spirit; the same technique
  # `WeddingPlannerWeb.TimelineComponents.x_pct/1` uses for the timeline axis).
  defp width_pct(bp) when is_integer(bp) and bp >= 0 and bp <= @basis_points_scale do
    "#{div(bp, 100)}.#{pad2(rem(bp, 100))}%"
  end

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: "#{n}"
end
