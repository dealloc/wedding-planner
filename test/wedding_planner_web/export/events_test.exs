defmodule WeddingPlannerWeb.Export.EventsTest do
  @moduledoc """
  `WeddingPlannerWeb.Export.Events` (`DR-88`) — pure, in-memory.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Export.Events

  @today ~D[2026-09-25]

  test "headers and 1-based position, in snapshot.events order" do
    ceremony = %Event{
      id: 1,
      name: "Ceremony",
      date: ~D[2027-05-13],
      location: "Town hall",
      notes: nil
    }

    reception = %Event{
      id: 2,
      name: "Reception",
      date: nil,
      location: nil,
      notes: "Ask about parking"
    }

    snapshot = %Snapshot{events: [ceremony, reception]}
    table = Events.table(snapshot, @today)

    assert table.stem == "events"
    assert table.headers == ["Position", "Name", "Date", "Location", "Notes"]

    assert table.rows == [
             [1, "Ceremony", ~D[2027-05-13], "Town hall", nil],
             [2, "Reception", nil, nil, "Ask about parking"]
           ]
  end

  test "an event with no date yet is a blank cell, not a nil sentinel string" do
    event = %Event{id: 1, name: "TBD", date: nil, location: nil, notes: nil}
    snapshot = %Snapshot{events: [event]}

    [row] = Events.table(snapshot, @today).rows
    assert Enum.at(row, 2) == nil
  end

  test "no money is exported, so there is no Currency column" do
    snapshot = %Snapshot{events: []}
    table = Events.table(snapshot, @today)
    refute "Currency" in table.headers
  end
end
