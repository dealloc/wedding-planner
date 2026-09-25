defmodule WeddingPlannerWeb.Export.OffersTest do
  @moduledoc """
  `WeddingPlannerWeb.Export.Offers.table/2` over in-memory snapshots (`XC-30`, `XC-32`,
  `HC-08`, `BUD-04`, `CST-21`, `CST-34`, `CST-36`, `CST-40`, `CST-43`, `XC-42`, `DR-89`).
  No database; `load/0` is covered in `WeddingPlannerWeb.Export.ComputedLoadTest`.

  Oracles are independent of the engine: the normative figures of
  `NormativeExamples` (O1, O2, O4, O5 and their per-line results), the figures
  `BudgetSnapshots` documents, and integer-cent amounts built in the test.
  """
  use ExUnit.Case, async: true

  import WeddingPlannerWeb.ComputedExportAssertions

  alias WeddingPlanner.BudgetSnapshots
  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeInvoices
  alias WeddingPlanner.NormativeSnapshots
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Export.Offers

  @today ~D[2026-09-25]

  @headers [
    "Category",
    "Offer",
    "Status",
    "VAT basis",
    "VAT rate (%)",
    "Minimum spend",
    "Planning pick",
    "Invoicing complete",
    "Offer total — Minimum",
    "Offer total — Likely",
    "Offer total — Maximum",
    "Line",
    "Kind",
    "State",
    "Pricing basis",
    "Event",
    "Amount (offer's VAT basis)",
    "Included quantity",
    "Minimum charge (offer's VAT basis)",
    "Line VAT rate (%)",
    "On",
    "Invalid",
    "Counts toward total",
    "Line total — Minimum",
    "Line total — Likely",
    "Line total — Maximum",
    "Currency"
  ]

  # The line columns (between the offer columns and Currency).
  @line_headers Enum.slice(@headers, 11..25)

  defp table(snapshot), do: snapshot |> Offers.table(@today) |> assert_table_shape()

  defp rows_of(table, vendor), do: rows_where(table, "Offer", vendor)

  defp line_row!(table, vendor, line_name) do
    case Enum.filter(rows_of(table, vendor), &(cell(table, &1, "Line") == line_name)) do
      [row] -> row
      other -> flunk("expected one #{vendor} row for #{line_name}, got #{inspect(other)}")
    end
  end

  # A normative offer (NormativeSnapshots, status considering) with the shared Dinner
  # guests and the three default presets, so the real headcount gives Likely 72 + 6.
  defp normative(which) do
    %{snapshot: snapshot} = NormativeSnapshots.snapshot(which)
    {persons, invitations} = NormativeInvoices.shared_guests()

    %{
      snapshot
      | persons: persons,
        invitations: invitations,
        headcount_presets: Preset.defaults()
    }
  end

  defp eur(amount), do: WeddingPlanner.Money.new(amount)

  test "stem and header row" do
    %{snapshot: snapshot} = BudgetSnapshots.branches()
    table = table(snapshot)

    assert table.stem == "offers"
    assert table.headers == @headers
  end

  test "every preset-dependent header names the role preset's stored name (HC-08)" do
    %{snapshot: snapshot} = BudgetSnapshots.branches()

    presets =
      Enum.map(snapshot.headcount_presets, fn
        %Preset{role: :likely} = preset -> %{preset | name: "Expected"}
        preset -> preset
      end)

    table = table(%{snapshot | headcount_presets: presets})

    assert "Offer total — Expected" in table.headers
    assert "Line total — Expected" in table.headers
    refute "Offer total — Likely" in table.headers
  end

  describe "branches/0" do
    setup do
      %{snapshot: snapshot} = BudgetSnapshots.branches()
      %{table: table(snapshot)}
    end

    test "offers in category order then id, lines in DR-41 order", %{table: table} do
      assert Enum.map(table.rows, &Enum.take(&1, 2)) |> Enum.dedup() == [
               ["Venue", "Venue A"],
               ["Photography", "Photographer P"],
               ["Flowers", "Florist F"],
               ["Flowers", "Florist G"]
             ]

      # Service lines in the category's service order (lines of one service by id), then
      # ad hoc lines by id.
      assert Enum.map(rows_of(table, "Venue A"), &cell(table, &1, "Line")) == [
               "Seating",
               "Catering",
               "Catering",
               "Sound",
               "Garden ceremony",
               "Late-night snack",
               "Base price",
               "Cleaning fee"
             ]
    end

    test "Venue A: O1 under Likely, O2 under Minimum, line by line (CST-36, CST-40)",
         %{table: table} do
      %{total: o1} = NE.expected("O1")
      %{total: o2} = NE.expected("O2")

      for row <- rows_of(table, "Venue A") do
        assert cell(table, row, "Status") == "confirmed"
        assert_money(cell(table, row, "Offer total — Likely"), o1, "Offer total — Likely")
        assert_money(cell(table, row, "Offer total — Minimum"), o2, "Offer total — Minimum")
        # The fixture's documented property: Maximum counts the same guests as Likely.
        assert_money(cell(table, row, "Offer total — Maximum"), o1, "Offer total — Maximum")
        assert cell(table, row, "Currency") == "EUR"
      end

      # Every line the doc prices, against the doc's own per-line results.
      rows = rows_of(table, "Venue A")
      by_name = Enum.group_by(rows, &cell(table, &1, "Line"))

      # (An *included* line's €0 is its state's, not a priced line: breakdown/3 does not
      # list it, so its line totals are blank — asserted for Sound below.)
      for %{label: label, service: service, state: state, result: result} <- NE.venue_a().lines,
          state != :included,
          %Money{} = likely <- [result["Likely"]] do
        name = service || label
        candidates = Map.fetch!(by_name, name)

        assert Enum.any?(candidates, fn row ->
                 total = cell(table, row, "Line total — Likely")
                 match?(%Money{}, total) and Money.equal?(total, likely)
               end),
               "#{name}: no row with Line total — Likely #{Money.to_string!(likely)}"
      end

      # Seating, line by line (the one per-person line with an included quantity).
      seating = line_row!(table, "Venue A", "Seating")
      assert cell(table, seating, "Kind") == "service"
      assert cell(table, seating, "State") == "mandatory"
      assert cell(table, seating, "Pricing basis") == "per attendee"
      assert cell(table, seating, "Event") == "Dinner"
      assert_money(cell(table, seating, "Amount (offer's VAT basis)"), eur(12))
      assert cell(table, seating, "Included quantity") == 50
      assert cell(table, seating, "On") == nil
      assert cell(table, seating, "Invalid") == false
      assert cell(table, seating, "Counts toward total") == "counted"
      assert_money(cell(table, seating, "Line total — Likely"), eur(336))
      assert_money(cell(table, seating, "Line total — Minimum"), eur(168))

      # Catering (adults): the minimum charge in the offer's basis.
      [catering_adults, _catering_children] =
        Enum.filter(rows, &(cell(table, &1, "Line") == "Catering"))

      assert_money(cell(table, catering_adults, "Minimum charge (offer's VAT basis)"), eur(6800))
      assert cell(table, catering_adults, "Pricing basis") == "per adult"

      # Sound is included (no charge, no price); the snack is unknown.
      sound = line_row!(table, "Venue A", "Sound")
      assert cell(table, sound, "State") == "included"
      assert cell(table, sound, "Pricing basis") == nil
      assert cell(table, sound, "Counts toward total") == "no charge"

      assert Enum.map(~w(Minimum Likely Maximum), &cell(table, sound, "Line total — #{&1}")) ==
               [nil, nil, nil]

      snack = line_row!(table, "Venue A", "Late-night snack")
      assert cell(table, snack, "State") == "unknown"
      assert cell(table, snack, "Counts toward total") == "no charge"

      # Garden ceremony is not in the confirmed offer's frozen selection (CST-43).
      garden = line_row!(table, "Venue A", "Garden ceremony")
      assert cell(table, garden, "Counts toward total") == "outside confirmed scope"
      assert cell(table, garden, "Line total — Likely") == nil

      base = line_row!(table, "Venue A", "Base price")
      assert cell(table, base, "Kind") == "ad hoc"
      assert cell(table, base, "Pricing basis") == "flat"
      assert cell(table, base, "Event") == nil
      assert cell(table, base, "On") == nil
    end

    test "Florist F (planning pick): Likely €1,280, Minimum €1,140", %{table: table} do
      %{"Dinner" => %{"Likely" => likely, "Minimum" => minimum}} = NE.shared_headcount()
      # €10 per attendee at Dinner + a flat €500 arch, in integer cents.
      likely_cents = likely.total * 1_000 + 50_000
      minimum_cents = minimum.total * 1_000 + 50_000
      assert {likely_cents, minimum_cents} == {128_000, 114_000}

      for row <- rows_of(table, "Florist F") do
        assert cell(table, row, "Planning pick") == true
        assert cell(table, row, "Status") == "shortlisted"
        assert_money(cell(table, row, "Offer total — Likely"), cents(likely_cents))
        assert_money(cell(table, row, "Offer total — Minimum"), cents(minimum_cents))
      end

      flowers = line_row!(table, "Florist F", "Table flowers")
      assert_money(cell(table, flowers, "Line total — Likely"), cents(likely.total * 1_000))
      assert_money(cell(table, flowers, "Line total — Minimum"), cents(minimum.total * 1_000))
    end

    test "Photographer P: invoicing complete is a boolean column", %{table: table} do
      [row] = rows_of(table, "Photographer P")
      assert cell(table, row, "Invoicing complete") == true
      assert cell(table, row, "Planning pick") == false
      assert cell(table, row, "Minimum spend") == nil
      assert cell(table, row, "VAT rate (%)") == nil
      assert cell(table, row, "VAT basis") == "inclusive"
      assert_money(cell(table, row, "Offer total — Likely"), eur(2_000))
    end
  end

  # FP-93c
  test "the three offer-total columns differ where the presets differ" do
    %{snapshot: snapshot} = BudgetSnapshots.branches()
    table = table(snapshot)

    [row | _] = rows_of(table, "Florist F")
    minimum = cell(table, row, "Offer total — Minimum")
    likely = cell(table, row, "Offer total — Likely")

    assert Money.compare(minimum, likely) == :lt
    assert_money(minimum, cents(114_000))
    assert_money(likely, cents(128_000))

    [venue | _] = rows_of(table, "Venue A")
    assert_money(cell(table, venue, "Offer total — Minimum"), NE.expected("O2").total)
    assert_money(cell(table, venue, "Offer total — Likely"), NE.expected("O1").total)
  end

  # FP-93d
  test "a minimum spend that bites: the offer total is the minimum spend, above the line sum" do
    category = %Category{id: 7, name: "Band", sort_order: 0}

    offer = %Offer{
      id: 70,
      category_id: 7,
      vendor_name: "Band B",
      status: :considering,
      vat_basis: :inclusive,
      minimum_spend: cents(150_000),
      planning_pick: false,
      invoicing_complete: false
    }

    line = fn id, label, state, amount_cents, enabled ->
      %OfferLine{
        id: id,
        offer_id: 70,
        label: label,
        state: state,
        basis: :flat,
        amount: cents(amount_cents),
        enabled: enabled
      }
    end

    snapshot = %Snapshot{
      categories: [category],
      offers: [offer],
      offer_lines: [
        line.(701, "Set", :mandatory, 60_000, false),
        line.(702, "Travel", :mandatory, 25_000, false),
        line.(703, "Encore", :optional, 10_000, false)
      ],
      headcount_presets: Preset.defaults()
    }

    table = table(snapshot)
    rows = rows_of(table, "Band B")
    assert length(rows) == 3

    for row <- rows, role <- ~w(Minimum Likely Maximum) do
      assert_money(cell(table, row, "Offer total — #{role}"), cents(150_000))
      assert_money(cell(table, row, "Minimum spend"), cents(150_000))
    end

    # The counted lines sum to €850, below the €1,500 minimum spend.
    assert_money(
      cell(table, line_row!(table, "Band B", "Set"), "Line total — Likely"),
      cents(60_000)
    )

    assert_money(
      cell(table, line_row!(table, "Band B", "Travel"), "Line total — Likely"),
      cents(25_000)
    )

    encore = line_row!(table, "Band B", "Encore")
    assert cell(table, encore, "On") == false
    assert cell(table, encore, "Counts toward total") == "not selected"
    assert cell(table, encore, "Line total — Likely") == nil
  end

  # FP-93e
  test "a not-selected optional line (service not wanted) has blank line totals" do
    table = table(normative(:venue_a))
    garden = line_row!(table, "Venue A", "Garden ceremony")

    assert cell(table, garden, "State") == "optional"
    assert cell(table, garden, "Counts toward total") == "not selected"
    assert_money(cell(table, garden, "Amount (offer's VAT basis)"), eur(500))

    assert Enum.map(~w(Minimum Likely Maximum), &cell(table, garden, "Line total — #{&1}")) ==
             [nil, nil, nil]

    # And the considering offer still reads O1 / O2.
    assert_money(cell(table, garden, "Offer total — Likely"), NE.expected("O1").total)
    assert_money(cell(table, garden, "Offer total — Minimum"), NE.expected("O2").total)
  end

  test "Caterer C: VAT exclusive, rates in %, line totals VAT inclusive, O4 / O5 (CST-33, CST-36)" do
    table = table(normative(:caterer_c))
    rows = rows_of(table, "Caterer C")
    %{total: o4} = NE.expected("O4")
    %{total: o5} = NE.expected("O5")

    for row <- rows do
      assert cell(table, row, "VAT basis") == "exclusive"
      assert Decimal.equal?(cell(table, row, "VAT rate (%)"), 21)
      assert_money(cell(table, row, "Offer total — Likely"), o4)
      # O5: the €7,000 minimum spend applies under Minimum.
      assert_money(cell(table, row, "Offer total — Minimum"), o5)
    end

    expected_lines = NE.caterer_c().lines

    assert length(rows) == length(expected_lines)

    for {row, line} <- Enum.zip(rows, expected_lines) do
      assert cell(table, row, "Line") == (line.service || line.label)
      assert_money(cell(table, row, "Amount (offer's VAT basis)"), line.amount)
      assert_money(cell(table, row, "Line total — Likely"), line.result["Likely"].total)
      assert_money(cell(table, row, "Line total — Minimum"), line.result["Minimum"].total)

      case line.vat_rate do
        nil -> assert cell(table, row, "Line VAT rate (%)") == nil
        _rate -> assert Decimal.equal?(cell(table, row, "Line VAT rate (%)"), 12)
      end
    end
  end

  test "an invalid counted line is listed at €0, a rejected offer is present, a lineless offer has one row" do
    %{snapshot: snapshot, offers: %{"Venue A" => venue_a, "Florist G" => florist_g}} =
      BudgetSnapshots.branches()

    invalid = %OfferLine{
      id: 901,
      offer_id: venue_a.id,
      label: "Welcome drink",
      state: :mandatory,
      basis: :per_attendee,
      event_id: nil,
      amount: eur(5),
      enabled: false
    }

    lineless = %Offer{
      id: 24,
      category_id: florist_g.category_id,
      vendor_name: "Florist H",
      status: :considering,
      vat_basis: :inclusive,
      vat_rate_bp: 2100,
      planning_pick: false,
      invoicing_complete: false
    }

    snapshot =
      Snapshot.apply(snapshot, [
        {:put, :offer_lines, invalid},
        {:put, :offers, %{florist_g | status: :rejected}},
        {:put, :offers, lineless}
      ])

    table = table(snapshot)

    drink = line_row!(table, "Venue A", "Welcome drink")
    assert cell(table, drink, "Invalid") == true
    assert cell(table, drink, "Counts toward total") == "counted"
    assert cell(table, drink, "Event") == nil

    for role <- ~w(Minimum Likely Maximum) do
      assert_money(cell(table, drink, "Line total — #{role}"), eur(0), "Line total — #{role}")
    end

    # It contributes nothing (XC-42): the total is still O1's.
    assert_money(cell(table, drink, "Offer total — Likely"), NE.expected("O1").total)

    [rejected] = rows_of(table, "Florist G")
    assert cell(table, rejected, "Status") == "rejected"
    assert_money(cell(table, rejected, "Offer total — Likely"), eur(5_000))

    [florist_h] = rows_of(table, "Florist H")
    assert Enum.map(@line_headers, &cell(table, florist_h, &1)) == List.duplicate(nil, 15)
    assert Decimal.equal?(cell(table, florist_h, "VAT rate (%)"), 21)
    assert_money(cell(table, florist_h, "Offer total — Likely"), eur(0))
    assert cell(table, florist_h, "Currency") == "EUR"

    # Florist H (id 24) sorts after Florist G (id 23) within Flowers.
    assert Enum.map(rows_where(table, "Category", "Flowers"), &cell(table, &1, "Offer"))
           |> Enum.dedup() == ["Florist F", "Florist G", "Florist H"]
  end

  test "a role preset missing: preset columns blank, headers by role word, never raises" do
    %{snapshot: snapshot} = BudgetSnapshots.branches()
    presets = Enum.map(snapshot.headcount_presets, &%{&1 | role: nil})

    table = table(%{snapshot | headcount_presets: presets})

    assert table.headers == @headers

    preset_columns =
      for kind <- ["Offer total", "Line total"],
          role <- ~w(Minimum Likely Maximum),
          do: "#{kind} — #{role}"

    for row <- table.rows, header <- preset_columns do
      assert cell(table, row, header) == nil
    end

    # A row with no amount left has a blank Currency; one with a stored amount keeps it.
    [photographer] = rows_of(table, "Photographer P")
    assert cell(table, photographer, "Currency") == "EUR"
    sound = line_row!(table, "Venue A", "Sound")
    assert cell(table, sound, "Currency") == nil
  end
end
