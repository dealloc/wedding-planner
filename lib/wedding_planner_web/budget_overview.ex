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
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Valuation.Budget
  alias WeddingPlanner.Valuation.Invoices, as: InvoiceValuation
  alias WeddingPlanner.Valuation.PresetChoice
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Format
  alias WeddingPlannerWeb.FormulaPresenter

  @typedoc """
  One role's display value plus the preset id a tap on it selects (`DR-71`). `:money`
  is the same figure's raw, unrounded amount — kept alongside the display string only so
  a caller that needs to compare or order role values (`summary_forecast/1`'s low–high)
  never has to re-derive it from `:value`.
  """
  @type figure :: %{value: String.t(), preset_id: term(), money: Money.t()}

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
          categories: [category_card()]
        }

  @doc """
  Builds the whole `/budget` view model from `snapshot`, `today`
  (`WeddingPlanner.Tasks.TodoList.today/1` in the viewer's zone, `DR-44`) and
  `selected_preset_id` (a transient assign — `HC-10`, never persisted; `nil` or a stale
  id falls back to the default likely-role preset, `PresetChoice.find/2`).

  When `snapshot.headcount_presets` is `[]` (defensive only — presets always exist once
  the app is set up), `:presets_missing?` is `true` and every other field is empty/`nil`;
  the caller renders a short notice instead of tiles or cards, the `offer-cost-missing-preset`
  idiom.
  """
  @spec build(Snapshot.t(), Date.t(), term() | nil) :: t()
  def build(%Snapshot{} = snapshot, %Date{} = today, selected_preset_id) do
    presets = snapshot.headcount_presets

    case PresetChoice.find(presets, selected_preset_id) do
      nil ->
        empty()

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
          categories: build_categories(selected.categories, by_role)
        }
    end
  end

  defp empty do
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
      categories: []
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
    by_role = %{
      minimum: {min_o.preset, money_fun.(min_o)},
      likely: {likely_o.preset, money_fun.(likely_o)},
      maximum: {max_o.preset, money_fun.(max_o)}
    }

    moneys = Map.new(by_role, fn {role, {_preset, amount}} -> {role, amount} end)

    equal? =
      WeddingPlanner.Money.compare(moneys.minimum, moneys.likely) == :eq and
        WeddingPlanner.Money.compare(moneys.likely, moneys.maximum) == :eq

    by_role
    |> Map.new(fn {role, {preset, amount}} ->
      {role, %{value: Format.money(amount), preset_id: preset.id, money: amount}}
    end)
    |> Map.put(:equal?, equal?)
  end

  defp money(%WeddingPlanner.Valuation.Formula{total: {:money, %Money{} = money}}), do: money
end
