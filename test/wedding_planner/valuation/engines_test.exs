defmodule WeddingPlanner.Valuation.EnginesTest do
  @moduledoc """
  The three engine contracts exist with their documented arity and, until their slices
  land, **raise** rather than return a plausible wrong number. When a slice implements
  an engine, it replaces that engine's test here with real ones.
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
end
