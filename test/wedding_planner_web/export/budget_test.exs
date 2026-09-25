defmodule WeddingPlannerWeb.Export.BudgetTest do
  @moduledoc """
  `WeddingPlannerWeb.Export.Budget.table/2` over in-memory snapshots (`XC-30`, `XC-32`,
  `BUD-02`, `BUD-03`, `BUD-04`, `BUD-05`, `HC-08`, `XC-42`, `DR-72`, `DR-84`, `DR-89`).
  No database; `load/0` is covered in `WeddingPlannerWeb.Export.ComputedLoadTest`.

  Oracles are independent of the engine: `NormativeExamples`' B1/B3/O1/O2 figures and
  the figures `BudgetSnapshots.branches/0` documents, restated here in integer euros.
  """
  use ExUnit.Case, async: true

  import WeddingPlannerWeb.ComputedExportAssertions

  alias WeddingPlanner.BudgetSnapshots
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Export.Budget

  @today ~D[2026-09-25]

  @headers [
    "Category",
    "Forecast basis",
    "Target",
    "Committed — Minimum",
    "Committed — Likely",
    "Committed — Maximum",
    "Invoiced",
    "Paid",
    "Outstanding",
    "Forecast — Minimum",
    "Forecast — Likely",
    "Forecast — Maximum",
    "Needs attention",
    "Currency"
  ]

  @money_headers @headers -- ["Category", "Forecast basis", "Needs attention", "Currency"]

  defp table(snapshot), do: snapshot |> Budget.table(@today) |> assert_table_shape()

  defp eur(amount), do: WeddingPlanner.Money.new(amount)

  # Expected cells of one row as integer euros (`nil` = blank), from the fixture's
  # documented figures — never from the engine.
  defp assert_row(table, row, expected) do
    for {header, value} <- expected do
      actual = cell(table, row, header)

      case value do
        amount when is_integer(amount) ->
          assert_money(actual, eur(amount), header)

        %Money{} = money ->
          assert_money(actual, money, header)

        other ->
          assert actual == other, "#{header}: expected #{inspect(other)}, got #{inspect(actual)}"
      end
    end
  end

  test "stem and header row" do
    %{snapshot: snapshot} = BudgetSnapshots.branches()
    table = table(snapshot)

    assert table.stem == "budget"
    assert table.headers == @headers
  end

  test "every preset-dependent header names the role preset's stored name (HC-08)" do
    %{snapshot: snapshot} = BudgetSnapshots.branches()

    presets =
      Enum.map(snapshot.headcount_presets, fn
        %Preset{role: :maximum} = preset -> %{preset | name: "Everyone"}
        preset -> preset
      end)

    table = table(%{snapshot | headcount_presets: presets})

    assert "Committed — Everyone" in table.headers
    assert "Forecast — Everyone" in table.headers
    refute "Forecast — Maximum" in table.headers
  end

  describe "branches/0" do
    setup do
      %{snapshot: snapshot} = BudgetSnapshots.branches()
      %{table: table(snapshot)}
    end

    test "one row per category in order, then Total", %{table: table} do
      assert Enum.map(table.rows, &hd/1) ==
               ["Venue", "Photography", "Flowers", "Attire", "Church", "Total"]
    end

    test "every BUD-03 branch under Likely, with the preset-independent layers",
         %{table: table} do
      b1 = NE.expected("B1")

      assert_row(table, row_where!(table, "Category", "Venue"), %{
        "Forecast basis" => "Confirmed offers",
        "Target" => nil,
        "Committed — Likely" => NE.given("B1").committed,
        "Invoiced" => b1.invoiced,
        "Paid" => b1.paid,
        "Outstanding" => b1.outstanding,
        "Forecast — Likely" => b1.forecast,
        "Needs attention" => false,
        "Currency" => "EUR"
      })

      # Invoicing complete: the invoiced €1,800 wins, below the committed €2,000.
      assert_row(table, row_where!(table, "Category", "Photography"), %{
        "Forecast basis" => "Confirmed offers",
        "Target" => nil,
        "Committed — Likely" => 2_000,
        "Invoiced" => 1_800,
        "Paid" => 1_800,
        "Outstanding" => 0,
        "Forecast — Likely" => 1_800
      })

      assert_row(table, row_where!(table, "Category", "Flowers"), %{
        "Forecast basis" => "Planning pick",
        "Target" => 1_000,
        "Committed — Likely" => 0,
        "Invoiced" => 300,
        "Paid" => 0,
        "Outstanding" => 300,
        "Forecast — Likely" => 1_280
      })

      # The unlinked €3,100 tailor invoice beats the €2,500 target.
      assert_row(table, row_where!(table, "Category", "Attire"), %{
        "Forecast basis" => "Target",
        "Target" => NE.given("B3").category.target,
        "Invoiced" => 3_100,
        "Paid" => 3_100,
        "Forecast — Likely" => 3_100
      })

      assert_row(table, row_where!(table, "Category", "Church"), %{
        "Forecast basis" => "No target",
        "Target" => nil,
        "Committed — Likely" => 0,
        "Invoiced" => 0,
        "Forecast — Likely" => 0,
        "Needs attention" => false,
        "Currency" => "EUR"
      })

      # €11,726 + €1,800 + €1,280 + €3,100 + €0, as the fixture documents.
      assert 11_726 + 1_800 + 1_280 + 3_100 + 0 == 17_906

      assert_row(table, row_where!(table, "Category", "Total"), %{
        "Forecast basis" => nil,
        # Σ of the set targets only: Flowers €1,000 + Attire €2,500 (DR-72).
        "Target" => 3_500,
        "Committed — Likely" => 11_726 + 2_000,
        "Invoiced" => 3_000 + 1_800 + 300 + 3_100,
        "Paid" => 3_000 + 1_800 + 3_100,
        "Outstanding" => 300,
        "Forecast — Likely" => 17_906,
        "Needs attention" => nil,
        "Currency" => "EUR"
      })
    end

    test "the Minimum and Maximum columns (BUD-04)", %{table: table} do
      # Venue A's committed total is O2 under Minimum, O1 under Maximum (= Likely here).
      assert_row(table, row_where!(table, "Category", "Venue"), %{
        "Committed — Minimum" => NE.expected("O2").total,
        "Committed — Maximum" => NE.expected("O1").total,
        "Forecast — Minimum" => NE.expected("O2").total,
        "Forecast — Maximum" => NE.expected("O1").total
      })

      assert_row(table, row_where!(table, "Category", "Total"), %{
        "Forecast — Minimum" => 11_478 + 1_800 + 1_140 + 3_100,
        "Forecast — Maximum" => 17_906
      })
    end

    test "Σ category rows equals the Total row in every money column, unrounded (BUD-05)",
         %{table: table} do
      {categories, [total]} = Enum.split(table.rows, -1)

      for header <- @money_headers, header != "Target" do
        sum =
          categories
          |> Enum.map(&cell(table, &1, header))
          |> Enum.reduce(eur(0), &Money.add!/2)

        assert_money(cell(table, total, header), sum, header)
      end

      set_targets =
        categories |> Enum.map(&cell(table, &1, "Target")) |> Enum.reject(&is_nil/1)

      assert_money(cell(table, total, "Target"), Enum.reduce(set_targets, eur(0), &Money.add!/2))
    end
  end

  test "B3: Attire's forecast is €2,500 under every preset" do
    %{snapshot: snapshot} = BudgetSnapshots.b3()
    table = table(snapshot)
    %{category: name, forecast_under_every_preset: forecast} = NE.expected("B3")
    row = row_where!(table, "Category", name)

    assert cell(table, row, "Forecast basis") == "Target"

    for role <- ~w(Minimum Likely Maximum) do
      assert_money(cell(table, row, "Forecast — #{role}"), forecast, "Forecast — #{role}")
    end
  end

  # FP-93f
  test "Minimum and Maximum are not swapped: the lower forecast is under — Minimum" do
    %{snapshot: snapshot} = BudgetSnapshots.branches()
    table = table(snapshot)
    flowers = row_where!(table, "Category", "Flowers")

    # Florist F: €10 × 64 + €500 under Minimum, €10 × 78 + €500 under Maximum (= Likely).
    assert_money(cell(table, flowers, "Forecast — Minimum"), eur(1_140))
    assert_money(cell(table, flowers, "Forecast — Maximum"), eur(1_280))
  end

  # FP-93g
  test "Needs attention: true for a confirmed offer with an invalid line, false otherwise" do
    %{snapshot: snapshot, offers: %{"Photographer P" => photographer}} =
      BudgetSnapshots.branches()

    invalid = %OfferLine{
      id: 902,
      offer_id: photographer.id,
      label: "Second shooter",
      state: :optional,
      basis: :per_adult,
      event_id: nil,
      amount: eur(20),
      enabled: false
    }

    table = table(Snapshot.apply(snapshot, {:put, :offer_lines, invalid}))

    assert cell(table, row_where!(table, "Category", "Photography"), "Needs attention") == true

    for name <- ~w(Venue Flowers Attire Church) do
      assert cell(table, row_where!(table, "Category", name), "Needs attention") == false
    end
  end

  test "a role preset missing: preset-independent layers written, preset columns blank" do
    %{snapshot: snapshot} = BudgetSnapshots.branches()
    presets = Enum.map(snapshot.headcount_presets, &%{&1 | role: nil})

    table = table(%{snapshot | headcount_presets: presets})

    assert table.headers == @headers

    preset_columns =
      for layer <- ["Committed", "Forecast"],
          role <- ~w(Minimum Likely Maximum),
          do: "#{layer} — #{role}"

    for row <- table.rows, header <- preset_columns do
      assert cell(table, row, header) == nil
    end

    assert_row(table, row_where!(table, "Category", "Flowers"), %{
      "Forecast basis" => "Planning pick",
      "Target" => 1_000,
      "Invoiced" => 300,
      "Outstanding" => 300,
      "Needs attention" => false
    })

    assert_row(table, row_where!(table, "Category", "Total"), %{
      "Target" => 3_500,
      "Invoiced" => 8_200,
      "Paid" => 7_900
    })
  end

  test "no preset at all: still one row per category and a Total, never raises" do
    %{snapshot: snapshot} = BudgetSnapshots.branches()
    table = table(%{snapshot | headcount_presets: []})

    assert Enum.map(table.rows, &hd/1) ==
             ["Venue", "Photography", "Flowers", "Attire", "Church", "Total"]

    assert_row(table, row_where!(table, "Category", "Total"), %{"Invoiced" => 8_200})
  end
end
