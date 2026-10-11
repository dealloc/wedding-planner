defmodule WeddingPlannerWeb.SeatingOverviewTest do
  @moduledoc "`WeddingPlannerWeb.SeatingOverview.plan/3` (SEAT-54, SEAT-70): the plan view model."
  use ExUnit.Case, async: true

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Seating.Table
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Seating
  alias WeddingPlanner.Valuation.SeatingPlan
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.SeatingOverview

  test "unit-mates are listed together even when others come between them in seating order" do
    event = %Event{id: 1, name: "Dinner", couple_attends: false}
    host = %Person{id: 1, first_name: "Pieter", group_id: 1}
    others = for id <- 2..3, do: %Person{id: id, first_name: "P#{id}", group_id: 1}
    plus_one = %Person{id: 4, host_id: 1, plus_one_status: :confirmed}
    persons = [host | others] ++ [plus_one]

    invitations =
      for p <- [host | others],
          do: %Invitation{id: p.id, person_id: p.id, event_id: 1, status: :accepted}

    snapshot = %Snapshot{events: [event], persons: persons, invitations: invitations}

    analysis =
      Seating.analyse(snapshot, Enum.find(Preset.defaults(), &(&1.role == :likely)), event)

    plan = SeatingPlan.compute(analysis, [%Table{id: 1, name: "T1", min_seats: 1, max_seats: 6}])
    names = SeatingOverview.names(persons, [], "the couple")

    assert %{tables: [%{units: units}]} = SeatingOverview.plan(analysis, plan, names)
    assert Enum.map(hd(units), & &1.name) == ["Pieter", "+1 of Pieter"]
  end
end
