defmodule WeddingPlanner.Valuation.SnapshotTest do
  @moduledoc """
  `WeddingPlanner.Valuation.Snapshot.apply/2` over an in-memory snapshot — no database,
  no sandbox (`NFR-41`). The change representation `BUD-20`–`BUD-22` what-ifs are built
  from. The database side (no queries, nothing written) is in `SnapshotLoadTest`.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Valuation.Snapshot

  defp snapshot do
    %Snapshot{
      events: [
        %Event{id: 1, name: "Ceremony", sort_order: 0},
        %Event{id: 2, name: "Dinner", sort_order: 1},
        %Event{id: 3, name: "Party", sort_order: 2}
      ]
    }
  end

  defp names(%Snapshot{events: events}), do: Enum.map(events, & &1.name)

  test "a snapshot can be built in memory, with every collection empty and the budget unset" do
    snapshot = %Snapshot{}

    assert snapshot.events == []
    assert snapshot.persons == []
    assert snapshot.settings.overall_budget == nil
  end

  describe "{:put, collection, entity}" do
    test "replaces the element with the same id in place, keeping its position" do
      changed = Snapshot.apply(snapshot(), {:put, :events, %Event{id: 2, name: "Gala dinner"}})

      assert names(changed) == ["Ceremony", "Gala dinner", "Party"]
    end

    test "appends an entity whose id no row has — a hypothetical row with a ref id" do
      id = make_ref()
      changed = Snapshot.apply(snapshot(), {:put, :events, %Event{id: id, name: "Brunch"}})

      assert names(changed) == ["Ceremony", "Dinner", "Party", "Brunch"]
      assert List.last(changed.events).id == id
    end

    test "refuses an entity without an id, since two such rows would be indistinguishable" do
      assert_raise ArgumentError, ~r/non-nil :id/, fn ->
        Snapshot.apply(snapshot(), {:put, :events, %Event{name: "No id"}})
      end
    end
  end

  describe "{:delete, collection, id}" do
    test "removes the element with that id" do
      assert names(Snapshot.apply(snapshot(), {:delete, :events, 2})) == ["Ceremony", "Party"]
    end

    test "raises when there is no such row, rather than silently doing nothing" do
      assert_raise ArgumentError, ~r/no such row/, fn ->
        Snapshot.apply(snapshot(), {:delete, :events, 99})
      end
    end
  end

  describe "a list of changes" do
    test "applies each change to the result of the previous one, in order" do
      id = make_ref()

      changed =
        Snapshot.apply(snapshot(), [
          {:put, :events, %Event{id: id, name: "Brunch"}},
          {:put, :events, %Event{id: id, name: "Late brunch"}},
          {:delete, :events, 1}
        ])

      assert names(changed) == ["Dinner", "Party", "Late brunch"]
    end

    test "an empty list is the unchanged snapshot" do
      assert Snapshot.apply(snapshot(), []) == snapshot()
    end
  end

  test "every entity collection accepts changes, including ones whose schema is future work" do
    person = %{__struct__: FuturePerson, id: make_ref()}
    changed = Snapshot.apply(%Snapshot{}, {:put, :persons, person})

    assert changed.persons == [person]
  end

  test "refuses a collection that is not in the snapshot" do
    assert_raise ArgumentError, ~r/not a snapshot collection/, fn ->
      Snapshot.apply(snapshot(), {:put, :settings, %Event{id: 1}})
    end
  end

  test "refuses anything that is not a change" do
    assert_raise ArgumentError, ~r/not a snapshot change/, fn ->
      Snapshot.apply(snapshot(), {:rename, :events, 1})
    end
  end
end
