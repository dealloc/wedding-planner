defmodule WeddingPlannerWeb.BudgetOverviewTest do
  @moduledoc """
  Pure, in-memory tests for `WeddingPlannerWeb.BudgetOverview.build/4` (tasks 82, 84;
  `docs/modules/invoices-and-budget.md` `BUD-01`…`BUD-08`, `BIL-06`; `DR-71`, `DR-72`,
  `DR-73`, `DR-74`, `DR-75`, `DR-76`, `DR-77`) over `WeddingPlanner.BudgetSnapshots.branches/0`
  (task 80's fixture — every `BUD-03` branch on a real category, `Preset.defaults()`, an
  overall budget of €20,000, one event "Dinner" holding Venue's per-attendee lines).
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.BudgetSnapshots
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Invoices.InvoiceLine
  alias WeddingPlanner.Money
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Valuation.PresetChoice
  alias WeddingPlannerWeb.BudgetOverview
  alias WeddingPlannerWeb.Format

  @today ~D[2027-02-01]

  defp eur(amount), do: Money.new(amount)

  defp by_id(overview, id), do: Enum.find(overview.categories, &(&1.id == id))

  # `WeddingPlanner.Valuation.Preset.defaults/0` (the pure in-memory fixture) leaves
  # every preset's `:id` as `nil` — real, distinct ids only exist once a preset is a DB
  # row. `WeddingPlannerWeb.BudgetOverview.build/3`'s `selected_preset_id` is meant to be
  # looked up by id (`PresetChoice.find/2` — `DR-54`), so these tests give the fixture's
  # three presets distinct test ids to actually exercise that lookup, the same "test
  # construction, not normative data" convention `BudgetSnapshots` itself uses throughout.
  defp with_distinct_preset_ids(snapshot) do
    presets =
      snapshot.headcount_presets |> Enum.with_index(1) |> Enum.map(fn {p, i} -> %{p | id: i} end)

    %{snapshot | headcount_presets: presets}
  end

  describe "role values (DR-71)" do
    test "minimum/likely/maximum are named to real presets; equal collapses only when all three agree (FP-82e)" do
      %{snapshot: snapshot, categories: categories} = BudgetSnapshots.branches()
      snapshot = with_distinct_preset_ids(snapshot)
      {:ok, roles} = PresetChoice.role_presets(snapshot.headcount_presets)

      overview = BudgetOverview.build(snapshot, @today, nil, "category")

      venue = by_id(overview, categories["Venue"].id)
      assert venue.forecast.minimum.preset_id == roles.minimum.id
      assert venue.forecast.likely.preset_id == roles.likely.id
      assert venue.forecast.maximum.preset_id == roles.maximum.id

      # Venue's shared Dinner guests: Likely and Maximum count the same headcount
      # (every shared guest is certain or likely), Minimum counts fewer. Two of the
      # three values therefore agree with each other while the third does not — this
      # MUST NOT collapse (a "two equal" implementation would wrongly treat
      # `likely == maximum` as reason enough, `FP-82e`).
      assert venue.forecast.likely.value == venue.forecast.maximum.value
      refute venue.forecast.minimum.value == venue.forecast.likely.value
      refute venue.forecast.equal?

      # Attire (target €2,500, but an unlinked €3,100 invoice wins the fallback max —
      # `BudgetSnapshots`' `:target`/`fallback_winner: :unlinked_invoices` branch) has no
      # headcount dependence at all — all three collapse to the same figure.
      attire = by_id(overview, categories["Attire"].id)
      assert attire.forecast.equal?
      assert attire.forecast.likely.value == Format.money(eur(3_100))
      assert attire.committed.equal?
    end

    test "the selected preset drives only the single-figure formulas, never the three-value lists (FP-82a)" do
      %{snapshot: snapshot, categories: categories} = BudgetSnapshots.branches()
      snapshot = with_distinct_preset_ids(snapshot)
      {:ok, roles} = PresetChoice.role_presets(snapshot.headcount_presets)

      likely_overview = BudgetOverview.build(snapshot, @today, roles.likely.id, "category")
      minimum_overview = BudgetOverview.build(snapshot, @today, roles.minimum.id, "category")

      assert likely_overview.tiles.forecast.role_values ==
               minimum_overview.tiles.forecast.role_values

      assert likely_overview.tiles.available.role_values ==
               minimum_overview.tiles.available.role_values

      venue_id = categories["Venue"].id
      likely_venue = by_id(likely_overview, venue_id)
      minimum_venue = by_id(minimum_overview, venue_id)
      assert likely_venue.forecast == minimum_venue.forecast
      assert likely_venue.committed == minimum_venue.committed

      # But the single-figure formulas (computed at the selected preset only) differ,
      # since Venue's headcount differs between Minimum and Likely.
      refute likely_overview.overall_forecast_formula == minimum_overview.overall_forecast_formula
      refute likely_venue.forecast_formula == minimum_venue.forecast_formula
    end
  end

  describe "the collapsed card's summary forecast (orchestrator review, 2026-09-25)" do
    test "shows the low–high range, ordered by comparison, when the three roles differ" do
      %{snapshot: snapshot, categories: categories} = BudgetSnapshots.branches()

      overview = BudgetOverview.build(snapshot, @today, nil, "category")
      venue = by_id(overview, categories["Venue"].id)

      refute venue.forecast.equal?
      expected = "Forecast #{venue.forecast.minimum.value} – #{venue.forecast.maximum.value}"
      assert venue.summary_forecast == expected
    end

    test "shows one value when the three roles agree (FP-82f)" do
      %{snapshot: snapshot, categories: categories} = BudgetSnapshots.branches()

      overview = BudgetOverview.build(snapshot, @today, nil, "category")
      attire = by_id(overview, categories["Attire"].id)

      assert attire.forecast.equal?
      assert attire.summary_forecast == "Forecast #{Format.money(eur(3_100))}"
    end

    test "shows the missing-preset notice when a role is unassigned" do
      %{snapshot: snapshot, categories: categories} = BudgetSnapshots.branches()

      # Defensive-only case (`DR-54` normally guarantees all three roles exist):
      # dropping the maximum-role preset makes `Budget.for_roles/2` return `:missing`.
      presets = Enum.reject(snapshot.headcount_presets, &(&1.role == :maximum))
      snapshot = %{snapshot | headcount_presets: presets}

      overview = BudgetOverview.build(snapshot, @today, nil, "category")
      venue = by_id(overview, categories["Venue"].id)

      assert venue.forecast == :missing

      assert venue.summary_forecast ==
               "A stored preset is missing one of the three roles, so this range can't be shown right now."
    end
  end

  describe "badges (DR-76)" do
    test "one badge per branch, incl. the plural confirmed-offer count and 'Nothing yet'" do
      %{snapshot: snapshot, categories: categories} = BudgetSnapshots.branches()

      second_venue_offer = %Offer{
        id: 9101,
        category_id: categories["Venue"].id,
        vendor_name: "Venue B",
        status: :confirmed,
        vat_basis: :inclusive,
        invoicing_complete: false,
        planning_pick: false
      }

      second_venue_line = %OfferLine{
        id: 9101,
        offer_id: 9101,
        label: "Price",
        state: :mandatory,
        basis: :flat,
        amount: eur(500),
        enabled: false
      }

      snapshot = %{
        snapshot
        | offers: snapshot.offers ++ [second_venue_offer],
          offer_lines: snapshot.offer_lines ++ [second_venue_line]
      }

      overview = BudgetOverview.build(snapshot, @today, nil, "category")

      assert by_id(overview, categories["Venue"].id).badge == %{
               label: "2 confirmed offers",
               tone: :good
             }

      assert by_id(overview, categories["Photography"].id).badge == %{
               label: "Confirmed offer",
               tone: :good
             }

      assert by_id(overview, categories["Flowers"].id).badge == %{
               label: "Planning pick",
               tone: :info
             }

      assert by_id(overview, categories["Attire"].id).badge == %{label: "Target", tone: :neutral}

      assert by_id(overview, categories["Church"].id).badge == %{
               label: "Nothing yet",
               tone: :neutral
             }
    end
  end

  describe "overall budget and overdue (DR-72, BIL-06, FP-82d)" do
    test "an unset overall budget shows :no_budget with no formula to expand" do
      %{snapshot: snapshot} = BudgetSnapshots.branches()
      snapshot = put_in(snapshot.settings.overall_budget, nil)

      overview = BudgetOverview.build(snapshot, @today, nil, "category")

      assert overview.tiles.available.role_values == :no_budget
      refute overview.overall_budget_set?
      assert overview.overall_available_formula == nil
      assert overview.over_budget == nil
    end

    test "over budget shows the 'Over budget by €X' wording" do
      %{snapshot: snapshot} = BudgetSnapshots.branches()
      snapshot = put_in(snapshot.settings.overall_budget, eur(1))

      overview = BudgetOverview.build(snapshot, @today, nil, "category")

      assert overview.over_budget =~ "€"
      refute overview.tiles.available.role_values == :no_budget
    end

    test "the overdue list is built from `today`: due today is not overdue, due yesterday is (FP-82d)" do
      %{snapshot: snapshot, categories: categories} = BudgetSnapshots.branches()
      church_id = categories["Church"].id

      due_today = %Invoice{
        id: 9201,
        category_id: church_id,
        label: "Due today",
        invoice_date: Date.add(@today, -30),
        due_date: @today,
        paid_on: nil
      }

      overdue_yesterday = %Invoice{
        id: 9202,
        category_id: church_id,
        label: "Overdue one",
        invoice_date: Date.add(@today, -30),
        due_date: Date.add(@today, -1),
        paid_on: nil
      }

      lines = [
        %InvoiceLine{id: 9201, invoice_id: 9201, label: "Due today", amount: eur(100)},
        %InvoiceLine{id: 9202, invoice_id: 9202, label: "Overdue one", amount: eur(200)}
      ]

      snapshot = %{
        snapshot
        | invoices: snapshot.invoices ++ [due_today, overdue_yesterday],
          invoice_lines: snapshot.invoice_lines ++ lines
      }

      overview = BudgetOverview.build(snapshot, @today, nil, "category")

      expected_amount = Format.money(eur(200))

      assert [
               %{
                 label: "Overdue one",
                 days_overdue: 1,
                 category_name: "Church",
                 amount: ^expected_amount
               }
             ] =
               overview.overdue
    end
  end

  # -- by-event breakdown (BUD-07, DR-73, task 84) --------------------------------------------

  describe "by-event breakdown (BUD-07, DR-73)" do
    test "only an all-zero row is compact; a non-zero row equal under every preset stays a full card" do
      %{snapshot: snapshot} = BudgetSnapshots.branches()
      # Targets only: General holds the targets (the same under every preset), Dinner nothing.
      snapshot = %{snapshot | offers: [], offer_lines: [], invoices: [], invoice_lines: []}

      overview = BudgetOverview.build(snapshot, @today, nil, "event")
      dinner = Enum.find(overview.by_event, &(&1.id == "budget-event-1"))
      general = Enum.find(overview.by_event, &(&1.id == "budget-event-general"))

      assert dinner.compact?
      assert general.amount.equal?
      refute WeddingPlanner.Money.compare(general.amount.likely.money, eur(0)) == :eq
      refute general.compact?
    end

    test "rows in event order + General, three independent role values each; Σ Likely == the Likely forecast tile (FP-84d)" do
      %{snapshot: snapshot} = BudgetSnapshots.branches()

      overview = BudgetOverview.build(snapshot, @today, nil, "event")

      assert Enum.map(overview.by_event, & &1.id) == ["budget-event-1", "budget-event-general"]
      assert Enum.map(overview.by_event, & &1.name) == ["Dinner", "General"]

      dinner_row = Enum.find(overview.by_event, &(&1.id == "budget-event-1"))
      refute dinner_row.amount == :missing

      # Three genuinely independent values (not the same selected-preset figure rendered
      # three times, FP-84d) — Venue's shared Dinner guests differ Minimum vs Likely.
      refute dinner_row.amount.minimum.value == dinner_row.amount.likely.value
      assert dinner_row.amount.likely.role == :likely
      assert dinner_row.amount.likely.preset_name == "Likely"

      likely_sum =
        overview.by_event
        |> Enum.map(& &1.amount.likely.money)
        |> WeddingPlanner.Money.sum()

      assert WeddingPlanner.Money.compare(
               likely_sum,
               overview.tiles.forecast.role_values.likely.money
             ) == :eq
    end

    test "the row's formula and by-category split are at the selected preset only" do
      %{snapshot: snapshot} = BudgetSnapshots.branches()
      snapshot = with_distinct_preset_ids(snapshot)
      {:ok, roles} = PresetChoice.role_presets(snapshot.headcount_presets)

      minimum_overview = BudgetOverview.build(snapshot, @today, roles.minimum.id, "event")
      likely_overview = BudgetOverview.build(snapshot, @today, roles.likely.id, "event")

      minimum_dinner = Enum.find(minimum_overview.by_event, &(&1.id == "budget-event-1"))
      likely_dinner = Enum.find(likely_overview.by_event, &(&1.id == "budget-event-1"))

      refute minimum_dinner.formula == likely_dinner.formula
      # The three role values themselves never move with the selector (DR-71, FP-82a).
      assert minimum_dinner.amount == likely_dinner.amount
    end
  end

  # -- per-guest breakdown (BUD-07, DR-74, task 84) -------------------------------------------

  describe "per-guest breakdown (BUD-07, DR-74)" do
    test ":no_guests shows '—' with the DR-74 sentence when nobody is counted; persons shown per preset" do
      %{snapshot: snapshot, category: category} = BudgetSnapshots.b3()
      snapshot = with_distinct_preset_ids(snapshot)

      overview = BudgetOverview.build(snapshot, @today, nil, "guest")

      overall = overview.per_guest.overall
      assert overall.amount.equal?
      assert overall.amount.minimum.value == "—"
      assert overall.amount.minimum.persons == 0
      assert overall.amount.likely.persons == 0
      assert overall.formula == nil
      assert overall.no_guests_message == "No one is counted under Likely."

      [category_row] = overview.per_guest.categories
      assert category_row.id == "budget-per-guest-#{category.id}"
      assert category_row.amount.maximum.value == "—"
    end

    test "a real headcount shows the amount per person and the formula at the selected preset" do
      %{snapshot: snapshot} = BudgetSnapshots.branches()
      snapshot = with_distinct_preset_ids(snapshot)
      {:ok, roles} = PresetChoice.role_presets(snapshot.headcount_presets)

      overview = BudgetOverview.build(snapshot, @today, roles.likely.id, "guest")
      overall = overview.per_guest.overall

      refute overall.amount == :missing
      assert overall.amount.likely.value =~ "per person"
      assert overall.amount.likely.persons > 0
      refute overall.no_guests_message
      assert overall.formula
    end
  end

  # -- cash flow (BUD-06, DR-75, task 84) ------------------------------------------------------

  describe "cash flow (BUD-06, DR-75)" do
    test "overdue first, then due months (Format.month label), then no due date; total == Outstanding (FP-84c)" do
      %{snapshot: snapshot, categories: categories} = BudgetSnapshots.branches()
      church_id = categories["Church"].id

      overdue_invoice = %Invoice{
        id: 9301,
        category_id: church_id,
        label: "Overdue caterer",
        invoice_date: Date.add(@today, -40),
        due_date: Date.add(@today, -1),
        paid_on: nil
      }

      next_month_due = Date.add(@today, 30)

      next_month_invoice = %Invoice{
        id: 9302,
        category_id: church_id,
        label: "Next month florist",
        invoice_date: @today,
        due_date: next_month_due,
        paid_on: nil
      }

      lines = [
        %InvoiceLine{id: 9301, invoice_id: 9301, label: "Overdue", amount: eur(150)},
        %InvoiceLine{id: 9302, invoice_id: 9302, label: "Next month", amount: eur(250)}
      ]

      snapshot = %{
        snapshot
        | invoices: snapshot.invoices ++ [overdue_invoice, next_month_invoice],
          invoice_lines: snapshot.invoice_lines ++ lines
      }

      overview = BudgetOverview.build(snapshot, @today, nil, "category")
      cash_flow = overview.cash_flow

      refute cash_flow.empty?
      assert cash_flow.overdue.id == "cash-flow-overdue"
      assert Enum.any?(cash_flow.overdue.invoices, &(&1.invoice_id == 9301))

      expected_label = Format.month(Date.new!(next_month_due.year, next_month_due.month, 1))
      assert [month] = cash_flow.months
      assert month.id == "cash-flow-month-#{next_month_due.year}-#{pad2(next_month_due.month)}"
      assert month.label == expected_label
      assert Enum.any?(month.invoices, &(&1.invoice_id == 9302))
      # The overdue invoice never also appears in its due month's bucket (DR-75, FP-84c).
      refute Enum.any?(month.invoices, &(&1.invoice_id == 9301))

      assert cash_flow.no_due_date.id == "cash-flow-no-due-date"
      assert Enum.any?(cash_flow.no_due_date.invoices, &(&1.label == "Florist deposit"))

      assert cash_flow.total == overview.tiles.outstanding.value
    end

    test "empty state has no buckets" do
      %{snapshot: snapshot} = BudgetSnapshots.b3()

      overview = BudgetOverview.build(snapshot, @today, nil, "category")

      assert overview.cash_flow.empty?
      assert overview.cash_flow.overdue == nil
      assert overview.cash_flow.months == []
      assert overview.cash_flow.no_due_date == nil
    end
  end

  # -- charts (DR-77, task 84) ------------------------------------------------------------------

  describe "charts (DR-77)" do
    test "chart inputs use the selected preset, named in the caption, and the maximum-role forecast for the range ghost (FP-84b)" do
      %{snapshot: snapshot, categories: categories} = BudgetSnapshots.branches()
      snapshot = with_distinct_preset_ids(snapshot)
      {:ok, roles} = PresetChoice.role_presets(snapshot.headcount_presets)
      venue_id = categories["Venue"].id

      minimum_overview = BudgetOverview.build(snapshot, @today, roles.minimum.id, "category")
      assert minimum_overview.charts.preset_name == "Minimum"

      venue_row = Enum.find(minimum_overview.charts.categories, &(&1.id == venue_id))
      assert Enum.any?(venue_row.segments, &(&1.kind == :range_ghost))

      # Selecting Maximum names Maximum (not always Likely, FP-84b) and the ghost
      # disappears — nothing above Maximum's own forecast.
      maximum_overview = BudgetOverview.build(snapshot, @today, roles.maximum.id, "category")
      assert maximum_overview.charts.preset_name == "Maximum"

      maximum_venue_row = Enum.find(maximum_overview.charts.categories, &(&1.id == venue_id))
      refute Enum.any?(maximum_venue_row.segments, &(&1.kind == :range_ghost))
    end
  end

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: "#{n}"
end
