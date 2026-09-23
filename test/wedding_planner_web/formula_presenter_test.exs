defmodule WeddingPlannerWeb.FormulaPresenterTest do
  @moduledoc """
  `CST-34`, `BUD-08`, `NFR-32`, `NFR-14`: a `WeddingPlanner.Valuation.Formula` goes
  through `WeddingPlannerWeb.FormulaPresenter.present/1` into the task-06
  `WeddingPlannerWeb.DisplayComponents.formula/1` component **unchanged**, rounding only
  at render, and never reconciled.

  The figures here are arbitrary; normative examples are task 24's fixture.
  """
  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest
  import WeddingPlannerWeb.DisplayComponents

  alias WeddingPlanner.Money, as: M
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Formula.Step
  alias WeddingPlannerWeb.FormulaPresenter

  # ex_money renders a non-breaking space after the euro sign (DR-18 finding b).
  @eur "\u20AC\u00A0"

  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp text(html, selector), do: html |> find(selector) |> LazyHTML.text() |> String.trim()
  defp present?(html, selector), do: not Enum.empty?(find(html, selector))

  defp euros(amount), do: {:money, M.new(Decimal.new(amount))}

  # Exactly how a view will use it: the presenter's map spread into the component.
  defp render_formula(formula) do
    assigns = %{formula: formula}

    rendered_to_string(~H"""
    <.formula id="f" open {FormulaPresenter.present(@formula)} />
    """)
  end

  defp step_label(html, index), do: text(html, "#f-step-#{index} > span:first-child")
  defp step_value(html, index), do: text(html, "#f-step-#{index} > span:last-child")

  describe "present/1" do
    test "produces exactly the component's documented input, every value a display string" do
      formula = %Formula{
        label: "Total",
        steps: [
          %Step{label: "Preset used", value: {:preset, "Likely"}},
          %Step{
            label: [
              "Drinks — ",
              {:count, 40},
              " × ",
              euros("20"),
              " excl., ",
              {:rate, Decimal.new("0.21")},
              " VAT"
            ],
            value: euros("968")
          },
          %Step{label: "Minimum spend applied", value: euros("1500")}
        ],
        total: euros("1500")
      }

      assert FormulaPresenter.present(formula) == %{
               total_label: "Total",
               total: "#{@eur}1.500,00",
               steps: [
                 %{label: "Preset used", value: "Likely"},
                 %{
                   label: "Drinks — 40 × #{@eur}20,00 excl., 21% VAT",
                   value: "#{@eur}968,00"
                 },
                 %{label: "Minimum spend applied", value: "#{@eur}1.500,00"}
               ]
             }
    end

    test "counts use the app locale's grouping, rates keep every decimal they have" do
      formula = %Formula{
        label: ["Headcount (", {:preset, "Maximum"}, ")"],
        steps: [
          %Step{label: "Reduced rate", value: {:rate, Decimal.new("0.055")}},
          %Step{label: "Zero rate", value: {:rate, Decimal.new("0")}},
          %Step{label: "Standard rate, trailing zeros", value: {:rate, Decimal.new("0.2100")}}
        ],
        total: {:count, 1234}
      }

      assert %{total_label: "Headcount (Maximum)", total: "1.234", steps: steps} =
               FormulaPresenter.present(formula)

      assert Enum.map(steps, & &1.value) == ["5,5%", "0%", "21%"]
    end
  end

  describe "round trip through formula/1 (task 06 component, unchanged)" do
    test "renders the label, the total and every step in the formula's order" do
      formula = %Formula{
        label: "Total",
        steps: [
          %Step{label: "Preset used", value: {:preset, "Likely"}},
          %Step{label: ["Base price"], value: euros("3000")},
          %Step{
            label: ["Seating (", {:count, 90}, " − ", {:count, 50}, " included) × ", euros("10")],
            value: euros("400")
          }
        ],
        total: euros("3400")
      }

      html = render_formula(formula)

      assert text(html, "#f-total") == "#{@eur}3.400,00"
      assert step_label(html, 0) == "Preset used"
      assert step_value(html, 0) == "Likely"
      assert step_label(html, 1) == "Base price"
      assert step_value(html, 1) == "#{@eur}3.000,00"
      assert step_label(html, 2) == "Seating (90 − 50 included) × #{@eur}10,00"
      assert step_value(html, 2) == "#{@eur}400,00"
      refute present?(html, "#f-step-3")
    end

    test "rounded steps that do not sum to the rounded total are shown as they are — never reconciled (NFR-14)" do
      # Three unrounded thirds of a euro, total computed from the unrounded chain:
      # 3 × 0,3333… = 0,9999… → displayed € 1,00, while each step displays € 0,33
      # (the displayed steps sum to € 0,99).
      third = M.new(Decimal.div(Decimal.new(1), Decimal.new(3)))

      formula = %Formula{
        steps: for(n <- 1..3, do: %Step{label: "Part #{n}", value: {:money, third}}),
        total: {:money, M.sum([third, third, third])}
      }

      html = render_formula(formula)

      assert text(html, "#f-total") == "#{@eur}1,00"
      assert for(i <- 0..2, do: step_value(html, i)) == List.duplicate("#{@eur}0,33", 3)

      # Nothing added to make them agree: exactly the formula's three steps, and the
      # standing caption that states the discrepancy is expected.
      refute present?(html, "#f-step-3")
      assert text(html, "#f-caption") =~ "may not sum exactly to it"
    end

    test "a headcount formula — a count total — renders through the same component" do
      formula = %Formula{
        label: "Attendees",
        steps: [
          %Step{label: "Preset used", value: {:preset, "Likely"}},
          %Step{label: "Adults", value: {:count, 40}},
          %Step{label: "Children", value: {:count, 5}}
        ],
        total: {:count, 45}
      }

      html = render_formula(formula)

      assert text(html, "#f > div > span:first-child") == "Attendees"
      assert text(html, "#f-total") == "45"
      assert step_value(html, 1) == "40"
    end
  end
end
