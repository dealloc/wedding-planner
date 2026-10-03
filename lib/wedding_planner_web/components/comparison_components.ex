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
  (`WeddingPlannerWeb.DisplayComponents.gap_severity/1`) are the cell's own.

  ## Interactions (task 66, `DR-56`, `DR-57`)

  Every cell carries a small override toggle button (`aria-pressed` = the cell's
  `effectively_wanted?`, `hero-check-circle`/`hero-minus-circle`, title on hover/focus)
  calling `WeddingPlanner.Offers.toggle_override/3` (wired by
  `WeddingPlannerWeb.Live.CategoryLive`'s `"toggle_override"` event) and one small "Edit"
  link per line (or one "Add" link when the cell has none) that deep-links into the
  offer page's own line editor — **no in-matrix field editing** (DR-57; question Q2 in
  `w10-plan.md` §10 was answered no). These affordances sit at reduced opacity at rest
  and reach full opacity on hover or focus-within (`group`/`group-hover`,
  `focus-within`) — small, not hidden, so they stay reachable on a touch device that
  never hovers (the design record's "too clunky" feedback on matrix v1 forbids adding
  bulk back to the cell). The override marker itself stays the *only* accent-toned
  element here (design record §2: "accent is for the marker only") — the toggle button
  is neutral-toned, its icon shape alone carries the on/off state.

  The header's status `<form class="contents" phx-change="set_offer_status">` (one per
  column, `DR-40`, `DR-62`) now also offers *confirmed* — picking it calls
  `WeddingPlanner.Offers.confirm_offer/2` (`WeddingPlannerWeb.Live.CategoryLive`'s own
  branch on the event) instead of `update_offer/3`. A `:confirmed` offer instead shows
  the read-only `status_pill/1` plus a small "Un-confirm…" button
  (`WeddingPlanner.Offers.unconfirm_effects/1` / `unconfirm_blockers/1` back the
  `CoreComponents.destructive_confirm/1` dialog or the blocked panel, `DR-62`, `DR-65`),
  never a select missing the option currently selected in the data. The "Other charges"
  row's optional ad hoc lines (`CST-22`) get their own small checkbox-style `phx-click`
  toggle (`"toggle_ad_hoc"`, `WeddingPlanner.Offers.set_line_enabled/3`) — deliberately
  not a form/`phx-change`, per this task's own decision record.

  ## Confirmation, planning pick and scope (task 75, `DR-62`, `DR-64`, `DR-66`)

  A confirmed column's header also carries an "Un-confirm…" button, opening one dialog
  at a time (`@confirming_unconfirm_offer_id`): `CoreComponents.destructive_confirm/1`
  naming `unconfirm_effects/1` when nothing blocks it, or a blocked panel
  (`#matrix-unconfirm-blocked`) listing `unconfirm_blockers/1` with only Cancel when an
  invoice still links to it (`DR-65` final: refused, never unlinked automatically). Each
  non-rejected, non-confirmed column shows a planning-pick control while the category has
  no confirmed offer at all — hidden the moment any offer in it is confirmed (`DR-66`).
  A confirmed column's cell shows the frozen scope instead of the override toggle
  (`DR-64`): `cell.scope == :in` a small lock icon, `cell.scope == :out` nothing except
  that any line the presenter marks `:outside_scope` gets its own "Add to confirmed
  scope" button (`Offers.add_to_confirmed_scope/3`); its total gets a "Committed"
  caption.
  """

  use Phoenix.Component

  import WeddingPlannerWeb.CoreComponents, only: [icon: 1, input: 1, destructive_confirm: 1]

  import WeddingPlannerWeb.DisplayComponents,
    only: [formula: 1, range: 1, preset_selector: 1, gap_severity: 1, status_pill: 1]

  alias WeddingPlanner.Offers.OfferLine
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
  attr :category_has_confirmed_offer?, :boolean, required: true
  attr :confirming_unconfirm_offer_id, :any, required: true
  attr :unconfirm_blockers, :list, required: true
  attr :unconfirm_effects, :list, required: true

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
          <%!-- Only ever reached at :confirmed (DR-40's own read-only-pill branch), so
          the tone is the fixed one DR-40's semantic table gives that status — never a
          generic `offer_status_tone/1` lookup, which the compiler would then (rightly)
          flag as carrying dead clauses for every other status. --%>
          <.status_pill
            :if={column.offer.status == :confirmed}
            id={"matrix-col-#{column.offer.id}-status"}
            label={offer_status_label(column.offer.status)}
            tone={:good}
          />

          <.form
            :if={column.offer.status != :confirmed}
            for={to_form(%{}, as: :matrix_status)}
            id={"matrix-status-form-#{column.offer.id}"}
            phx-change="set_offer_status"
            phx-value-offer-id={column.offer.id}
          >
            <label for={"matrix-status-#{column.offer.id}"} class="sr-only">Status</label>
            <.input
              type="select"
              id={"matrix-status-#{column.offer.id}"}
              name="status"
              value={Atom.to_string(column.offer.status)}
              options={status_select_options()}
              aria-label="Status"
              class="block max-w-full truncate border-0 border-b border-dashed border-line-strong bg-transparent p-0 pb-0.5 text-xs text-ink-soft focus:border-accent focus:outline-none focus:ring-0"
            />
          </.form>

          <span id={"matrix-col-#{column.offer.id}-vat-basis"} class="text-xs text-ink-faint">
            {offer_vat_basis_label(column.offer)}
          </span>
        </div>

        <button
          :if={column.offer.status == :confirmed}
          type="button"
          id={"matrix-col-#{column.offer.id}-unconfirm"}
          phx-click="confirm_unconfirm"
          phx-value-offer-id={column.offer.id}
          class="mt-1 block text-xs font-medium text-ink-soft hover:text-ink hover:underline"
        >
          Un-confirm…
        </button>

        <div
          :if={
            column.offer.status not in [:confirmed, :rejected] and
              not @category_has_confirmed_offer?
          }
          class="mt-1"
        >
          <button
            :if={not column.offer.planning_pick}
            type="button"
            id={"matrix-col-#{column.offer.id}-planning-pick"}
            phx-click="set_planning_pick"
            phx-value-offer-id={column.offer.id}
            class="text-xs font-medium text-ink-soft hover:text-ink hover:underline"
          >
            Use as planning pick
          </button>

          <div :if={column.offer.planning_pick} class="flex items-center gap-1.5">
            <.status_pill
              id={"matrix-col-#{column.offer.id}-planning-pick-badge"}
              label="Planning pick"
              tone={:info}
            />
            <button
              type="button"
              id={"matrix-col-#{column.offer.id}-planning-pick-clear"}
              phx-click="clear_planning_pick"
              phx-value-offer-id={column.offer.id}
              class="text-xs font-medium text-ink-soft hover:text-ink hover:underline"
            >
              Clear
            </button>
          </div>
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

        <%!-- One dialog at a time (`@confirming_unconfirm_offer_id`, DR-62). DR-65
        final: refused with a blocked panel (no confirm button) while an invoice still
        links to the offer, never the destructive_confirm dialog. --%>
        <.destructive_confirm
          :if={@confirming_unconfirm_offer_id == column.offer.id and @unconfirm_blockers == []}
          id="matrix-unconfirm-dialog"
          title={"Un-confirm '#{column.offer.vendor_name}'?"}
          body="Its confirmed scope is discarded and it returns to shortlisted."
          affected={@unconfirm_effects}
          confirm="unconfirm_confirmed"
          confirm_value={column.offer.id}
          confirm_label="Un-confirm"
          cancel="cancel_unconfirm"
        />

        <div
          :if={@confirming_unconfirm_offer_id == column.offer.id and @unconfirm_blockers != []}
          id="matrix-unconfirm-blocked"
          role="alertdialog"
          aria-labelledby="matrix-unconfirm-blocked-title"
          class="mt-2 rounded-field border border-line-strong bg-surface p-4 text-sm"
        >
          <p id="matrix-unconfirm-blocked-title" class="font-semibold text-ink">
            Can't un-confirm '{column.offer.vendor_name}'
          </p>
          <ul class="mt-1 list-disc space-y-0.5 pl-5 text-ink-soft">
            <li :for={blocker <- @unconfirm_blockers}>{blocker}</li>
          </ul>
          <div class="mt-3">
            <button
              type="button"
              id="matrix-unconfirm-blocked-cancel"
              phx-click="cancel_unconfirm"
              class="inline-flex min-h-11 items-center justify-center rounded-field border border-line-strong px-3 text-sm font-medium text-ink-soft transition hover:bg-surface"
            >
              Cancel
            </button>
          </div>
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
    lines = Enum.zip(assigns.cell.lines, fragments)

    assigns =
      assigns
      |> assign(:fragments, fragments)
      |> assign(:zipped_lines, lines)

    ~H"""
    <div
      id={"matrix-cell-#{@service_id}-#{@offer_id}"}
      class={["group space-y-1.5 p-3 text-sm", @rejected? && "opacity-60"]}
    >
      <p :if={@fragments == []} class="text-ink-faint italic">No line</p>
      <p :if={@fragments != []} class="text-ink">
        <.fragment_join lines={@zipped_lines} service_id={@service_id} offer_id={@offer_id} />
      </p>

      <.line_note :for={entry <- @cell.lines} line={entry.line} />

      <.gap_severity
        :if={@cell.gap}
        id={"matrix-cell-#{@service_id}-#{@offer_id}-gap"}
        severity={@cell.gap.severity}
      />

      <div class="flex flex-wrap items-center gap-2 opacity-70 transition-opacity duration-150 group-hover:opacity-100 group-focus-within:opacity-100">
        <%!-- DR-64: a confirmed column shows its frozen scope instead of the override
        toggle — `cell.scope` is `nil` for a non-confirmed offer, so these two branches
        never both render for the same cell. `:out` renders neither (the "Add to
        confirmed scope" action lives per outside-scope *line*, in `fragment_join/1`
        below, not per cell). --%>
        <span
          :if={@cell.scope == :in}
          id={"matrix-cell-#{@service_id}-#{@offer_id}-scope"}
          title="In the confirmed scope"
          class="inline-flex size-6 items-center justify-center rounded-full text-good"
        >
          <.icon name="hero-lock-closed" class="size-4" />
          <span class="sr-only">In the confirmed scope</span>
        </span>

        <button
          :if={is_nil(@cell.scope)}
          type="button"
          id={"matrix-toggle-#{@service_id}-#{@offer_id}"}
          phx-click="toggle_override"
          phx-value-service-id={@service_id}
          phx-value-offer-id={@offer_id}
          aria-pressed={to_string(@cell.effectively_wanted?)}
          title={override_toggle_title(@cell.effectively_wanted?)}
          class="inline-flex size-6 items-center justify-center rounded-full text-ink-soft transition hover:bg-surface hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-1 focus-visible:ring-offset-surface-raised"
        >
          <.icon
            name={if @cell.effectively_wanted?, do: "hero-check-circle", else: "hero-minus-circle"}
            class="size-4"
          />
          <span class="sr-only">{override_toggle_title(@cell.effectively_wanted?)}</span>
        </button>

        <span
          :if={(is_nil(@cell.scope) and @cell.override) && @cell.override.deviates?}
          id={"matrix-cell-#{@service_id}-#{@offer_id}-override-marker"}
          title="Overridden for this offer"
          class="inline-flex size-4 items-center justify-center rounded-full bg-accent text-white"
        >
          <span class="sr-only">Overridden for this offer</span>
        </span>

        <.link
          :for={{entry, index} <- Enum.with_index(@cell.lines, 1)}
          navigate={"/offers/#{@offer_id}?line=#{entry.line.id}"}
          id={"matrix-edit-line-#{entry.line.id}"}
          class="text-xs font-medium text-ink-soft hover:text-ink hover:underline"
        >
          {edit_link_label(entry.line, index, length(@cell.lines))}
        </.link>

        <.link
          :if={@cell.lines == []}
          navigate={"/offers/#{@offer_id}?add_line=#{@service_id}"}
          id={"matrix-add-line-#{@service_id}-#{@offer_id}"}
          class="text-xs font-medium text-ink-soft hover:text-ink hover:underline"
        >
          Add
        </.link>
      </div>
    </div>
    """
  end

  # CST-26: a line's notes stay out of the way until asked for — a native `<details>`, so
  # opening one needs no server round trip and no state.
  attr :line, :any, required: true

  defp line_note(assigns) do
    ~H"""
    <details :if={@line.notes not in [nil, ""]} id={"matrix-line-note-#{@line.id}"} class="group/note">
      <summary class="inline-flex cursor-pointer list-none items-center gap-1 text-xs font-medium text-ink-soft transition hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent [&::-webkit-details-marker]:hidden">
        <.icon name="hero-chat-bubble-left-ellipsis" class="size-4" /> Note
      </summary>
      <p class="mt-1 whitespace-pre-line rounded-field bg-surface p-2 text-xs text-ink-soft">
        {@line.notes}
      </p>
    </details>
    """
  end

  # One line: plain "Edit". Several lines in one cell: tell the links apart by the
  # line's own label, else its pricing basis, else its position.
  defp edit_link_label(_line, _index, 1), do: "Edit"

  defp edit_link_label(%{label: label}, _index, _count) when is_binary(label) and label != "",
    do: "Edit #{label}"

  defp edit_link_label(%{basis: basis}, _index, _count)
       when basis in [:per_adult, :per_child, :per_attendee],
       do: "Edit #{basis |> Atom.to_string() |> String.replace("_", " ")}"

  defp edit_link_label(_line, index, _count), do: "Edit #{index}"

  defp override_toggle_title(true), do: "On for this offer"
  defp override_toggle_title(false), do: "Off for this offer"

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
    assigns = assign(assigns, :rows, Enum.zip(assigns.lines, fragments))

    ~H"""
    <p :if={@rows == []} class="text-ink-faint italic">None</p>
    <ul :if={@rows != []} class="space-y-1">
      <li :for={{entry, fragment} <- @rows} class="flex items-center gap-1.5">
        <button
          :if={OfferLine.optional_ad_hoc?(entry.line)}
          type="button"
          id={"matrix-adhoc-toggle-#{entry.line.id}"}
          role="checkbox"
          aria-checked={to_string(entry.line.enabled)}
          phx-click="toggle_ad_hoc"
          phx-value-id={entry.line.id}
          title={ad_hoc_toggle_title(entry.line.enabled)}
          class="inline-flex size-4 shrink-0 items-center justify-center rounded-sm border border-line-strong text-ink-soft transition hover:bg-surface focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-1 focus-visible:ring-offset-surface-raised"
        >
          <.icon :if={entry.line.enabled} name="hero-check" class="size-3" />
          <span class="sr-only">{ad_hoc_toggle_title(entry.line.enabled)}</span>
        </button>

        <span class={fragment_classes(fragment)}>{fragment.text}</span>
        <.line_note line={entry.line} />
      </li>
    </ul>
    """
  end

  defp ad_hoc_toggle_title(true), do: "Turn off"
  defp ad_hoc_toggle_title(false), do: "Turn on"

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

      <p
        :if={@column.offer.status == :confirmed}
        id={"matrix-total-#{@column.offer.id}-committed"}
        class="text-xs text-ink-soft"
      >
        Committed
      </p>

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

  # `lines` zips each cell's `Comparison.line_entry/0` with its own rendered fragment
  # (same order, `ComparisonPresenter.cell_fragments/2`'s contract) — the entry is
  # needed here, not just the fragment, so an `:outside_scope` line (`CST-43`, `DR-64`)
  # can carry its own "Add to confirmed scope" button (`#matrix-add-to-scope-<line_id>`).
  attr :lines, :list, required: true
  attr :service_id, :any, required: true
  attr :offer_id, :any, required: true

  defp fragment_join(assigns) do
    ~H"""
    <span :for={{{entry, fragment}, index} <- Enum.with_index(@lines)}>
      <span :if={index > 0} class="text-ink-faint" aria-hidden="true"> · </span>
      <span class={fragment_classes(fragment)}>{fragment.text}</span>
      <button
        :if={entry.inclusion == :outside_scope}
        type="button"
        id={"matrix-add-to-scope-#{entry.line.id}"}
        phx-click="add_to_confirmed_scope"
        phx-value-service-id={@service_id}
        phx-value-offer-id={@offer_id}
        class="ml-1 text-xs font-medium text-accent hover:underline"
      >
        Add to confirmed scope
      </button>
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

  # DR-62 (task 75): the header select now offers *confirmed* too — picking it is
  # handled by `WeddingPlannerWeb.Live.CategoryLive`'s own `"set_offer_status"` branch,
  # which calls `Offers.confirm_offer/2` instead of `update_offer/3`. This form only
  # ever renders for a non-confirmed offer, so the current status is always one of these
  # four values (never a select missing the option currently selected in the data).
  defp status_select_options do
    Enum.map(
      [:considering, :shortlisted, :confirmed, :rejected],
      &{offer_status_label(&1), Atom.to_string(&1)}
    )
  end

  # CST-54: "incl. VAT" / "excl. VAT, 21 %".
  defp offer_vat_basis_label(%{vat_basis: :inclusive}), do: "incl. VAT"

  defp offer_vat_basis_label(%{vat_basis: :exclusive, vat_rate_bp: bp}),
    do: "excl. VAT, #{VatRate.format(bp)}"
end
