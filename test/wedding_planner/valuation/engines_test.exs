defmodule WeddingPlanner.Valuation.EnginesTest do
  @moduledoc """
  The engine contracts exist with their documented arity. Every engine is implemented
  now (C3: `WeddingPlanner.Valuation.Offer`; B3: `WeddingPlanner.Valuation.Budget`), and
  each has its own test module; what stays here is the export check and the `headcount:`
  seam's guard (a source scan of `lib/`), which is what keeps a test seam out of
  production.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Valuation.Budget
  alias WeddingPlanner.Valuation.Offer

  test "Budget's forecast/2, forecast/3, overall/2, overall/3, for_roles/1, for_roles/2 are exported" do
    Code.ensure_loaded!(Budget)

    for {name, arity} <- [
          forecast: 2,
          forecast: 3,
          overall: 2,
          overall: 3,
          for_roles: 1,
          for_roles: 2
        ] do
      assert function_exported?(Budget, name, arity), "Budget.#{name}/#{arity} is not exported"
    end
  end

  describe "the headcount: test seam" do
    test "Offer.total/4 and Budget.forecast/3 exist alongside total/3 and forecast/2" do
      Code.ensure_loaded!(Offer)
      Code.ensure_loaded!(Budget)

      assert function_exported?(Offer, :total, 3)
      assert function_exported?(Offer, :total, 4)
      assert function_exported?(Budget, :forecast, 2)
      assert function_exported?(Budget, :forecast, 3)
    end

    @seam_owners [
      "lib/wedding_planner/valuation/offer.ex",
      "lib/wedding_planner/valuation/budget.ex"
    ]

    # `headcount:` is the keyword form; `:headcount` catches `Keyword.put(opts, :headcount,
    # f)` and `[{:headcount, f}]`.
    @seam_pattern ~r/headcount:|:headcount\b/

    defp lib_files do
      "lib/**/*"
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
    end

    test "the source scan sees the option where it is defined (so the guard is not vacuous)" do
      files = lib_files()

      for owner <- @seam_owners do
        assert owner in files
        assert File.read!(owner) =~ @seam_pattern
      end
    end

    test "no production code outside the two engines mentions the headcount: option" do
      violations =
        for file <- lib_files(),
            file not in @seam_owners,
            File.read!(file) =~ @seam_pattern,
            do: file

      assert violations == [],
             "the `headcount:` option is a test seam (Offer.total/4, Budget.forecast/3) and " <>
               "production code must never pass it; found in #{inspect(violations)}"
    end
  end
end
