defmodule WeddingPlanner.Valuation.EnginesTest do
  @moduledoc """
  The three engine contracts exist with their documented arity and, until their slices
  land, **raise** rather than return a plausible wrong number. When a slice implements
  an engine, it replaces that engine's test here with real ones.

  The `headcount:` seam's guard (a source scan of `lib/`) stays when C3 and B3 land: it
  is what keeps a test seam out of production.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Valuation.Budget
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Offer
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot

  setup do
    event = %Event{id: 1, name: "Dinner", sort_order: 0}
    %{snapshot: %Snapshot{events: [event]}, event: event, preset: %Preset{name: "Likely"}}
  end

  test "Headcount.evaluate/3 raises until slice G4", ctx do
    assert_raise RuntimeError,
                 ~r/Headcount\.evaluate\/3 is not yet implemented \(slice G4\)/,
                 fn ->
                   Headcount.evaluate(ctx.snapshot, ctx.preset, ctx.event)
                 end

    assert_raise RuntimeError, ~r/slice G4/, fn ->
      Headcount.evaluate(ctx.snapshot, ctx.preset, :all_events)
    end
  end

  test "Offer.total/3 raises until slice C3", ctx do
    assert_raise RuntimeError, ~r/Offer\.total\/3 is not yet implemented \(slice C3\)/, fn ->
      Offer.total(ctx.snapshot, %{__struct__: FutureOffer, id: 1}, ctx.preset)
    end
  end

  test "Budget.forecast/2 raises until slice B3", ctx do
    assert_raise RuntimeError, ~r/Budget\.forecast\/2 is not yet implemented \(slice B3\)/, fn ->
      Budget.forecast(ctx.snapshot, ctx.preset)
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

    test "Offer.total/4 still raises until slice C3 when given the option", ctx do
      assert_raise RuntimeError, ~r/not yet implemented \(slice C3\)/, fn ->
        Offer.total(ctx.snapshot, %{__struct__: FutureOffer, id: 1}, ctx.preset,
          headcount: WeddingPlanner.NormativeExamples.fixed_headcount()
        )
      end
    end

    test "Budget.forecast/3 still raises until slice B3 when given the option", ctx do
      assert_raise RuntimeError, ~r/not yet implemented \(slice B3\)/, fn ->
        Budget.forecast(ctx.snapshot, ctx.preset,
          headcount: WeddingPlanner.NormativeExamples.fixed_headcount()
        )
      end
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
