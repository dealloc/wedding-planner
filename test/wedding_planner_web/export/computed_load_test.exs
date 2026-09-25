defmodule WeddingPlannerWeb.Export.ComputedLoadTest do
  @moduledoc """
  `load/0` of the three computed exporters (`WeddingPlannerWeb.Export.Headcount`,
  `.Offers`, `.Budget`) over **real database rows** (`XC-32`: exports reflect current
  live data): the shared Dinner guests (`WeddingPlanner.NormativeGuests`) and Venue A
  (`WeddingPlanner.NormativeOfferRows`) entered through the contexts, then
  `load/0 |> table/2` through the real engines — no `headcount` seam. Oracles are the
  normative figures (Dinner Likely 72 + 6, Minimum 60 + 4; O1 €11,726, O2 €11,478).
  """
  use WeddingPlanner.DataCase, async: true

  import WeddingPlanner.OfferFixtures, only: [scope_fixture: 0, confirm_directly!: 1]
  import WeddingPlannerWeb.ComputedExportAssertions

  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeGuests
  alias WeddingPlanner.NormativeOfferRows, as: Rows
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Export

  @today ~D[2026-09-25]

  setup do
    scope = scope_fixture()
    dinner = Rows.dinner!(scope)
    NormativeGuests.shared_dinner!(scope, dinner)
    {venue, services} = Rows.category!(scope, NE.venue_category())
    %{offer: offer} = Rows.offer!(scope, :venue_a, venue, services, dinner)
    %{offer: offer}
  end

  test "each load/0 is the live snapshot" do
    for exporter <- [Export.Headcount, Export.Offers, Export.Budget] do
      assert %Snapshot{} = snapshot = exporter.load()
      assert [%{name: "Dinner"}] = snapshot.events
      assert [%{vendor_name: "Venue A"}] = snapshot.offers
    end
  end

  test "headcount: the shared Dinner counts from stored rows" do
    table = Export.Headcount.load() |> Export.Headcount.table(@today) |> assert_table_shape()
    %{"Dinner" => %{"Likely" => likely, "Minimum" => minimum}} = NE.shared_headcount()

    assert ["Dinner", "Likely", likely.adults, likely.children, likely.total] in table.rows
    assert ["Dinner", "Minimum", minimum.adults, minimum.children, minimum.total] in table.rows
    assert ["All events", "Likely", likely.adults, likely.children, likely.total] in table.rows
  end

  test "offers: Venue A's totals from stored rows are O1 / O2" do
    table = Export.Offers.load() |> Export.Offers.table(@today) |> assert_table_shape()
    rows = rows_where(table, "Offer", "Venue A")

    assert length(rows) == length(NE.venue_a().lines)

    for row <- rows do
      assert_money(cell(table, row, "Offer total — Likely"), NE.expected("O1").total)
      assert_money(cell(table, row, "Offer total — Minimum"), NE.expected("O2").total)
    end
  end

  test "budget: a confirmed Venue A forecasts O1 / O2 from stored rows", %{offer: offer} do
    confirm_directly!(offer)

    table = Export.Budget.load() |> Export.Budget.table(@today) |> assert_table_shape()
    venue = row_where!(table, "Category", "Venue")
    total = row_where!(table, "Category", "Total")

    assert cell(table, venue, "Forecast basis") == "Confirmed offers"

    for row <- [venue, total] do
      assert_money(cell(table, row, "Committed — Likely"), NE.expected("O1").total)
      assert_money(cell(table, row, "Forecast — Likely"), NE.expected("O1").total)
      assert_money(cell(table, row, "Forecast — Minimum"), NE.expected("O2").total)
    end
  end
end
