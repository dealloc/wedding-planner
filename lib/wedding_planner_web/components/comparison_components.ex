defmodule WeddingPlannerWeb.Components.ComparisonComponents do
  @moduledoc """
  The comparison matrix's own markup (task 65; `DR-57`;
  `docs/modules/offers-and-comparison.md` `CST-50`…`CST-55`): the column header row,
  a service cell, the "other charges" row and the totals row. `WeddingPlannerWeb.Live.CategoryLive`
  wires assigns and events; every figure and flag rendered here comes from
  `WeddingPlanner.Valuation.Comparison.build/4`'s pure view model — nothing here
  computes, prices or decides a gap.

  ## The shared grid (invitations-matrix technique, `NFR-31`)

  `matrix_grid_style/1` is one inline `grid-template-columns` — a sticky first
  (service) column plus one column per visible offer — shared by the header row, every
  band's service rows (`WeddingPlannerWeb.Live.CategoryLive`'s own `service_row/1`) and
  this module's other-charges and totals rows, so independent CSS grids stack into
  visually aligned columns with no wrapping `<table>` (a dynamic column count needs an
  inline style, not a Tailwind class — an interpolated class string cannot be found by
  Tailwind's static scan). The whole matrix scrolls horizontally inside
  `#comparison-matrix`'s own `overflow-x-auto` container (`NFR-31`: desktop-first, but
  usable on a phone), with the service column pinned via `sticky left-0`.

  The service column's own width is a `clamp()` (`~8.5rem` on a phone, `~15rem` on
  desktop, scaling with viewport width in between) rather than a fixed pixel figure —
  this is what the design record's revision after Wannes' hands-on use ("too clunky to
  read even at small scale") and this task's own row-header compaction both need: a
  narrow phone viewport must still show at least one full offer column beside the
  service column, not just the sticky column filling the screen. Every row's sticky
  first child stretches to fill this track automatically (CSS Grid's default
  `justify-items: stretch`) — no per-row width class to keep in sync.

  ## Rejected offers (`CST-55`)

  `:columns` is always the **visible** set the caller has already filtered
  (`CategoryLive`'s `@show_rejected?` transient assign) — every row here (header, cell,
  other charges, totals) renders exactly the offers in `:columns`, in the same order,
  so the grid stays aligned. A rejected column that is shown anyway (the caller decided
  to) is dimmed (`opacity-60`, design record §5).

  ## Price summary wording (`CST-52`) and cell decoration

  A cell's lines go through `WeddingPlannerWeb.ComparisonPresenter.cell_fragments/2`,
  joined here with `" · "`; other charges through `other_charge_fragments/2`, stacked.
  The override marker (`DR-49`, `DR-56`) and the gap badge
  (`WeddingPlannerWeb.DisplayComponents.gap_severity/1`) are the cell's own — task 66
  wires the override toggle and edit deep link; this task only renders their places.
  """

  use Phoenix.Component

  import WeddingPlannerWeb.DisplayComponents,
    only: [formula: 1, range: 1, preset_selector: 1, gap_severity: 1, status_pill: 1]

  alias WeddingPlanner.Offers.VatRate
  alias WeddingPlannerWeb.ComparisonPresenter
  alias WeddingPlannerWeb.Format
  alias WeddingPlannerWeb.FormulaPresenter

  # The service column's width — see moduledoc. A `clamp()`, not a fixed pixel value,
  # so a phone viewport (`~8.5rem`) leaves enough room beside it for at least one full
  # offer column, while desktop (`~15rem`) still fits the compacted row header
  # comfortably.
  @service_column "clamp(8.5rem, 22vw, 15rem)"

  @doc "The shared inline `grid-template-columns` every matrix row uses (see moduledoc)."
  @spec matrix_grid_style([map()]) :: String.t()
  def matrix_grid_style(columns) do
    n = length(columns)

    "display: grid; grid-template-columns: #{@service_column} repeat(#{n}, minmax(220px, 1fr)); " <>
      "min-width: calc(#{@service_column} + #{n} * 220px);"
  end

  # -- header row (CST-54) ---------------------------------------------------------------

  attr :columns, :list, required: true

  def matrix_header_row(assigns) do
    ~H"""
    <div class="grid border-b border-line bg-surface" style={matrix_grid_style(@columns)}>
      <div class="sticky left-0 z-10 bg-surface px-3 py-2 text-xs font-semibold tracking-wide text-ink-soft uppercase">
        Service
      </div>
      <div
        :for={column <- @columns}
        id={"matrix-col-#{column.offer.id}"}
        class={["px-3 py-2", column.rejected? && "opacity-60"]}
      >
        <.link
          navigate={"/offers/#{column.offer.id}"}
          id={"matrix-col-#{column.offer.id}-vendor"}
          class="block truncate text-sm font-semibold text-ink hover:underline"
        >
          {column.offer.vendor_name}
        </.link>

        <div class="mt-1 flex flex-wrap items-center gap-1.5">
          <.status_pill
            id={"matrix-col-#{column.offer.id}-status"}
            label={offer_status_label(column.offer.status)}
            tone={offer_status_tone(column.offer.status)}
          />
          <span id={"matrix-col-#{column.offer.id}-vat-basis"} class="text-xs text-ink-faint">
            {offer_vat_basis_label(column.offer)}
          </span>
        </div>

        <p
          :if={gap_counts_label(column.gap_counts)}
          id={"matrix-col-#{column.offer.id}-gaps"}
          class="mt-1 text-xs text-ink-soft"
        >
          {gap_counts_label(column.gap_counts)}
        </p>

        <div :if={column.needs_attention?} class="mt-1">
          <.gap_severity
            id={"matrix-col-#{column.offer.id}-attention"}
            severity={:invalid}
            label="Needs attention"
          />
        </div>
      </div>
    </div>
    """
  end

  # -- a service cell (CST-52) -----------------------------------------------------------

  attr :service_id, :any, required: true
  attr :offer_id, :any, required: true
  attr :cell, :map, required: true
  attr :vat_basis, :atom, required: true
  attr :rejected?, :boolean, default: false

  def matrix_cell(assigns) do
    fragments = ComparisonPresenter.cell_fragments(assigns.cell.lines, assigns.vat_basis)
    assigns = assign(assigns, :fragments, fragments)

    ~H"""
    <div
      id={"matrix-cell-#{@service_id}-#{@offer_id}"}
      class={["space-y-1.5 p-3 text-sm", @rejected? && "opacity-60"]}
    >
      <p :if={@fragments == []} class="text-ink-faint italic">No line</p>
      <p :if={@fragments != []} class="text-ink">
        <.fragment_join fragments={@fragments} />
      </p>

      <.gap_severity
        :if={@cell.gap}
        id={"matrix-cell-#{@service_id}-#{@offer_id}-gap"}
        severity={@cell.gap.severity}
      />

      <span
        :if={@cell.override && @cell.override.deviates?}
        id={"matrix-cell-#{@service_id}-#{@offer_id}-override-marker"}
        title="Overridden for this offer"
        class="inline-flex size-4 items-center justify-center rounded-full bg-accent text-white"
      >
        <span class="sr-only">Overridden for this offer</span>
      </span>
    </div>
    """
  end

  # -- "other charges" row (CST-50) -------------------------------------------------------

  attr :columns, :list, required: true
  attr :other_charges, :map, required: true

  def matrix_other_charges_row(assigns) do
    ~H"""
    <div class="grid border-b border-line bg-surface" style={matrix_grid_style(@columns)}>
      <div class="sticky left-0 z-10 bg-surface px-3 py-2 text-xs font-semibold tracking-wide text-ink-soft uppercase">
        Other charges
      </div>
      <div
        :for={column <- @columns}
        id={"matrix-other-#{column.offer.id}"}
        class={["p-3 text-sm", column.rejected? && "opacity-60"]}
      >
        <.other_charge_lines
          lines={Map.get(@other_charges, column.offer.id, [])}
          vat_basis={column.offer.vat_basis}
        />
      </div>
    </div>
    """
  end

  attr :lines, :list, required: true
  attr :vat_basis, :atom, required: true

  defp other_charge_lines(assigns) do
    fragments = ComparisonPresenter.other_charge_fragments(assigns.lines, assigns.vat_basis)
    assigns = assign(assigns, :fragments, fragments)

    ~H"""
    <p :if={@fragments == []} class="text-ink-faint italic">None</p>
    <ul :if={@fragments != []} class="space-y-1">
      <li :for={fragment <- @fragments} class={fragment_classes(fragment)}>
        {fragment.text}
      </li>
    </ul>
    """
  end

  # -- totals row (CST-53, DR-54) ---------------------------------------------------------

  attr :columns, :list, required: true
  attr :presets, :list, required: true
  attr :selected_preset, :any, required: true
  attr :range_missing?, :boolean, required: true

  def matrix_totals_row(assigns) do
    ~H"""
    <div class="grid bg-surface" style={matrix_grid_style(@columns)}>
      <div class="sticky left-0 z-10 space-y-2 bg-surface px-3 py-3">
        <.form
          :if={@presets != []}
          for={to_form(%{}, as: :matrix_preset)}
          id="matrix-preset-form"
          phx-change="select_preset"
        >
          <.preset_selector
            id="matrix-preset"
            presets={Enum.map(@presets, &%{id: &1.id, name: &1.name})}
            selected={@selected_preset && @selected_preset.id}
          />
        </.form>

        <p :if={@range_missing?} id="matrix-range-missing" class="text-xs text-ink-soft">
          No preset is set as the range low/high end — set one on the Headcount page.
        </p>
      </div>

      <div :for={column <- @columns} class={["p-3", column.rejected? && "opacity-60"]}>
        <.matrix_column_total
          column={column}
          preset_name={@selected_preset && @selected_preset.name}
        />
      </div>
    </div>
    """
  end

  attr :column, :map, required: true
  attr :preset_name, :any, required: true

  defp matrix_column_total(assigns) do
    formula_assigns = assigns.column.total && FormulaPresenter.present(assigns.column.total)
    range = money_range(assigns.column.range)

    assigns =
      assigns
      |> assign(:formula_assigns, formula_assigns)
      |> assign(:range, range)

    ~H"""
    <div :if={@formula_assigns} id={"matrix-total-#{@column.offer.id}"} class="space-y-2">
      <.formula
        id={"matrix-total-#{@column.offer.id}-formula"}
        total_label={"Total (#{@preset_name})"}
        {@formula_assigns}
      />

      <.range
        :if={@range}
        id={"matrix-total-#{@column.offer.id}-range"}
        label="Range (Minimum – Maximum)"
        minimum={@range.minimum}
        maximum={@range.maximum}
      />

      <p
        :if={@column.gaps != []}
        id={"matrix-total-#{@column.offer.id}-partial"}
        class="text-xs text-ink-soft"
      >
        partial — {length(@column.gaps)} {if length(@column.gaps) == 1, do: "gap", else: "gaps"}
      </p>
    </div>
    """
  end

  # -- shared fragment rendering (ComparisonPresenter fragments) --------------------------

  attr :fragments, :list, required: true

  defp fragment_join(assigns) do
    ~H"""
    <span :for={{fragment, index} <- Enum.with_index(@fragments)}>
      <span :if={index > 0} class="text-ink-faint" aria-hidden="true"> · </span>
      <span class={fragment_classes(fragment)}>{fragment.text}</span>
    </span>
    """
  end

  defp fragment_classes(%{muted?: true}), do: "italic text-ink-faint"
  defp fragment_classes(%{struck?: true}), do: "line-through text-ink-faint"
  defp fragment_classes(%{}), do: nil

  # -- helpers ------------------------------------------------------------------------------

  defp money_range(nil), do: nil

  defp money_range({low, high}) do
    %{minimum: Format.money(low), maximum: Format.money(high)}
  end

  defp gap_counts_label(counts) do
    [
      count_part(counts.must_have, "warning", "warnings"),
      count_part(counts.nice_to_have, "marker", "markers"),
      count_part(counts.unknown, "unknown", "unknowns")
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp count_part(0, _singular, _plural), do: nil
  defp count_part(1, singular, _plural), do: "1 #{singular}"
  defp count_part(n, _singular, plural), do: "#{n} #{plural}"

  defp offer_status_label(:considering), do: "Considering"
  defp offer_status_label(:shortlisted), do: "Shortlisted"
  defp offer_status_label(:rejected), do: "Rejected"
  defp offer_status_label(:confirmed), do: "Confirmed"

  # DR-40's semantic table (`.claude/design/ui-decisions.md` §2), same mapping
  # `WeddingPlannerWeb.Live.CategoryLive`/`WeddingPlannerWeb.Live.OfferLive` use.
  defp offer_status_tone(:considering), do: :neutral
  defp offer_status_tone(:shortlisted), do: :info
  defp offer_status_tone(:confirmed), do: :good
  defp offer_status_tone(:rejected), do: :neutral

  # CST-54: "incl. VAT" / "excl. VAT, 21 %".
  defp offer_vat_basis_label(%{vat_basis: :inclusive}), do: "incl. VAT"

  defp offer_vat_basis_label(%{vat_basis: :exclusive, vat_rate_bp: bp}),
    do: "excl. VAT, #{VatRate.format(bp)}"
end
