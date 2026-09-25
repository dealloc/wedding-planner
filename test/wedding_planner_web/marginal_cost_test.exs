defmodule WeddingPlannerWeb.MarginalCostTest do
  @moduledoc """
  Pure tests for `WeddingPlannerWeb.MarginalCost.build/3`'s caption (`DR-81`): whether a
  person is counted decides "Not counted…", never a zero marginal cost — a counted guest
  can cost €0 when an included quantity or a minimum spend absorbs them.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlannerWeb.MarginalCost

  defp marginal(id, name, person) do
    %{
      preset: %Preset{id: id, name: name},
      formula: %Formula{label: "Marginal cost", steps: [], total: {:money, Money.new(:EUR, 0)}},
      removed: [person]
    }
  end

  defp zero_marginals(person) do
    {:ok,
     %{
       minimum: marginal(1, "Minimum", person),
       likely: marginal(2, "Likely", person),
       maximum: marginal(3, "Maximum", person)
     }}
  end

  test "a counted guest who costs €0 is not captioned 'Not counted'" do
    person = %Person{id: 7, first_name: "Jasper", last_name: "Van Damme"}

    view = MarginalCost.build(zero_marginals(person), person, true)

    assert view.ranged.equal?
    assert view.caption == "How much the forecast would drop without Jasper Van Damme"
  end

  test "someone counted nowhere is captioned 'Not counted…'" do
    person = %Person{id: 8, first_name: "Griet", last_name: "Peeters"}

    view = MarginalCost.build(zero_marginals(person), person, false)

    assert view.caption == "Not counted for any event under these presets."
  end
end
