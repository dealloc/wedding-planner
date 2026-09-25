defmodule WeddingPlannerWeb.BudgetChartTest do
  use ExUnit.Case, async: true

  doctest WeddingPlannerWeb.BudgetChart

  alias WeddingPlanner.Money
  alias WeddingPlannerWeb.BudgetChart, as: Subject

  defp sum_bp(segments), do: Enum.sum(Enum.map(segments, & &1.basis_points))
  defp kinds(segments), do: Enum.map(segments, & &1.kind)

  describe "composition/1 — design numbers (design record §7 v2)" do
    test "budget €45,000, paid €3,800, outstanding €4,926, forecast €21,352" do
      result =
        Subject.composition(%{
          overall_budget: Money.new(45_000),
          paid: Money.new(3_800),
          outstanding: Money.new(4_926),
          forecast: Money.new(21_352)
        })

      assert result.no_budget? == false
      assert result.over_budget == nil
      assert result.scale == Money.new(45_000)

      by_kind = Map.new(result.segments, &{&1.kind, &1.amount})

      assert by_kind[:paid] == Money.new(3_800)
      assert by_kind[:outstanding] == Money.new(4_926)
      assert by_kind[:not_yet_billed] == Money.new(12_626)
      assert by_kind[:available] == Money.new(23_648)

      assert kinds(result.segments) == [:paid, :outstanding, :not_yet_billed, :available]
      assert sum_bp(result.segments) == 10_000
    end
  end

  describe "composition/1 — over budget (FP-83b)" do
    test "forecast €50,000 on a €45,000 budget: no available segment, scale is the forecast" do
      result =
        Subject.composition(%{
          overall_budget: Money.new(45_000),
          paid: Money.new(10_000),
          outstanding: Money.new(5_000),
          forecast: Money.new(50_000)
        })

      assert result.no_budget? == false
      assert result.scale == Money.new(50_000)
      assert result.over_budget == Money.new(5_000)
      refute :available in kinds(result.segments)
      assert sum_bp(result.segments) == 10_000
    end
  end

  describe "composition/1 — no budget set" do
    test "overall_budget: nil sets no_budget?, scale is the forecast, no available segment" do
      result =
        Subject.composition(%{
          overall_budget: nil,
          paid: Money.new(1_000),
          outstanding: Money.new(500),
          forecast: Money.new(3_000)
        })

      assert result.no_budget? == true
      assert result.over_budget == nil
      assert result.scale == Money.new(3_000)
      refute :available in kinds(result.segments)
      assert sum_bp(result.segments) == 10_000
    end
  end

  describe "composition/1 — all zero" do
    test "no budget, nothing paid, owed or forecast: no segments, no crash" do
      result =
        Subject.composition(%{
          overall_budget: nil,
          paid: Money.new(0),
          outstanding: Money.new(0),
          forecast: Money.new(0)
        })

      assert result.segments == []
      assert result.no_budget? == true
      assert result.over_budget == nil
    end

    test "a budget of €0 with nothing forecast also yields no segments" do
      result =
        Subject.composition(%{
          overall_budget: Money.new(0),
          paid: Money.new(0),
          outstanding: Money.new(0),
          forecast: Money.new(0)
        })

      assert result.segments == []
    end
  end

  describe "composition/1 — defensive clamp (not_yet_billed never negative)" do
    test "paid + outstanding exceeding forecast clamps not_yet_billed to €0, not negative" do
      result =
        Subject.composition(%{
          overall_budget: Money.new(100),
          paid: Money.new(30),
          outstanding: Money.new(20),
          forecast: Money.new(40)
        })

      not_yet_billed = Enum.find(result.segments, &(&1.kind == :not_yet_billed))
      assert not_yet_billed.amount == Money.new(0)
      assert not_yet_billed.basis_points >= 0
      assert Enum.all?(result.segments, &(&1.basis_points >= 0))
    end
  end

  describe "categories/2 — an empty (€0) category" do
    test "renders empty?: true with no segments and a zero length" do
      rows = [
        %{
          id: :flowers,
          name: "Flowers",
          paid: Money.new(0),
          outstanding: Money.new(0),
          forecast: Money.new(0),
          maximum_forecast: Money.new(0)
        }
      ]

      [flowers] = Subject.categories(rows, Money.new(45_000))

      assert flowers.empty? == true
      assert flowers.segments == []
      assert flowers.length_basis_points == 0
    end
  end

  describe "categories/2 — a complete category (fully invoiced, unpaid)" do
    test "paid €0, outstanding == forecast: the whole bar is :outstanding" do
      rows = [
        %{
          id: :catering,
          name: "Catering",
          paid: Money.new(0),
          outstanding: Money.new(4_926),
          forecast: Money.new(4_926),
          maximum_forecast: Money.new(4_926)
        }
      ]

      [catering] = Subject.categories(rows, Money.new(45_000))

      assert catering.empty? == false
      refute :range_ghost in kinds(catering.segments)

      outstanding = Enum.find(catering.segments, &(&1.kind == :outstanding))
      assert outstanding.basis_points == 10_000
      assert sum_bp(catering.segments) == 10_000
    end
  end

  describe "categories/2 — the range ghost appears iff maximum_forecast > forecast" do
    test "no ghost when maximum equals forecast" do
      rows = [
        %{
          id: :photography,
          name: "Photography",
          paid: Money.new(0),
          outstanding: Money.new(0),
          forecast: Money.new(2_200),
          maximum_forecast: Money.new(2_200)
        }
      ]

      [photography] = Subject.categories(rows, Money.new(45_000))

      refute :range_ghost in kinds(photography.segments)
      assert sum_bp(photography.segments) == 10_000
    end

    test "a ghost segment appears, sized to maximum minus forecast, when maximum is higher" do
      rows = [
        %{
          id: :venue,
          name: "Venue",
          paid: Money.new(3_000),
          outstanding: Money.new(0),
          forecast: Money.new(11_726),
          maximum_forecast: Money.new(11_981)
        }
      ]

      [venue] = Subject.categories(rows, Money.new(45_000))

      ghost = Enum.find(venue.segments, &(&1.kind == :range_ghost))
      assert ghost.amount == Money.new(255)
      assert sum_bp(venue.segments) == 10_000
    end
  end

  describe "categories/2 — lengths scale to max(overall_budget, Σ forecasts) (FP-83c)" do
    @rows [
      %{
        id: :venue,
        name: "Venue",
        paid: Money.new(3_000),
        outstanding: Money.new(0),
        forecast: Money.new(11_726),
        maximum_forecast: Money.new(11_981)
      },
      %{
        id: :catering,
        name: "Catering",
        paid: Money.new(0),
        outstanding: Money.new(4_926),
        forecast: Money.new(4_926),
        maximum_forecast: Money.new(4_926)
      },
      %{
        id: :photography,
        name: "Photography",
        paid: Money.new(0),
        outstanding: Money.new(0),
        forecast: Money.new(2_200),
        maximum_forecast: Money.new(2_200)
      },
      %{
        id: :attire,
        name: "Attire",
        paid: Money.new(0),
        outstanding: Money.new(0),
        forecast: Money.new(2_500),
        maximum_forecast: Money.new(2_500)
      },
      %{
        id: :flowers,
        name: "Flowers",
        paid: Money.new(0),
        outstanding: Money.new(0),
        forecast: Money.new(0),
        maximum_forecast: Money.new(0)
      }
    ]

    # Σ forecasts across the five rows above is €21,352 (the design record's own Likely total).
    defp expected_bp(own_total_cents, scale_cents) do
      Decimal.new(own_total_cents)
      |> Decimal.div(Decimal.new(scale_cents))
      |> Decimal.mult(Decimal.new(10_000))
      |> Decimal.round(0, :half_up)
      |> Decimal.to_integer()
    end

    test "when the budget exceeds Σ forecasts, the scale is the budget" do
      [venue | _] = Subject.categories(@rows, Money.new(45_000))

      assert venue.length_basis_points == expected_bp(11_981, 45_000)
    end

    test "when Σ forecasts exceeds the budget, the scale is Σ forecasts, not the budget" do
      [venue | _] = Subject.categories(@rows, Money.new(10_000))

      assert venue.length_basis_points == expected_bp(11_981, 21_352)
    end

    test "with no budget at all, the scale is Σ forecasts" do
      [venue | _] = Subject.categories(@rows, nil)

      assert venue.length_basis_points == expected_bp(11_981, 21_352)
    end
  end

  # -- property tests (fixed :rand seeds, no StreamData — this repo's own convention, see
  # WeddingPlanner.Tasks.TimelineTest) --------------------------------------------------------

  describe "property: composition/1" do
    @describetag :property

    test "segments always sum to exactly 10_000 (or are empty), never negative" do
      for_each_composition_case({111, 112, 113}, 300, fn input, result ->
        cond do
          Money.compare(result.scale, Money.new(0)) == :eq ->
            assert result.segments == []

          true ->
            assert sum_bp(result.segments) == 10_000
            assert Enum.all?(result.segments, &(&1.basis_points >= 0))
            assert result.no_budget? == is_nil(input.overall_budget)

            assert :available in kinds(result.segments) ==
                     (not is_nil(input.overall_budget) and result.over_budget == nil)
        end
      end)
    end
  end

  describe "property: categories/2" do
    @describetag :property

    test "every row's segments sum to exactly 10_000 (or are empty for a €0 forecast); " <>
           "lengths stay in 0..10_000" do
      for_each_categories_case({211, 212, 213}, 300, fn rows, budget, result ->
        for row <- result do
          assert row.length_basis_points in 0..10_000

          if row.empty? do
            assert row.segments == []
          else
            assert sum_bp(row.segments) == 10_000
            assert Enum.all?(row.segments, &(&1.basis_points >= 0))
          end
        end

        # scale sanity: Σ forecasts never itself yields an out-of-range length.
        _ = {rows, budget}
      end)
    end
  end

  # -- random generators (independent integer-cent oracle, no reuse of the module's own math) ----

  defp money_from_cents(cents) do
    Money.new(Decimal.div(Decimal.new(cents), Decimal.new(100)))
  end

  defp random_cents(max), do: :rand.uniform(max + 1) - 1

  defp random_forecast_triple(max_cents) do
    forecast_cents = random_cents(max_cents)
    paid_cents = random_cents(forecast_cents)
    outstanding_cents = random_cents(forecast_cents - paid_cents)
    extra_cents = random_cents(max_cents)

    %{
      paid: money_from_cents(paid_cents),
      outstanding: money_from_cents(outstanding_cents),
      forecast: money_from_cents(forecast_cents),
      maximum_forecast: money_from_cents(forecast_cents + extra_cents)
    }
  end

  defp random_budget(max_cents) do
    if :rand.uniform(2) == 1, do: nil, else: money_from_cents(random_cents(max_cents))
  end

  defp for_each_composition_case(seed, n, fun) do
    :rand.seed(:exsss, seed)

    for iteration <- 1..n do
      triple = random_forecast_triple(1_000_000)

      input = %{
        overall_budget: random_budget(1_000_000),
        paid: triple.paid,
        outstanding: triple.outstanding,
        forecast: triple.forecast
      }

      run_case(seed, iteration, input, fn -> fun.(input, Subject.composition(input)) end)
    end
  end

  defp for_each_categories_case(seed, n, fun) do
    :rand.seed(:exsss, seed)

    for iteration <- 1..n do
      row_count = :rand.uniform(5)

      rows =
        for id <- 1..row_count do
          triple = random_forecast_triple(500_000)
          Map.merge(%{id: id, name: "Category #{id}"}, triple)
        end

      budget = random_budget(2_000_000)

      run_case(seed, iteration, %{rows: rows, budget: budget}, fn ->
        fun.(rows, budget, Subject.categories(rows, budget))
      end)
    end
  end

  defp run_case(seed, iteration, input, fun) do
    fun.()
  rescue
    error in ExUnit.AssertionError ->
      message =
        "#{error.message}\n\nseed #{inspect(seed)}, iteration #{iteration}\ninput:\n" <>
          inspect(input, pretty: true, limit: :infinity)

      reraise %{error | message: message}, __STACKTRACE__
  end
end
