defmodule WeddingPlannerWeb.BudgetOverviewTest do
  @moduledoc """
  Pure, in-memory tests for `WeddingPlannerWeb.BudgetOverview.build/3` (task 82;
  `docs/modules/invoices-and-budget.md` `BUD-01`…`BUD-08`, `BIL-06`; `DR-71`, `DR-72`)
  over `WeddingPlanner.BudgetSnapshots.branches/0` (task 80's fixture — every `BUD-03`
  branch on a real category, `Preset.defaults()`, an overall budget of €20,000).
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

      overview = BudgetOverview.build(snapshot, @today, nil)

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

      likely_overview = BudgetOverview.build(snapshot, @today, roles.likely.id)
      minimum_overview = BudgetOverview.build(snapshot, @today, roles.minimum.id)

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

      overview = BudgetOverview.build(snapshot, @today, nil)

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

      overview = BudgetOverview.build(snapshot, @today, nil)

      assert overview.tiles.available.role_values == :no_budget
      refute overview.overall_budget_set?
      assert overview.overall_available_formula == nil
      assert overview.over_budget == nil
    end

    test "over budget shows the 'Over budget by €X' wording" do
      %{snapshot: snapshot} = BudgetSnapshots.branches()
      snapshot = put_in(snapshot.settings.overall_budget, eur(1))

      overview = BudgetOverview.build(snapshot, @today, nil)

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

      overview = BudgetOverview.build(snapshot, @today, nil)

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
end
