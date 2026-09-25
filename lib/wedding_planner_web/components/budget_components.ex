defmodule WeddingPlannerWeb.Components.BudgetComponents do
  @moduledoc """
  The display idioms for `/budget` (task 82, `DR-76`): `tile/1` (the four overall stat
  tiles), `role_values/1` (`DR-71`'s three role-preset values, or the collapsed single
  value, or the task-57 `#offer-cost-missing-range` idiom when a role is unassigned),
  `category_card/1` (one expandable `<details>` per category) and `overdue_banner/1`
  (`BIL-06`'s "needs attention" banner).

  All of them render `WeddingPlannerWeb.BudgetOverview.build/3`'s output — no
  computation happens here, only display. See that module's moduledoc for exactly what
  `ranged()` values mean and which formula disclosure a role-value button opens.

  ## `role_values/1`'s one interaction (`DR-71`, `NFR-32`)

  Each of the three (or, collapsed, the one) values is a `<button type="button">` whose
  `phx-click` both pushes `"select_preset"` (with the preset id and the target formula's
  id) **and** immediately sets that formula's `<details>` `open` attribute client-side
  (`JS.set_attribute/2`) — one click both re-points the view at that preset and expands
  its calculation, satisfying `NFR-32` without a second interaction. `WeddingPlannerWeb.Live.BudgetLive`
  keeps a transient `:open_formula_ids` assign so a disclosure a role-value button opened
  stays open across an unrelated live update (`DR-71`; a plain `<details open={false}>`
  re-render would otherwise drop the attribute the `JS` command set — the "known trap"
  this task calls out).
  """

  use WeddingPlannerWeb, :html

  import WeddingPlannerWeb.Components.InvoiceComponents, only: [invoice_row: 1]

  @doc """
  One overall stat tile (`BUD-05`): a label, and whatever figure the caller renders into
  `:inner_block` — either `role_values/1` (Available, Forecast) or a plain value (Spent,
  Outstanding).
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :bad?, :boolean, default: false, doc: "over budget / negative available (DR-77)"
  slot :inner_block, required: true

  def tile(assigns) do
    ~H"""
    <div id={@id} class="rounded-field border border-line bg-surface-raised p-4">
      <p class="text-xs font-medium tracking-wide text-ink-soft uppercase">{@label}</p>
      <div class={["mt-1.5 tabular-nums", @bad? && "text-bad"]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a `WeddingPlannerWeb.BudgetOverview.ranged()` value: `:missing` (the
  `#offer-cost-missing-range` idiom, `DR-54`), the collapsed single value ("under every
  preset") when the three roles agree, or the three Minimum/Likely/Maximum buttons
  (`DR-71`). Each button both selects that role's preset for the view and opens
  `:formula_id`'s disclosure in one click.
  """
  attr :id, :string, required: true
  attr :ranged, :any, required: true
  attr :formula_id, :string, required: true
  attr :bad?, :boolean, default: false, doc: "negative Available / over budget (design record §2)"

  def role_values(assigns) do
    ~H"""
    <div id={@id}>
      <p :if={@ranged == :missing} id={"#{@id}-missing"} class="text-sm text-ink-soft">
        A stored preset is missing one of the three roles, so this range can't be shown right now.
      </p>

      <div :if={@ranged != :missing and @ranged.equal?}>
        <button
          type="button"
          id={"#{@id}-value"}
          phx-click={select_preset_js(@ranged.likely.preset_id, @formula_id)}
          class={[
            "text-lg font-semibold tabular-nums transition hover:text-accent focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent",
            if(@bad?, do: "text-bad", else: "text-ink")
          ]}
        >
          {@ranged.likely.value}
        </button>
        <p class="text-xs text-ink-faint">under every preset</p>
      </div>

      <div :if={@ranged != :missing and !@ranged.equal?} class="flex flex-wrap gap-x-3 gap-y-1">
        <.role_value_button
          id={"#{@id}-minimum"}
          role_label="Min"
          figure={@ranged.minimum}
          formula_id={@formula_id}
          bad?={@bad?}
        />
        <.role_value_button
          id={"#{@id}-likely"}
          role_label="Likely"
          figure={@ranged.likely}
          formula_id={@formula_id}
          bad?={@bad?}
        />
        <.role_value_button
          id={"#{@id}-maximum"}
          role_label="Max"
          figure={@ranged.maximum}
          formula_id={@formula_id}
          bad?={@bad?}
        />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :role_label, :string, required: true
  attr :figure, :map, required: true
  attr :formula_id, :string, required: true
  attr :bad?, :boolean, default: false

  defp role_value_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click={select_preset_js(@figure.preset_id, @formula_id)}
      class="rounded-chip px-1.5 py-1 text-left transition hover:bg-surface focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
    >
      <span class="block text-[0.65rem] font-medium tracking-wide text-ink-faint uppercase">
        {@role_label}
      </span>
      <span class={[
        "text-base font-semibold tabular-nums",
        if(@bad?, do: "text-bad", else: "text-ink")
      ]}>
        {@figure.value}
      </span>
    </button>
    """
  end

  defp select_preset_js(preset_id, formula_id) do
    JS.push("select_preset", value: %{"preset_id" => preset_id, "formula_id" => formula_id})
    |> JS.set_attribute({"open", "true"}, to: "##{formula_id}-disclosure")
  end

  @doc """
  The "needs attention" banner (`BIL-06`): every overdue unpaid invoice, worst first,
  above everything else on the page. Absent entirely when `:overdue` is `[]`.
  """
  attr :id, :string, default: "budget-overdue"
  attr :overdue, :list, required: true

  def overdue_banner(assigns) do
    ~H"""
    <div :if={@overdue != []} id={@id} class="rounded-field border border-bad bg-bad-soft p-4">
      <p class="flex items-center gap-2 text-sm font-semibold text-bad">
        <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
        Needs attention — overdue unpaid invoices
      </p>
      <ul class="mt-3 space-y-2">
        <li
          :for={row <- @overdue}
          id={row.id}
          class="flex flex-wrap items-baseline justify-between gap-2 text-sm"
        >
          <span class="text-ink">
            <.link navigate={~p"/invoices/#{row.invoice_id}"} class="font-medium hover:underline">
              {row.label}
            </.link>
            <span :if={row.category_name} class="text-ink-soft"> · {row.category_name}</span>
          </span>
          <span class="tabular-nums text-bad">
            {row.amount} — {row.days_overdue} {pluralize_days(row.days_overdue)} overdue
          </span>
        </li>
      </ul>
    </div>
    """
  end

  defp pluralize_days(1), do: "day"
  defp pluralize_days(_n), do: "days"

  @doc """
  One category card (`DR-76`): a native `<details>` (zero JS) whose `<summary>` shows the
  name, the branch badge and the forecast range/single value; the body has the full
  layer list, each confirmed offer, the planning pick (when the branch is
  `:planning_pick`), the category's invoices (`InvoiceComponents.invoice_row/1`, `BIL-06`)
  and the Committed/Forecast formulas under the selected preset (`BUD-08`).

  `:open_formula_ids` is `WeddingPlannerWeb.Live.BudgetLive`'s transient `MapSet` of
  formula ids a role-value button has opened (see the moduledoc).
  """
  attr :card, :map, required: true
  attr :snapshot, :any, required: true
  attr :today, :any, required: true
  attr :open_formula_ids, :any, required: true

  def category_card(assigns) do
    ~H"""
    <details
      id={"budget-category-#{@card.id}"}
      class="rounded-field border border-line bg-surface-raised"
    >
      <summary class="cursor-pointer list-none px-4 py-3 select-none focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent">
        <span class="flex min-w-0 flex-wrap items-center gap-2">
          <span class="truncate font-semibold text-ink" title={@card.name}>{@card.name}</span>
          <.status_pill
            id={"budget-category-#{@card.id}-badge"}
            label={@card.badge.label}
            tone={@card.badge.tone}
          />
          <%!-- C6 (DR-78): the budget "needs attention" marker for an invalid line goes here. --%>
        </span>
        <%!--
        Plain text, never a button: a click anywhere in <summary> already toggles the
        <details>, so this line must not carry its own phx-click (unlike the tappable
        role-value figures below, a sibling of <summary> for exactly that reason).
        --%>
        <p
          id={"budget-category-#{@card.id}-summary-forecast"}
          class="mt-1 tabular-nums text-sm text-ink-soft"
        >
          {@card.summary_forecast}
        </p>
      </summary>

      <%!--
      The forecast role-values are a SIBLING of <summary>, never nested inside it, so
      clicking one of its buttons never toggles this <details> — only a real <summary>
      click does that natively (zero JS, the task's own suggested fix for the trap).
      --%>
      <div class="border-t border-line px-4 py-2">
        <p class="text-xs font-medium tracking-wide text-ink-soft uppercase">Forecast</p>
        <.role_values
          id={"budget-category-#{@card.id}-forecast-tile"}
          ranged={@card.forecast}
          formula_id={@card.forecast_formula_id}
        />
      </div>

      <div class="space-y-4 border-t border-line px-4 py-4">
        <dl class="grid grid-cols-2 gap-x-4 gap-y-3 text-sm sm:grid-cols-3">
          <div>
            <dt class="text-ink-soft">Target</dt>
            <dd class="tabular-nums font-medium text-ink">{@card.target}</dd>
          </div>
          <div class="col-span-2 sm:col-span-1">
            <dt class="text-ink-soft">Committed</dt>
            <dd>
              <.role_values
                id={"budget-category-#{@card.id}-committed-tile"}
                ranged={@card.committed}
                formula_id={@card.committed_formula_id}
              />
            </dd>
          </div>
          <div>
            <dt class="text-ink-soft">Invoiced</dt>
            <dd class="tabular-nums font-medium text-ink">{@card.invoiced}</dd>
          </div>
          <div>
            <dt class="text-ink-soft">Paid</dt>
            <dd class="tabular-nums font-medium text-ink">{@card.paid}</dd>
          </div>
          <div>
            <dt class="text-ink-soft">Outstanding</dt>
            <dd class="tabular-nums font-medium text-ink">{@card.outstanding}</dd>
          </div>
        </dl>

        <div
          :if={@card.confirmed_offers != []}
          id={"budget-category-#{@card.id}-offers"}
          class="space-y-3"
        >
          <div
            :for={offer <- @card.confirmed_offers}
            id={offer.id}
            class="rounded-field border border-line bg-surface p-3"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <.link
                navigate={~p"/offers/#{offer.offer_id}"}
                class="font-medium text-ink hover:underline"
              >
                {offer.vendor_name}
              </.link>
              <.status_pill
                :if={offer.invoicing_complete?}
                id={"#{offer.id}-invoicing-complete"}
                label="Invoicing complete"
                tone={:good}
              />
            </div>
            <div class="mt-2">
              <p class="text-xs font-medium tracking-wide text-ink-soft uppercase">Committed</p>
              <.role_values
                id={"#{offer.id}-committed"}
                ranged={offer.committed}
                formula_id={offer.formula_id}
              />
            </div>
            <p class="mt-2 text-sm text-ink-soft">Invoiced {offer.invoiced}</p>
            <p class="mt-1 text-sm text-ink-faint">{offer.forecast_source_label}</p>
          </div>
        </div>

        <div
          :if={@card.planning_pick}
          id={"budget-category-#{@card.id}-planning-pick"}
          class="rounded-field border border-line bg-surface p-3"
        >
          <p class="font-medium text-ink">
            Planning pick —
            <.link navigate={~p"/offers/#{@card.planning_pick.offer_id}"} class="hover:underline">
              {@card.planning_pick.vendor_name}
            </.link>
          </p>
          <div class="mt-2">
            <p class="text-xs font-medium tracking-wide text-ink-soft uppercase">Total</p>
            <.role_values
              id={"budget-category-#{@card.id}-planning-pick-total"}
              ranged={@card.planning_pick.total}
              formula_id={@card.planning_pick.formula_id}
            />
          </div>
        </div>

        <div id={"budget-category-#{@card.id}-invoices"}>
          <h3 class="mb-2 text-sm font-semibold text-ink-soft">Invoices</h3>
          <p :if={@card.invoices == []} class="text-sm text-ink-faint">No invoices yet</p>
          <div class="space-y-3">
            <.invoice_row
              :for={invoice <- @card.invoices}
              id={"budget-category-#{@card.id}-invoice-#{invoice.id}"}
              invoice={invoice}
              snapshot={@snapshot}
              today={@today}
              show_offer?={false}
            />
          </div>
        </div>

        <.formula
          id={@card.committed_formula_id}
          total_label="Committed"
          open={MapSet.member?(@open_formula_ids, @card.committed_formula_id)}
          {@card.committed_formula}
        />

        <.formula
          id={@card.forecast_formula_id}
          total_label="Forecast"
          open={MapSet.member?(@open_formula_ids, @card.forecast_formula_id)}
          {@card.forecast_formula}
        />
      </div>
    </details>
    """
  end
end
