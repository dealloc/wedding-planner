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
  `phx-click` both pushes `:click_event` (with the preset id and the target formula's
  id) **and** immediately sets that formula's `<details>` `open` attribute client-side
  (`JS.set_attribute/2`) — one click both re-points the view at that preset and expands
  its calculation, satisfying `NFR-32` without a second interaction. `WeddingPlannerWeb.Live.BudgetLive`
  keeps a transient `:open_formula_ids` assign so a disclosure a role-value button opened
  stays open across an unrelated live update (`DR-71`; a plain `<details open={false}>`
  re-render would otherwise drop the attribute the `JS` command set — the "known trap"
  this task calls out).

  ## `role_values/1` is reusable outside `/budget` (task 84, the W13 amendment)

  Every attr is generic — an id prefix, a `WeddingPlannerWeb.BudgetOverview.ranged()`
  value (three `figure()`s, each carrying `:role`, `:preset_id`, `:preset_name` and
  `:value` — see that module's typedoc), the id of the formula disclosure to open, and
  the click event name (`:click_event`, default `"select_preset"`) — nothing budget-specific
  is read inside this component. Tasks 89 (`/what-if`) and 90 (person marginal cost) reuse
  it as-is; a caller whose own `handle_event` clause matches on a different event name
  only needs to pass `click_event="its_own_event"`. `:loading_target` (default `nil` — no
  dimming) is likewise generic: an optional CSS selector `JS.push/2`'s own `:loading`
  option dims instantly, client-side; `/budget`'s call sites pass `loading_targets/0`
  (below), a caller outside `/budget` passes its own selector or omits it.

  ## Client-side instant loading, server-side `@recomputing` for the rest (orchestrator
  amendment, loading state & latency, 2026-09-25)

  The user's actual complaint was the *visible* gap between a click and the numbers
  changing — a server-side `@recomputing` assign cannot close that gap by construction,
  since the assign and the finished result leave the server **together** (see
  `WeddingPlannerWeb.Live.BudgetLive`'s own moduledoc for the measurement). `loading_targets/0`
  is the one CSS selector string every preset-dependent region on `/budget` shares;
  passed to `JS.push/2`'s `:loading` option by the preset form, every `role_values/1`
  button and the view switcher, it makes the LiveView JS client add
  `phx-click-loading`/`phx-change-loading` to those elements **at click time**, removed
  the moment the reply is acknowledged — covering the click→first-reply gap regardless of
  how long that takes. `@recomputing` then covers whatever remains (a genuinely slow
  async build, or a live refresh from another tab) — both drive the exact same
  `opacity-50`/`aria-busy` treatment on the same elements, so there is no visible seam
  between the two.
  """

  use WeddingPlannerWeb, :html

  import WeddingPlannerWeb.Components.InvoiceComponents, only: [invoice_row: 1]

  @doc """
  The CSS selector every preset-dependent region on `/budget` shares (orchestrator
  amendment, loading state & latency, 2026-09-25): the overall Forecast/Available
  formulas (`#budget-overall-formulas`) and the wrapper around whichever of
  Category/Event/Per guest is currently shown (`#budget-preset-dependent`,
  `WeddingPlannerWeb.Live.BudgetLive`'s template). Passed to every `JS.push/2`'s
  `:loading` option on `/budget` (the preset form, every `role_values/1` button, the
  view switcher) so the LiveView JS client dims them **instantly**, client-side, at
  click time — see the moduledoc.
  """
  @spec loading_targets() :: String.t()
  def loading_targets, do: "#budget-overall-formulas, #budget-preset-dependent"

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

  attr :click_event, :string,
    default: "select_preset",
    doc: "task 84, W13 amendment: the event name a role-value button pushes"

  attr :loading_target, :string,
    default: nil,
    doc:
      "orchestrator amendment, loading state & latency: an optional CSS selector dimmed instantly (JS.push's :loading) in addition to :formula_id's own disclosure — /budget passes loading_targets/0"

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
          phx-click={
            select_preset_js(@ranged.likely.preset_id, @formula_id, @click_event, @loading_target)
          }
          class={[
            "text-lg font-semibold tabular-nums transition hover:text-accent focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent",
            "phx-click-loading:opacity-60 phx-click-loading:cursor-wait",
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
          click_event={@click_event}
          loading_target={@loading_target}
          bad?={@bad?}
        />
        <.role_value_button
          id={"#{@id}-likely"}
          role_label="Likely"
          figure={@ranged.likely}
          formula_id={@formula_id}
          click_event={@click_event}
          loading_target={@loading_target}
          bad?={@bad?}
        />
        <.role_value_button
          id={"#{@id}-maximum"}
          role_label="Max"
          figure={@ranged.maximum}
          formula_id={@formula_id}
          click_event={@click_event}
          loading_target={@loading_target}
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
  attr :click_event, :string, required: true
  attr :loading_target, :string, default: nil
  attr :bad?, :boolean, default: false

  defp role_value_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click={select_preset_js(@figure.preset_id, @formula_id, @click_event, @loading_target)}
      class="rounded-chip px-1.5 py-1 text-left transition hover:bg-surface focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent phx-click-loading:opacity-60 phx-click-loading:cursor-wait"
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

  defp select_preset_js(preset_id, formula_id, click_event, loading_target) do
    push_opts = [value: %{"preset_id" => preset_id, "formula_id" => formula_id}]
    push_opts = if loading_target, do: push_opts ++ [loading: loading_target], else: push_opts

    JS.push(click_event, push_opts)
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
          loading_target={loading_targets()}
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
                loading_target={loading_targets()}
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
                loading_target={loading_targets()}
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
              loading_target={loading_targets()}
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

  # -- view switcher (BUD-07, DR-76, task 84) --------------------------------------------------

  @doc """
  The view switcher (`BUD-07`, `DR-76`): Category / Event / Per guest, each a plain
  `<.link patch=...>` to `?view=...` — the selection lives in the URL, `WeddingPlannerWeb.Live.BudgetLive`'s
  `handle_params/3` reads it, so a reload keeps it. No `phx-change` here (the UI trap
  this task calls out is about a bare `<select>`/radio group — a set of patch links has
  no such hazard). The current view's chip uses `--color-accent` — an action state
  (design record §2), never a status colour.
  """
  attr :current, :string, required: true, doc: "\"category\" | \"event\" | \"guest\" (DR-76)"

  def view_switcher(assigns) do
    ~H"""
    <div
      id="budget-view-switcher"
      class="mt-6 inline-flex flex-wrap gap-1 rounded-chip bg-surface p-1"
    >
      <.view_switcher_link view="category" current={@current} label="Category" />
      <.view_switcher_link view="event" current={@current} label="Event" />
      <.view_switcher_link view="guest" current={@current} label="Per guest" />
    </div>
    """
  end

  attr :view, :string, required: true
  attr :current, :string, required: true
  attr :label, :string, required: true

  # A `<button>`, not `<.link patch>` (orchestrator amendment, loading state & latency):
  # `JS.patch/2` has no `:loading` option (only `:replace` — checked against
  # `deps/phoenix_live_view/lib/phoenix_live_view/js.ex` rather than guessed), so the
  # instant, client-side dimming needs a real `JS.push` round trip. `select_view`'s own
  # `handle_event` does nothing but `push_patch/2` to the same URL a link click would
  # have produced — `handle_params/3` (unchanged) still owns `@view` and the recompute,
  # so this is one round trip, not two, and the loading window covers the whole thing
  # (push → push_patch → handle_params → recompute), not just a trivial companion event.
  defp view_switcher_link(assigns) do
    assigns = assign(assigns, :selected?, assigns.view == assigns.current)

    ~H"""
    <button
      type="button"
      id={"budget-view-switcher-#{@view}"}
      phx-click={JS.push("select_view", value: %{"view" => @view}, loading: loading_targets())}
      aria-current={if(@selected?, do: "page")}
      class={[
        "rounded-chip px-3 py-1.5 text-sm font-medium transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent",
        "phx-click-loading:opacity-60 phx-click-loading:cursor-wait",
        if(@selected?,
          do: "bg-accent text-white",
          else: "text-ink-soft hover:bg-surface-raised hover:text-ink"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  # -- by-event view (BUD-07, DR-73, task 84) --------------------------------------------------

  @doc """
  The by-event view (`BUD-07`, `DR-73`): one row per event of `snapshot.events` plus
  General, each `WeddingPlannerWeb.BudgetOverview.event_view_row()`'s three role values
  (`DR-71`, `role_values/1` unchanged — same one-interaction buttons), its per-category
  split and its own formula disclosure at the selected preset (`BUD-08`).
  """
  attr :id, :string, default: "budget-by-event"
  attr :rows, :list, required: true
  attr :open_formula_ids, :any, required: true

  def event_rows(assigns) do
    ~H"""
    <div id={@id}>
      <p class="text-sm text-ink-soft">
        Per-person charges count under their event; flat charges, targets and invoices are General.
      </p>

      <div class="mt-3 space-y-3">
        <.event_row :for={row <- @rows} row={row} open_formula_ids={@open_formula_ids} />
      </div>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :open_formula_ids, :any, required: true

  # A compact row (orchestrator review, 2026-09-25): every role is the same zero amount,
  # so the full card (role values + empty by-category list + an empty formula
  # disclosure) would read "€ 0,00 / under every preset / Nothing yet" for no benefit —
  # one plain, non-interactive line instead, still under the row's own id, but with
  # neither `:formula_id`'s disclosure nor a by-category list rendered at all.
  defp event_row(%{row: %{compact?: true}} = assigns) do
    ~H"""
    <p id={@row.id} class="rounded-field border border-line bg-surface-raised px-4 py-3 text-sm">
      <span class="font-semibold text-ink">{@row.name}</span>
      <span class="text-ink-faint"> — </span>
      <span class="tabular-nums text-ink">{@row.amount.likely.value}</span>
      <span class="text-ink-faint"> · Nothing yet</span>
    </p>
    """
  end

  defp event_row(assigns) do
    ~H"""
    <div id={@row.id} class="rounded-field border border-line bg-surface-raised p-4">
      <p class="font-semibold text-ink">{@row.name}</p>

      <div class="mt-2">
        <.role_values
          id={"#{@row.id}-amount"}
          ranged={@row.amount}
          formula_id={@row.formula_id}
          loading_target={loading_targets()}
        />
      </div>

      <ul
        :if={@row.by_category != []}
        id={"#{@row.id}-by-category"}
        class="mt-3 space-y-1 text-sm text-ink-soft"
      >
        <li :for={part <- @row.by_category} class="flex items-baseline justify-between gap-2">
          <span>{part.name}</span>
          <span class="tabular-nums text-ink">{part.amount}</span>
        </li>
      </ul>
      <p
        :if={@row.by_category == []}
        id={"#{@row.id}-by-category-empty"}
        class="mt-3 text-sm text-ink-faint"
      >
        Nothing yet
      </p>

      <div class="mt-3">
        <.formula
          id={@row.formula_id}
          total_label={@row.name}
          open={MapSet.member?(@open_formula_ids, @row.formula_id)}
          {@row.formula}
        />
      </div>
    </div>
    """
  end

  # -- per-guest view (BUD-07, DR-74, task 84) -------------------------------------------------

  @doc """
  The per-guest view (`BUD-07`, `DR-74`): the overall row and one row per category,
  each `WeddingPlannerWeb.BudgetOverview.per_guest_row()`'s three role values
  (`role_values/1` unchanged), the persons counted per preset beside it (`HC-08`) and
  the formula at the selected preset — or the `:no_guests_message` sentence in its
  place when nobody is counted under it (`DR-74`).
  """
  attr :id, :string, default: "budget-per-guest"
  attr :per_guest, :map, required: true
  attr :open_formula_ids, :any, required: true

  def per_guest(assigns) do
    ~H"""
    <div id={@id}>
      <.per_guest_row row={@per_guest.overall} open_formula_ids={@open_formula_ids} />

      <div class="mt-3 space-y-3">
        <.per_guest_row
          :for={row <- @per_guest.categories}
          row={row}
          open_formula_ids={@open_formula_ids}
        />
      </div>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :open_formula_ids, :any, required: true

  defp per_guest_row(assigns) do
    ~H"""
    <div id={@row.id} class="rounded-field border border-line bg-surface-raised p-4">
      <p class="font-semibold text-ink">{@row.name}</p>

      <div class="mt-2">
        <.role_values
          id={"#{@row.id}-amount"}
          ranged={@row.amount}
          formula_id={@row.formula_id}
          loading_target={loading_targets()}
        />
      </div>

      <p :if={@row.persons_caption} id={"#{@row.id}-persons"} class="mt-1 text-xs text-ink-faint">
        {@row.persons_caption}
      </p>

      <p
        :if={@row.no_guests_message}
        id={"#{@row.id}-no-guests"}
        class="mt-3 text-sm text-ink-soft"
      >
        {@row.no_guests_message}
      </p>

      <div :if={@row.formula} class="mt-3">
        <.formula
          id={@row.formula_id}
          total_label={@row.name}
          open={MapSet.member?(@open_formula_ids, @row.formula_id)}
          {@row.formula}
        />
      </div>
    </div>
    """
  end

  # -- cash flow (BUD-06, DR-75, task 84) -------------------------------------------------------

  @doc """
  The cash-flow section (`BUD-06`, `DR-75`): Overdue first (bad tone, `BIL-06`), then
  one bucket per due month, then No due date — each a native `<details>` listing its
  invoices (label, category, due date, amount, a link to `/invoices/:id`); the
  section's total equals Outstanding. Empty state "Nothing unpaid". Renders in every
  view (task 84's own decision, flagged): `BUD-06` is a page-level concern orthogonal to
  the `BUD-07` view switcher, not a fourth view.
  """
  attr :id, :string, default: "budget-cash-flow"
  attr :cash_flow, :map, required: true

  def cash_flow(assigns) do
    ~H"""
    <div id={@id} class="mt-8">
      <div class="flex items-baseline justify-between gap-4">
        <h2 class="text-lg font-semibold text-ink">Cash flow</h2>
        <p id="cash-flow-total" class="tabular-nums text-sm font-medium text-ink-soft">
          {@cash_flow.total}
        </p>
      </div>

      <p :if={@cash_flow.empty?} id="cash-flow-empty" class="mt-3 text-sm text-ink-faint">
        Nothing unpaid
      </p>

      <div :if={!@cash_flow.empty?} class="mt-3 space-y-2">
        <.cash_flow_bucket :if={@cash_flow.overdue} bucket={@cash_flow.overdue} bad?={true} />
        <.cash_flow_bucket :for={bucket <- @cash_flow.months} bucket={bucket} bad?={false} />
        <.cash_flow_bucket :if={@cash_flow.no_due_date} bucket={@cash_flow.no_due_date} bad?={false} />
      </div>
    </div>
    """
  end

  attr :bucket, :map, required: true
  attr :bad?, :boolean, default: false

  defp cash_flow_bucket(assigns) do
    ~H"""
    <details id={@bucket.id} class="rounded-field border border-line bg-surface-raised">
      <summary class={[
        "cursor-pointer list-none select-none px-4 py-3 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent",
        if(@bad?, do: "text-bad font-semibold", else: "text-ink font-medium")
      ]}>
        <span class="flex items-baseline justify-between gap-4">
          <span>{@bucket.label}</span>
          <span class="tabular-nums">{@bucket.total}</span>
        </span>
      </summary>

      <ul class="space-y-2 border-t border-line px-4 py-3">
        <li
          :for={invoice <- @bucket.invoices}
          id={invoice.id}
          class="flex flex-wrap items-baseline justify-between gap-2 text-sm"
        >
          <span class="text-ink">
            <.link navigate={~p"/invoices/#{invoice.invoice_id}"} class="font-medium hover:underline">
              {invoice.label}
            </.link>
            <span :if={invoice.category_name} class="text-ink-soft"> · {invoice.category_name}</span>
            <span class="text-ink-faint"> · {invoice.due_date}</span>
          </span>
          <span class="tabular-nums text-ink">{invoice.amount}</span>
        </li>
      </ul>
    </details>
    """
  end
end
