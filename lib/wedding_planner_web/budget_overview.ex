defmodule WeddingPlannerWeb.BudgetOverview do
  @moduledoc """
  Builds the plain map `WeddingPlannerWeb.Components.BudgetComponents` renders on
  `/budget` (task 82; `docs/modules/invoices-and-budget.md` `BUD-01`…`BUD-08`, `BIL-06`;
  `DR-71`, `DR-72`, `DR-76`) — the `WeddingPlannerWeb.OfferCost` precedent: a pure map of
  display strings plus `WeddingPlannerWeb.FormulaPresenter` output, built once per render
  from a fresh `WeddingPlanner.Valuation.Snapshot`, `today` and the transient,
  per-view-only selected preset id (`HC-10`). No database access, no LiveView concerns.
  Every figure comes straight from `WeddingPlanner.Valuation.Budget` — nothing here
  re-derives a rule (`NFR-41`).

  Money is only ever formatted, never built or added, here (`DR-18`) — arithmetic already
  happened inside `Budget`; rounding happens exclusively inside `WeddingPlannerWeb.Format`
  (`NFR-14`).

  ## Three role-preset values vs. one selected-preset figure (`DR-71`, provisional)

  Every headcount-dependent figure (Committed, Forecast, Available, and a confirmed
  offer's own Committed / a planning pick's total) is built by `range_values/2` into one
  shape, `ranged()`, so a later flip to "the tiles follow the selector instead" (should
  the user answer Q1 that way) only touches this one helper and the handful of call
  sites that build a `ranged()` value — never the components or the LiveView:

    * `:missing` — `Valuation.Budget.for_roles/2` returned `:missing` (a role preset is
      unassigned; defensive only since `DR-54`'s roles are meant to always exist) — the
      caller renders the task-57 `#offer-cost-missing-range` idiom in its place.
    * `%{equal?: bool, minimum: figure, likely: figure, maximum: figure}` — one `figure`
      (`%{value: display string, preset_id: term()}`) per role, in that order. `equal?`
      is `true` when the three **money** values compare equal (`Money.compare/2`, not the
      display strings) — the caller then shows one value captioned "under every preset"
      rather than three (`FP-82e`: two matching is not enough).

  The **single selected-preset figure** (the formula disclosures under `#budget-*` and
  the overall Forecast/Available panel) is a completely separate computation
  (`Valuation.Budget.overall/3` at the caller's chosen preset, reused from `for_roles/2`'s
  own result when the selected preset happens to be one of the three roles — `DR-71`'s
  "reused from it when it is a role preset") — switching the selector only ever changes
  these, never the three-value lists (`FP-82a`).

  ## What a role-value button opens (a judgment call, flagged for the demo)

  The page structure only has **one** formula disclosure per figure family: the overall
  Forecast/Available panel, and each category's own Committed/Forecast formulas — there
  is no separate disclosure for a single confirmed offer's Committed or a planning pick's
  total. Tapping one of *their* three values therefore selects that preset and opens the
  category's own Committed formula (for an offer's Committed) or Forecast formula (for a
  planning pick's total) — the figure it feeds into `BUD-08` — rather than doing nothing.
  `:formula_id` on `category_card()`'s `confirmed_offers[]`/`planning_pick` entries name
  which disclosure a tap on that row opens.

  ## The collapsed card's summary forecast (orchestrator review, 2026-09-25)

  `category_card.summary_forecast` is a plain string ("Forecast € 11.150,00 –
  € 11.726,00", low–high; "Forecast € 1.200,00" when the three roles agree; the
  `:missing`-idiom sentence when a role preset is unassigned) — the locked design
  (`budget-v2-desktop.png`/`budget-v2-phone.png`) shows this under the name and badge in
  every `<summary>` so the whole category list is scannable collapsed, without
  contradicting `DR-71`: it is derived, read-only text (never a button), built from the
  same `category_card.forecast` `ranged()` value the expanded body already shows as three
  labelled, tappable figures — `summary_forecast/1` orders low/high by comparing the raw
  `:money` on `ranged()`'s `figure()` (`DR-71`'s minimum/maximum **role** ids do not
  themselves guarantee the low/high order of the figures they compute, the same reason
  `Valuation.PresetChoice.range/2` orders by comparison rather than by role).

  ## Structure

  See the `t/0` typedoc below for the exact shape; task 84 is expected to add fields
  (the view-switcher's chosen view, the cash-flow section, the by-event/per-guest rows)
  rather than restructure what is here.
  """

  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Valuation.Budget
  alias WeddingPlanner.Valuation.BudgetBreakdowns
  alias WeddingPlanner.Valuation.CashFlow
  alias WeddingPlanner.Valuation.Invoices, as: InvoiceValuation
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.PresetChoice
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.BudgetChart
  alias WeddingPlannerWeb.Format
  alias WeddingPlannerWeb.FormulaPresenter

  @typedoc """
  One role's display value plus the preset id a tap on it selects (`DR-71`). `:money`
  is the same figure's raw, unrounded amount — kept alongside the display string only so
  a caller that needs to compare or order role values (`summary_forecast/1`'s low–high)
  never has to re-derive it from `:value`.

  `:role` and `:preset_name` (task 84, the W13 amendment) make a `figure()` usable by a
  caller that has no other way to tell the three apart — `WeddingPlannerWeb.Components.BudgetComponents.role_values/1`
  itself never reads either (it renders `:value`/`:preset_id` only, generically), but
  tasks 89 (`/what-if`) and 90 (marginal cost) reuse `role_values/1` outside `/budget`
  and need the role and the preset's own name available on the entry itself rather than
  re-deriving it from a parallel `by_role` map they may not have in scope.
  """
  @type figure :: %{
          role: :minimum | :likely | :maximum,
          value: String.t(),
          preset_id: term(),
          preset_name: String.t(),
          money: Money.t()
        }

  @typedoc "See the moduledoc's \"Three role-preset values\" section."
  @type ranged ::
          :missing
          | %{equal?: boolean(), minimum: figure(), likely: figure(), maximum: figure()}

  @typedoc "One confirmed offer's row in a category card (`DR-76`)."
  @type offer_row :: %{
          id: String.t(),
          offer_id: term(),
          vendor_name: String.t(),
          committed: ranged(),
          invoiced: String.t(),
          invoicing_complete?: boolean(),
          forecast_source_label: String.t(),
          formula_id: String.t()
        }

  @typedoc "The planning-pick row in a category card, when the branch is `:planning_pick`."
  @type planning_pick_row :: %{
          offer_id: term(),
          vendor_name: String.t(),
          total: ranged(),
          formula_id: String.t()
        }

  @typedoc "One category card (`DR-76`)."
  @type category_card :: %{
          id: term(),
          name: String.t(),
          branch: Budget.branch(),
          badge: %{label: String.t(), tone: :good | :info | :neutral},
          summary_forecast: String.t(),
          target: String.t(),
          committed: ranged(),
          committed_formula: FormulaPresenter.assigns(),
          committed_formula_id: String.t(),
          invoiced: String.t(),
          paid: String.t(),
          outstanding: String.t(),
          forecast: ranged(),
          forecast_formula: FormulaPresenter.assigns(),
          forecast_formula_id: String.t(),
          confirmed_offers: [offer_row()],
          planning_pick: planning_pick_row() | nil,
          invoices: [Invoice.t()]
        }

  @typedoc "One overdue unpaid invoice row for the \"needs attention\" banner (`BIL-06`)."
  @type overdue_row :: %{
          id: String.t(),
          invoice_id: term(),
          label: String.t(),
          category_name: String.t(),
          amount: String.t(),
          days_overdue: pos_integer()
        }

  @typedoc """
  One row of the by-event view (`BUD-07`, `DR-73`, task 84): an event of
  `snapshot.events` or General, its three role values (`DR-71`), the per-category split
  and the row formula, both **at the selected preset**. `:compact?` is `true` when the
  three role values collapse to the same **zero** amount (orchestrator review,
  2026-09-25) — the caller renders a one-line "<name> — € 0,00 · Nothing yet" row with
  no formula disclosure and no by-category list in that case, rather than a full card
  whose whole body would read "€ 0,00 / under every preset / Nothing yet" for no benefit.
  `:amount`, `:formula` and `:by_category` stay fully populated either way (so, e.g., a
  sum-of-rows check never has to special-case a compact row) — `:compact?` only changes
  what the component renders, never what this module computes.
  """
  @type event_view_row :: %{
          id: String.t(),
          name: String.t(),
          amount: ranged(),
          compact?: boolean(),
          formula_id: String.t(),
          formula: FormulaPresenter.assigns(),
          by_category: [%{name: String.t(), amount: String.t()}]
        }

  @typedoc """
  One per-guest row (overall or one category, `BUD-07`, `DR-74`, task 84): three role
  values whose `:value` is `"<amount> per person"` or `"—"` for a role that counts
  nobody, `:persons_caption` naming how many are counted under each role (`HC-08`), the
  formula at the selected preset (`nil` when the selected preset itself counts nobody,
  in which case `:no_guests_message` carries the DR-74 sentence instead).
  """
  @type per_guest_row :: %{
          id: String.t(),
          name: String.t(),
          amount: ranged() | :missing,
          persons_caption: String.t() | nil,
          formula_id: String.t(),
          formula: FormulaPresenter.assigns() | nil,
          no_guests_message: String.t() | nil
        }

  @typedoc "The per-guest view (`BUD-07`, `DR-74`, task 84): the overall row and one row per category."
  @type per_guest_view :: %{overall: per_guest_row(), categories: [per_guest_row()]}

  @typedoc "One invoice in a cash-flow bucket (`BUD-06`, `DR-75`, task 84)."
  @type cash_flow_invoice :: %{
          id: String.t(),
          invoice_id: term(),
          label: String.t(),
          category_name: String.t() | nil,
          due_date: String.t(),
          amount: String.t()
        }

  @typedoc "One cash-flow bucket (`BUD-06`, `DR-75`, task 84): its total and its invoices."
  @type cash_flow_bucket :: %{
          id: String.t(),
          label: String.t(),
          total: String.t(),
          invoices: [cash_flow_invoice()]
        }

  @typedoc "The cash-flow section (`BUD-06`, `DR-75`, task 84): Overdue, one bucket per due month, then No due date."
  @type cash_flow_view :: %{
          empty?: boolean(),
          total: String.t(),
          overdue: cash_flow_bucket() | nil,
          months: [cash_flow_bucket()],
          no_due_date: cash_flow_bucket() | nil
        }

  @typedoc """
  Both budget charts (`DR-77`, task 84), already at the selected preset: `:composition`
  is `WeddingPlannerWeb.BudgetChart.composition/1`'s result, `:categories` is
  `WeddingPlannerWeb.BudgetChart.categories/2`'s result — passed straight to
  `WeddingPlannerWeb.BudgetChartComponents.composition_bar/1` / `category_bars/1`
  unchanged, so the exact shape is that module's, not repeated here.
  """
  @type charts_view :: %{composition: map(), categories: [map()], preset_name: String.t()}

  @typedoc "The plain map `WeddingPlannerWeb.Components.BudgetComponents` renders."
  @type t :: %{
          presets_missing?: boolean(),
          presets: [%{id: term(), name: String.t()}],
          selected_preset: %{id: term(), name: String.t()} | nil,
          overall_budget_set?: boolean(),
          over_budget: String.t() | nil,
          tiles: %{
            available: %{role_values: ranged() | :no_budget, over_budget?: boolean()},
            forecast: %{role_values: ranged()},
            spent: %{value: String.t()},
            outstanding: %{value: String.t()}
          },
          overall_forecast_formula: FormulaPresenter.assigns() | nil,
          overall_available_formula: FormulaPresenter.assigns() | nil,
          overdue: [overdue_row()],
          categories: [category_card()],
          view: String.t(),
          by_event: [event_view_row()],
          per_guest: per_guest_view(),
          cash_flow: cash_flow_view(),
          charts: charts_view()
        }

  @doc """
  Builds the whole `/budget` view model from `snapshot`, `today`
  (`WeddingPlanner.Tasks.TodoList.today/1` in the viewer's zone, `DR-44`),
  `selected_preset_id` (a transient assign — `HC-10`, never persisted; `nil` or a stale
  id falls back to the default likely-role preset, `PresetChoice.find/2`) and `view`
  (`"category"`, `"event"` or `"guest"` — the `DR-76` URL param, already validated by the
  caller; carried through only so the template has one source for what to render, never
  read back here).

  `:by_event`, `:per_guest`, `:cash_flow` and `:charts` (task 84) are built regardless of
  `view` — the view switcher only ever picks which section is shown, never which is
  computed (`DR-76`: "the view never recomputes").

  When `snapshot.headcount_presets` is `[]` (defensive only — presets always exist once
  the app is set up), `:presets_missing?` is `true` and every other field is empty/`nil`;
  the caller renders a short notice instead of tiles or cards, the `offer-cost-missing-preset`
  idiom.
  """
  @spec build(Snapshot.t(), Date.t(), term() | nil, String.t()) :: t()
  def build(%Snapshot{} = snapshot, %Date{} = today, selected_preset_id, view) do
    presets = snapshot.headcount_presets

    case PresetChoice.find(presets, selected_preset_id) do
      nil ->
        empty(view)

      selected_preset ->
        by_role = Budget.for_roles(snapshot)
        selected = selected_overall(snapshot, selected_preset, by_role)

        %{
          presets_missing?: false,
          presets: Enum.map(presets, &%{id: &1.id, name: &1.name}),
          selected_preset: %{id: selected_preset.id, name: selected_preset.name},
          overall_budget_set?: not is_nil(selected.overall_budget),
          over_budget: selected.over_budget && Format.money(selected.over_budget),
          tiles: build_tiles(by_role, selected),
          overall_forecast_formula: FormulaPresenter.present(selected.forecast),
          overall_available_formula: available_formula(selected.available),
          overdue: build_overdue(snapshot, today),
          categories: build_categories(selected.categories, by_role),
          view: view,
          by_event: build_by_event(snapshot, by_role, selected),
          per_guest: build_per_guest(snapshot, by_role, selected),
          cash_flow: build_cash_flow(snapshot, today),
          charts: build_charts(selected, by_role)
        }
    end
  end

  defp empty(view) do
    %{
      presets_missing?: true,
      presets: [],
      selected_preset: nil,
      overall_budget_set?: false,
      over_budget: nil,
      tiles: %{
        available: %{role_values: :missing, over_budget?: false},
        forecast: %{role_values: :missing},
        spent: %{value: nil},
        outstanding: %{value: nil}
      },
      overall_forecast_formula: nil,
      overall_available_formula: nil,
      overdue: [],
      categories: [],
      view: view,
      by_event: [],
      per_guest: %{
        overall: %{
          id: "budget-per-guest-overall",
          name: "Overall",
          amount: :missing,
          persons_caption: nil,
          formula_id: "budget-per-guest-overall-formula",
          formula: nil,
          no_guests_message: nil
        },
        categories: []
      },
      cash_flow: %{empty?: true, total: nil, overdue: nil, months: [], no_due_date: nil},
      charts: %{
        composition: %{scale: nil, segments: [], over_budget: nil, no_budget?: true},
        categories: [],
        preset_name: nil
      }
    }
  end

  # `DR-71`: reuse `for_roles/2`'s own `overall/3` result when the selected preset is one
  # of the three roles, rather than computing it a second time.
  defp selected_overall(snapshot, selected_preset, by_role) do
    case matching_role(by_role, selected_preset) do
      {:ok, overall} -> overall
      :none -> Budget.overall(snapshot, selected_preset)
    end
  end

  defp matching_role({:ok, roles}, %{id: id}) do
    Enum.find_value([roles.minimum, roles.likely, roles.maximum], :none, fn overall ->
      if overall.preset.id == id, do: {:ok, overall}
    end)
  end

  defp matching_role(:missing, _selected_preset), do: :none

  # -- tiles (BUD-05) ------------------------------------------------------------------------

  defp build_tiles(by_role, selected) do
    %{
      available: %{
        role_values: available_role_values(by_role, selected),
        over_budget?: not is_nil(selected.over_budget)
      },
      forecast: %{role_values: range_values(by_role, &money(&1.forecast))},
      spent: %{value: Format.money(selected.spent)},
      outstanding: %{value: Format.money(selected.outstanding)}
    }
  end

  defp available_role_values(_by_role, %{available: :no_budget}), do: :no_budget
  defp available_role_values(by_role, _selected), do: range_values(by_role, &money(&1.available))

  defp available_formula(:no_budget), do: nil

  defp available_formula(%WeddingPlanner.Valuation.Formula{} = formula),
    do: FormulaPresenter.present(formula)

  # -- overdue banner (BIL-06, DR-59) ---------------------------------------------------------

  defp build_overdue(snapshot, today) do
    categories_by_id = Map.new(snapshot.categories, &{&1.id, &1})

    snapshot.invoices
    |> Enum.filter(&InvoiceValuation.overdue?(&1, today))
    |> Enum.map(fn invoice ->
      total = InvoiceValuation.total(snapshot, invoice)
      category = Map.get(categories_by_id, invoice.category_id)

      %{
        id: "budget-overdue-#{invoice.id}",
        invoice_id: invoice.id,
        label: invoice.label,
        category_name: category && category.name,
        amount: Format.money(total),
        days_overdue: Date.diff(today, invoice.due_date)
      }
    end)
    |> Enum.sort_by(& &1.days_overdue, :desc)
  end

  # -- category cards (BUD-02, BUD-03, BUD-08) ------------------------------------------------

  defp build_categories(categories, by_role) do
    Enum.map(categories, &build_category(&1, by_role))
  end

  defp build_category(%{category: %Category{} = category} = layer, by_role) do
    committed_formula_id = "budget-category-#{category.id}-committed-formula"
    forecast_formula_id = "budget-category-#{category.id}-forecast-formula"
    forecast_ranged = range_values(by_role, &money(category_layer(&1, category.id).forecast))

    %{
      id: category.id,
      name: category.name,
      branch: layer.branch,
      badge: badge(layer),
      summary_forecast: summary_forecast(forecast_ranged),
      target: target_display(layer.target),
      committed: range_values(by_role, &money(category_layer(&1, category.id).committed)),
      committed_formula: FormulaPresenter.present(layer.committed),
      committed_formula_id: committed_formula_id,
      invoiced: Format.money(layer.invoiced),
      paid: Format.money(layer.paid),
      outstanding: Format.money(layer.outstanding),
      forecast: forecast_ranged,
      forecast_formula: FormulaPresenter.present(layer.forecast),
      forecast_formula_id: forecast_formula_id,
      confirmed_offers:
        Enum.map(
          layer.confirmed_offers,
          &offer_row(&1, category.id, by_role, committed_formula_id)
        ),
      planning_pick:
        planning_pick_row(layer.planning_pick, category.id, by_role, forecast_formula_id),
      invoices: layer.invoices
    }
  end

  defp category_layer(overall, category_id),
    do: Enum.find(overall.categories, &(&1.category.id == category_id))

  defp offer_row(contribution, category_id, by_role, formula_id) do
    offer = contribution.offer

    %{
      id: "budget-category-#{category_id}-offer-#{offer.id}",
      offer_id: offer.id,
      vendor_name: offer.vendor_name,
      committed: range_values(by_role, &contribution_committed(&1, category_id, offer.id)),
      invoiced: Format.money(contribution.invoiced),
      invoicing_complete?: offer.invoicing_complete,
      forecast_source_label: forecast_source_label(contribution.source),
      formula_id: formula_id
    }
  end

  defp contribution_committed(overall, category_id, offer_id) do
    layer = category_layer(overall, category_id)
    contribution = Enum.find(layer.confirmed_offers, &(&1.offer.id == offer_id))
    money(contribution.committed)
  end

  defp forecast_source_label(:invoicing_complete), do: "Forecast = invoiced total"
  defp forecast_source_label(:invoiced), do: "Forecast = invoiced so far"
  defp forecast_source_label(:committed), do: "Forecast = committed"

  defp planning_pick_row(nil, _category_id, _by_role, _formula_id), do: nil

  defp planning_pick_row(pick, category_id, by_role, formula_id) do
    %{
      offer_id: pick.offer.id,
      vendor_name: pick.offer.vendor_name,
      total:
        range_values(by_role, fn overall ->
          layer = category_layer(overall, category_id)
          money(layer.planning_pick.total)
        end),
      formula_id: formula_id
    }
  end

  # -- the collapsed card's summary forecast (orchestrator review, 2026-09-25) ----------------

  # Kept in sync by eye with `WeddingPlannerWeb.Components.BudgetComponents.role_values/1`'s
  # own `#{id}-missing` notice — the same sentence, reused here as plain summary text rather
  # than through a shared call, since one is a component template and the other a pure string.
  @missing_range_notice "A stored preset is missing one of the three roles, so this range can't be shown right now."

  defp summary_forecast(:missing), do: @missing_range_notice

  defp summary_forecast(%{equal?: true, likely: %{value: value}}), do: "Forecast #{value}"

  defp summary_forecast(%{minimum: minimum, maximum: maximum}) do
    {low, high} =
      case WeddingPlanner.Money.compare(minimum.money, maximum.money) do
        :gt -> {maximum, minimum}
        _ -> {minimum, maximum}
      end

    "Forecast #{low.value} – #{high.value}"
  end

  # -- badges (DR-76) -------------------------------------------------------------------------

  defp badge(%{branch: :confirmed, confirmed_offers: [_]}),
    do: %{label: "Confirmed offer", tone: :good}

  defp badge(%{branch: :confirmed, confirmed_offers: offers}),
    do: %{label: "#{length(offers)} confirmed offers", tone: :good}

  defp badge(%{branch: :planning_pick}), do: %{label: "Planning pick", tone: :info}

  defp badge(%{branch: :target}), do: %{label: "Target", tone: :neutral}

  defp badge(%{branch: :no_target, forecast: forecast, invoices: []}) do
    if zero_money?(money(forecast)) do
      %{label: "Nothing yet", tone: :neutral}
    else
      %{label: "No target", tone: :neutral}
    end
  end

  defp badge(%{branch: :no_target}), do: %{label: "No target", tone: :neutral}

  defp zero_money?(%Money{} = amount),
    do: WeddingPlanner.Money.compare(amount, WeddingPlanner.Money.new(0)) == :eq

  defp target_display(nil), do: "Not set"
  defp target_display(%Money{} = target), do: Format.money(target)

  # -- the ranged()/range_values() helper (DR-71) ---------------------------------------------

  # `by_role` is `Budget.for_roles/2`'s own result (`{:ok, %{minimum:, likely:, maximum:}}` of
  # `overall/3` results, or `:missing`); `money_fun` pulls one `%Money{}` figure out of a
  # given `overall/3` result (an overall figure, a category's, or an offer/pick figure).
  @spec range_values({:ok, Budget.by_role()} | :missing, (Budget.overall() -> Money.t())) ::
          ranged()
  defp range_values(:missing, _money_fun), do: :missing

  defp range_values({:ok, %{minimum: min_o, likely: likely_o, maximum: max_o}}, money_fun) do
    build_ranged(
      {:minimum, min_o.preset, money_fun.(min_o)},
      {:likely, likely_o.preset, money_fun.(likely_o)},
      {:maximum, max_o.preset, money_fun.(max_o)}
    )
  end

  # The shared `ranged()` builder (task 84): given each role's `{role, preset, money}`,
  # builds the three `figure()`s plus `:equal?` — used both by `range_values/2` (an
  # `overall/3`-shaped `money_fun`) and by the by-event view (task 84), whose three role
  # amounts come from three separate `BudgetBreakdowns.by_event/2` calls rather than
  # from `overall/3` itself.
  @spec build_ranged(
          {:minimum, Preset.t(), Money.t()},
          {:likely, Preset.t(), Money.t()},
          {:maximum, Preset.t(), Money.t()}
        ) :: ranged()
  defp build_ranged(
         {:minimum, min_p, min_m},
         {:likely, likely_p, likely_m},
         {:maximum, max_p, max_m}
       ) do
    entries = %{
      minimum: figure(:minimum, min_p, min_m),
      likely: figure(:likely, likely_p, likely_m),
      maximum: figure(:maximum, max_p, max_m)
    }

    equal? =
      WeddingPlanner.Money.compare(min_m, likely_m) == :eq and
        WeddingPlanner.Money.compare(likely_m, max_m) == :eq

    Map.put(entries, :equal?, equal?)
  end

  defp figure(role, %{id: id, name: name}, %Money{} = money) do
    %{role: role, value: Format.money(money), preset_id: id, preset_name: name, money: money}
  end

  defp money(%WeddingPlanner.Valuation.Formula{total: {:money, %Money{} = money}}), do: money

  # -- by-event view (BUD-07, DR-73, task 84) --------------------------------------------------

  # The by-event view never recomputes `BUD-03` — it renders `BudgetBreakdowns.by_event/2`'s
  # own output, called once per role preset (for the three-value amounts, `DR-71`) and once
  # more for the selected preset (for the row's own category split and formula). Rows come
  # back from `by_event/2` in the same order regardless of preset (`snapshot.events` order
  # then General — never preset-dependent), so the three role lists and the selected list
  # are zipped positionally rather than matched by event id.
  defp build_by_event(snapshot, by_role, selected) do
    selected_rows = BudgetBreakdowns.by_event(snapshot, selected)
    role_lists = by_event_role_lists(by_role, snapshot)

    selected_rows
    |> Enum.with_index()
    |> Enum.map(fn {selected_row, index} -> event_view_row(selected_row, role_lists, index) end)
  end

  defp by_event_role_lists(:missing, _snapshot), do: :missing

  defp by_event_role_lists({:ok, roles}, snapshot) do
    {:ok,
     %{
       minimum: {roles.minimum.preset, BudgetBreakdowns.by_event(snapshot, roles.minimum)},
       likely: {roles.likely.preset, BudgetBreakdowns.by_event(snapshot, roles.likely)},
       maximum: {roles.maximum.preset, BudgetBreakdowns.by_event(snapshot, roles.maximum)}
     }}
  end

  defp event_view_row(selected_row, role_lists, index) do
    id = event_row_id(selected_row.event)
    amount = event_ranged(role_lists, index)

    %{
      id: id,
      name: event_row_name(selected_row.event),
      amount: amount,
      compact?: compact_row?(amount),
      formula_id: "#{id}-formula",
      formula: FormulaPresenter.present(selected_row.formula),
      by_category:
        Enum.map(
          selected_row.by_category,
          &%{name: &1.category.name, amount: Format.money(&1.amount)}
        )
    }
  end

  # A row is compact (orchestrator review, 2026-09-25) when every role collapses to the
  # same, zero amount — never for `:missing` (can't tell), never for a real non-zero
  # figure even if it happens to be equal under every preset (that case still gets its
  # own formula, e.g. a flat target).
  defp compact_row?(:missing), do: false
  defp compact_row?(%{equal?: false}), do: false
  defp compact_row?(%{equal?: true, likely: %{money: money}}), do: zero_money?(money)

  defp event_row_id(:general), do: "budget-event-general"
  defp event_row_id(%Event{id: id}), do: "budget-event-#{id}"

  defp event_row_name(:general), do: "General"
  defp event_row_name(%Event{name: name}), do: name

  defp event_ranged(:missing, _index), do: :missing

  defp event_ranged(
         {:ok,
          %{
            minimum: {min_p, min_rows},
            likely: {likely_p, likely_rows},
            maximum: {max_p, max_rows}
          }},
         index
       ) do
    build_ranged(
      {:minimum, min_p, Enum.at(min_rows, index).amount},
      {:likely, likely_p, Enum.at(likely_rows, index).amount},
      {:maximum, max_p, Enum.at(max_rows, index).amount}
    )
  end

  # -- per-guest view (BUD-07, DR-74, task 84) -------------------------------------------------

  defp build_per_guest(snapshot, by_role, selected) do
    selected_pg = BudgetBreakdowns.per_guest(snapshot, selected)
    role_pg = per_guest_by_role(by_role, snapshot)

    %{
      overall:
        per_guest_row(
          "budget-per-guest-overall",
          "Overall",
          selected_pg.overall,
          selected_pg.preset,
          role_pg,
          & &1.overall
        ),
      categories:
        Enum.map(selected_pg.categories, fn %{category: category, figure: figure} ->
          per_guest_row(
            "budget-per-guest-#{category.id}",
            category.name,
            figure,
            selected_pg.preset,
            role_pg,
            fn pg -> Enum.find(pg.categories, &(&1.category.id == category.id)).figure end
          )
        end)
    }
  end

  defp per_guest_by_role(:missing, _snapshot), do: :missing

  defp per_guest_by_role({:ok, roles}, snapshot) do
    {:ok,
     %{
       minimum: BudgetBreakdowns.per_guest(snapshot, roles.minimum),
       likely: BudgetBreakdowns.per_guest(snapshot, roles.likely),
       maximum: BudgetBreakdowns.per_guest(snapshot, roles.maximum)
     }}
  end

  defp per_guest_row(id, name, selected_figure, selected_preset, :missing, _accessor) do
    %{
      id: id,
      name: name,
      amount: :missing,
      persons_caption: nil,
      formula_id: "#{id}-formula",
      formula: per_guest_formula(selected_figure),
      no_guests_message: per_guest_message(selected_figure, selected_preset)
    }
  end

  defp per_guest_row(id, name, selected_figure, selected_preset, {:ok, role_pg}, accessor) do
    amount =
      per_guest_ranged(%{
        minimum: {role_pg.minimum.preset, role_pg.minimum.persons, accessor.(role_pg.minimum)},
        likely: {role_pg.likely.preset, role_pg.likely.persons, accessor.(role_pg.likely)},
        maximum: {role_pg.maximum.preset, role_pg.maximum.persons, accessor.(role_pg.maximum)}
      })

    %{
      id: id,
      name: name,
      amount: amount,
      persons_caption: persons_caption(amount),
      formula_id: "#{id}-formula",
      formula: per_guest_formula(selected_figure),
      no_guests_message: per_guest_message(selected_figure, selected_preset)
    }
  end

  # A per-guest `ranged()`-shaped value (task 84): `role_data` is
  # `%{minimum: {preset, persons, per_guest_figure}, likely: {...}, maximum: {...}}`.
  # Reuses `figure()`'s shape (so `role_values/1` renders it unchanged) — a role with
  # nobody counted gets `value: "—"` and `money: €0` (never displayed directly, only
  # compared for `:equal?`; the `€0` sentinel never reaches the page since the figure's
  # own `:value` string is what renders).
  defp per_guest_ranged(role_data) do
    entries =
      Map.new(role_data, fn {role, {preset, persons, pg_figure}} ->
        {role, per_guest_figure(role, preset, persons, pg_figure)}
      end)

    equal? =
      WeddingPlanner.Money.compare(entries.minimum.money, entries.likely.money) == :eq and
        WeddingPlanner.Money.compare(entries.likely.money, entries.maximum.money) == :eq

    Map.put(entries, :equal?, equal?)
  end

  defp per_guest_figure(
         role,
         %{id: id, name: name},
         persons,
         {:ok, %{total: {:money, %Money{} = m}}}
       ) do
    %{
      role: role,
      preset_id: id,
      preset_name: name,
      persons: persons,
      value: "#{Format.money(m)} per person",
      money: m
    }
  end

  defp per_guest_figure(role, %{id: id, name: name}, 0 = persons, :no_guests) do
    %{
      role: role,
      preset_id: id,
      preset_name: name,
      persons: persons,
      value: "—",
      money: WeddingPlanner.Money.new(0)
    }
  end

  defp persons_caption(%{minimum: min_f, likely: likely_f, maximum: max_f}) do
    "#{min_f.persons} · #{likely_f.persons} · #{max_f.persons} #{persons_word(max_f.persons)} counted (Min · Likely · Max)"
  end

  defp persons_word(1), do: "person"
  defp persons_word(_n), do: "persons"

  defp per_guest_formula({:ok, %WeddingPlanner.Valuation.Formula{} = formula}),
    do: FormulaPresenter.present(formula)

  defp per_guest_formula(:no_guests), do: nil

  defp per_guest_message({:ok, _formula}, _preset), do: nil

  defp per_guest_message(:no_guests, %{name: name}),
    do: "No one is counted under #{name}."

  # -- cash flow (BUD-06, DR-75, task 84) -------------------------------------------------------

  defp build_cash_flow(snapshot, today) do
    cf = CashFlow.build(snapshot, today)
    categories_by_id = Map.new(snapshot.categories, &{&1.id, &1})

    %{
      empty?: cf.overdue == nil and cf.months == [] and cf.no_due_date == nil,
      total: Format.money(cf.total),
      overdue: cash_flow_bucket(cf.overdue, "cash-flow-overdue", "Overdue", categories_by_id),
      months: Enum.map(cf.months, &cash_flow_month(&1, categories_by_id)),
      no_due_date:
        cash_flow_bucket(cf.no_due_date, "cash-flow-no-due-date", "No due date", categories_by_id)
    }
  end

  defp cash_flow_bucket(nil, _id, _label, _categories), do: nil

  defp cash_flow_bucket(%{total: total, invoices: entries}, id, label, categories) do
    %{
      id: id,
      label: label,
      total: Format.money(total),
      invoices: Enum.map(entries, &cash_flow_invoice(&1, categories))
    }
  end

  defp cash_flow_month(
         %{year: year, month: month, first_day: first_day, total: total, invoices: entries},
         categories
       ) do
    %{
      id: "cash-flow-month-#{year}-#{pad2(month)}",
      label: Format.month(first_day),
      total: Format.money(total),
      invoices: Enum.map(entries, &cash_flow_invoice(&1, categories))
    }
  end

  defp cash_flow_invoice(%{invoice: invoice, total: total}, categories) do
    category = Map.get(categories, invoice.category_id)

    %{
      id: "cash-flow-invoice-#{invoice.id}",
      invoice_id: invoice.id,
      label: invoice.label,
      category_name: category && category.name,
      due_date: Format.date(invoice.due_date),
      amount: Format.money(total)
    }
  end

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: "#{n}"

  # -- charts (DR-77, task 84) ------------------------------------------------------------------

  # Both charts are built from the SELECTED preset's own `overall/3` result only — the
  # maximum-role forecast (the range-ghost extension) is the one figure that comes from
  # `by_role` instead, per `DR-77`.
  defp build_charts(selected, by_role) do
    composition =
      BudgetChart.composition(%{
        overall_budget: selected.overall_budget,
        paid: selected.paid,
        outstanding: selected.outstanding,
        forecast: money(selected.forecast)
      })

    categories =
      BudgetChart.categories(chart_category_rows(selected, by_role), selected.overall_budget)

    %{composition: composition, categories: categories, preset_name: selected.preset.name}
  end

  defp chart_category_rows(selected, by_role) do
    Enum.map(selected.categories, fn layer ->
      %{
        id: layer.category.id,
        name: layer.category.name,
        paid: layer.paid,
        outstanding: layer.outstanding,
        forecast: money(layer.forecast),
        maximum_forecast: maximum_role_forecast(by_role, layer)
      }
    end)
  end

  defp maximum_role_forecast(:missing, layer), do: money(layer.forecast)

  defp maximum_role_forecast({:ok, %{maximum: max_overall}}, layer) do
    case category_layer(max_overall, layer.category.id) do
      nil -> money(layer.forecast)
      max_layer -> money(max_layer.forecast)
    end
  end
end
