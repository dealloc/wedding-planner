defmodule WeddingPlannerWeb.BudgetChartComponentsTest do
  @moduledoc """
  Renders `WeddingPlannerWeb.BudgetChartComponents` from real
  `WeddingPlannerWeb.BudgetChart` presenter output (`DR-77`) — assertions go through
  `LazyHTML` element/attribute selectors on stable DOM ids, never raw HTML string matching
  (`AGENTS.md`).
  """
  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest
  import WeddingPlannerWeb.BudgetChartComponents

  alias WeddingPlanner.Money
  alias WeddingPlannerWeb.BudgetChart

  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp present?(html, selector), do: not Enum.empty?(find(html, selector))
  defp text(html, selector), do: html |> find(selector) |> LazyHTML.text()
  defp attribute(html, selector, name), do: html |> find(selector) |> LazyHTML.attribute(name)

  describe "composition_bar/1 — design numbers (design record §7 v2)" do
    setup do
      chart =
        BudgetChart.composition(%{
          overall_budget: Money.new(45_000),
          paid: Money.new(3_800),
          outstanding: Money.new(4_926),
          forecast: Money.new(21_352)
        })

      html =
        render_component(&composition_bar/1, %{
          id: "budget-composition",
          chart: chart,
          preset_name: "Likely"
        })

      %{html: html}
    end

    test "one segment per kind, in order, each with the expected tone class", %{html: html} do
      assert present?(html, "#budget-composition-segment-0[data-kind=paid]")
      assert present?(html, "#budget-composition-segment-1[data-kind=outstanding]")
      assert present?(html, "#budget-composition-segment-2[data-kind=not_yet_billed]")
      assert present?(html, "#budget-composition-segment-3[data-kind=available]")
      refute present?(html, "#budget-composition-segment-4")

      assert html =~ "bg-good"
      assert html =~ "bg-warn"
      assert html =~ "repeating-linear-gradient"
      assert html =~ "border-dashed"
    end

    test "segment widths are the exact basis-point percentages, no float drift", %{html: html} do
      assert attribute(html, "#budget-composition-segment-0", "style") == ["width: 8.44%"]
      assert attribute(html, "#budget-composition-segment-1", "style") == ["width: 10.95%"]
      assert attribute(html, "#budget-composition-segment-2", "style") == ["width: 28.06%"]
      assert attribute(html, "#budget-composition-segment-3", "style") == ["width: 52.55%"]
    end

    test "the caption names the overall budget and the preset (HC-08)", %{html: html} do
      caption = text(html, "#budget-composition-caption")
      assert caption =~ "45.000,00"
      assert caption =~ "Likely"
    end

    test "the track's aria-label names the preset and every segment amount (HC-08)", %{
      html: html
    } do
      [label] = attribute(html, "#budget-composition-track", "aria-label")

      assert label =~ "Likely"
      assert label =~ "3.800,00"
      assert label =~ "4.926,00"
      assert label =~ "12.626,00"
      assert label =~ "23.648,00"
    end

    test "not over budget: no over-budget line", %{html: html} do
      refute present?(html, "#budget-composition-over-budget")
    end
  end

  describe "composition_bar/1 — over budget" do
    test "the over-budget line renders only when over_budget is set (FP-83b)" do
      chart =
        BudgetChart.composition(%{
          overall_budget: Money.new(45_000),
          paid: Money.new(10_000),
          outstanding: Money.new(5_000),
          forecast: Money.new(50_000)
        })

      html =
        render_component(&composition_bar/1, %{id: "b", chart: chart, preset_name: "Max"})

      assert present?(html, "#b-over-budget")
      assert text(html, "#b-over-budget") =~ "Over budget by"
      assert text(html, "#b-over-budget") =~ "5.000,00"
      refute present?(html, "#b-segment-0[data-kind=available]")
      refute present?(html, "#b-segment-1[data-kind=available]")
      refute present?(html, "#b-segment-2[data-kind=available]")
    end
  end

  describe "composition_bar/1 — no budget set" do
    test "the caption reads 'no overall budget set' and names the preset" do
      chart =
        BudgetChart.composition(%{
          overall_budget: nil,
          paid: Money.new(1_000),
          outstanding: Money.new(500),
          forecast: Money.new(3_000)
        })

      html = render_component(&composition_bar/1, %{id: "b", chart: chart, preset_name: "Min"})

      caption = text(html, "#b-caption")
      assert caption =~ "no overall budget set"
      assert caption =~ "Min"
    end
  end

  describe "composition_bar/1 — no rendered boolean literal (the codebase's own known trap)" do
    test "never renders the literal word 'false' anywhere" do
      chart =
        BudgetChart.composition(%{
          overall_budget: nil,
          paid: Money.new(0),
          outstanding: Money.new(0),
          forecast: Money.new(0)
        })

      html = render_component(&composition_bar/1, %{id: "b", chart: chart, preset_name: "Likely"})

      refute html =~ "false"
    end
  end

  describe "category_bars/1 — design numbers" do
    setup do
      rows = [
        %{
          id: "venue",
          name: "Venue",
          paid: Money.new(3_000),
          outstanding: Money.new(0),
          forecast: Money.new(11_726),
          maximum_forecast: Money.new(11_981)
        },
        %{
          id: "catering",
          name: "Catering",
          paid: Money.new(0),
          outstanding: Money.new(4_926),
          forecast: Money.new(4_926),
          maximum_forecast: Money.new(4_926)
        },
        %{
          id: "flowers",
          name: "Flowers",
          paid: Money.new(0),
          outstanding: Money.new(0),
          forecast: Money.new(0),
          maximum_forecast: Money.new(0)
        }
      ]

      chart = BudgetChart.categories(rows, Money.new(45_000))

      html =
        render_component(&category_bars/1, %{
          id: "budget-categories",
          chart: chart,
          preset_name: "Likely"
        })

      %{html: html}
    end

    test "the caption names the view and the preset", %{html: html} do
      assert text(html, "#budget-categories-caption") == "By category (Likely)"
    end

    test "venue's bar carries a dashed range-ghost segment", %{html: html} do
      assert present?(html, "#budget-categories-row-venue-segment-3[data-kind=range_ghost]")
      assert html =~ "border-dashed"
    end

    test "catering (fully invoiced, unpaid) is a single solid outstanding block", %{html: html} do
      assert present?(html, "#budget-categories-row-catering-segment-1[data-kind=outstanding]")

      assert attribute(html, "#budget-categories-row-catering-segment-1", "style") == [
               "width: 100.00%"
             ]

      refute present?(html, "#budget-categories-row-catering-segment-3")
    end

    test "flowers (empty, €0) renders the dashed 'nothing yet' placeholder, not a zero-width bar",
         %{html: html} do
      assert present?(html, "#budget-categories-row-flowers-empty")
      assert text(html, "#budget-categories-row-flowers-empty") =~ "nothing yet"
      refute present?(html, "#budget-categories-row-flowers-track")
    end

    test "every row shows its own name and forecast amount", %{html: html} do
      assert text(html, "#budget-categories-row-venue-name") =~ "Venue"
      assert text(html, "#budget-categories-row-venue-amount") =~ "11.726,00"
      assert text(html, "#budget-categories-row-catering-amount") =~ "4.926,00"
      assert text(html, "#budget-categories-row-flowers-amount") =~ "0,00"
    end

    test "each non-empty row's bar carries an aria-label naming the preset (HC-08)", %{
      html: html
    } do
      [label] = attribute(html, "#budget-categories-row-venue-track", "aria-label")
      assert label =~ "Likely"
      assert label =~ "Venue"
    end

    test "the legend lists every segment kind exactly once", %{html: html} do
      legend = text(html, "#budget-categories-legend")
      assert legend =~ "Paid"
      assert legend =~ "Outstanding (unpaid)"
      assert legend =~ "Forecast, not yet billed"
      assert legend =~ "Available"
      assert legend =~ "Possible range to Maximum"
    end

    test "never renders the literal word 'false' anywhere", %{html: html} do
      refute html =~ "false"
    end
  end

  describe "FP-83d — the preset name must be in the aria-label, not only the legend" do
    test "a category row's aria-label alone names the preset, independent of the legend" do
      rows = [
        %{
          id: "attire",
          name: "Attire",
          paid: Money.new(0),
          outstanding: Money.new(0),
          forecast: Money.new(2_500),
          maximum_forecast: Money.new(2_500)
        }
      ]

      chart = BudgetChart.categories(rows, Money.new(45_000))
      html = render_component(&category_bars/1, %{id: "b", chart: chart, preset_name: "Max"})

      [label] = attribute(html, "#b-row-attire-track", "aria-label")
      assert label =~ "Max"
    end
  end
end
