defmodule WeddingPlannerWeb.Export.HeadcountTest do
  @moduledoc """
  `WeddingPlannerWeb.Export.Headcount.table/2` over in-memory snapshots (`XC-30`,
  `XC-32`, `HC-03`, `HC-08`, `HC-09`, `DR-89`). No database; `load/0` is covered in
  `WeddingPlannerWeb.Export.ComputedLoadTest`.

  Oracles are independent of the engine: the normative shared Dinner counts
  (`NormativeExamples.shared_headcount/0`) and counts derived in the test from how the
  snapshot is built.
  """
  use ExUnit.Case, async: true

  import WeddingPlannerWeb.ComputedExportAssertions

  alias WeddingPlanner.BudgetSnapshots
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Export.Headcount

  @today ~D[2026-09-25]

  defp table(snapshot), do: snapshot |> Headcount.table(@today) |> assert_table_shape()

  defp counts(table, event, preset) do
    [row] = Enum.filter(table.rows, &match?([^event, ^preset | _], &1))
    [_event, _preset, adults, children, total] = row
    %{adults: adults, children: children, total: total}
  end

  test "stem and header row (no Currency column: no money)" do
    %{snapshot: snapshot} = BudgetSnapshots.b1()
    table = table(snapshot)

    assert table.stem == "headcount"
    assert table.headers == ["Event", "Preset", "Adults", "Children", "Total"]
  end

  test "the shared Dinner guests: Likely 72 + 6, Minimum 60 + 4, Maximum equal to Likely" do
    %{snapshot: snapshot} = BudgetSnapshots.branches()
    table = table(snapshot)
    %{"Dinner" => %{"Likely" => likely, "Minimum" => minimum}} = NE.shared_headcount()

    assert counts(table, "Dinner", "Likely") == likely
    assert counts(table, "Dinner", "Minimum") == minimum
    # The fixture's documented property (every shared guest is certain or likely).
    assert counts(table, "Dinner", "Maximum") == likely

    # One event: "All events" is the same set of persons.
    assert counts(table, "All events", "Likely") == likely
    assert counts(table, "All events", "Minimum") == minimum

    # Events in EVT-04 order then "All events"; presets in stored order within each.
    assert Enum.map(table.rows, &Enum.take(&1, 2)) == [
             ["Dinner", "Minimum"],
             ["Dinner", "Likely"],
             ["Dinner", "Maximum"],
             ["All events", "Minimum"],
             ["All events", "Likely"],
             ["All events", "Maximum"]
           ]
  end

  # FP-93a
  test "a custom preset gets its own rows, in stored order (HC-09)" do
    %{snapshot: snapshot} = BudgetSnapshots.b1()

    custom = %Preset{
      id: 99,
      name: "Children only",
      invitation_statuses: MapSet.new([:planned, :invited, :accepted]),
      age_categories: MapSet.new([:child])
    }

    table = table(%{snapshot | headcount_presets: snapshot.headcount_presets ++ [custom]})

    # The shared guests hold 4 certain + 2 likely children, all invited to Dinner.
    assert counts(table, "Dinner", "Children only") == %{adults: 0, children: 6, total: 6}
    assert counts(table, "All events", "Children only") == %{adults: 0, children: 6, total: 6}

    assert Enum.map(rows_where(table, "Event", "Dinner"), &Enum.at(&1, 1)) ==
             ["Minimum", "Likely", "Maximum", "Children only"]
  end

  # FP-93b
  test "a person counted for two events contributes 1 to All events (HC-03)" do
    %{snapshot: snapshot} = BudgetSnapshots.b1()
    reception = %Event{couple_attends: false, id: 2, name: "Reception", sort_order: 1}
    [first | _] = snapshot.persons

    only_reception = %Person{
      id: 1500,
      first_name: "Reception",
      last_name: "Only",
      certainty: :certain,
      age_category: :child,
      want_tier: :yes
    }

    snapshot = %{
      snapshot
      | events: snapshot.events ++ [reception],
        persons: snapshot.persons ++ [only_reception],
        invitations:
          snapshot.invitations ++
            [
              %Invitation{id: 3001, person_id: first.id, event_id: 2, status: :invited},
              %Invitation{id: 3002, person_id: only_reception.id, event_id: 2, status: :invited}
            ]
    }

    table = table(snapshot)
    %{"Dinner" => %{"Likely" => likely}} = NE.shared_headcount()

    # `first` is a certain adult already counted for Dinner; the new child only for Reception.
    assert first.age_category == :adult and first.certainty == :certain
    assert counts(table, "Reception", "Likely") == %{adults: 1, children: 1, total: 2}

    assert counts(table, "All events", "Likely") == %{
             adults: likely.adults,
             children: likely.children + 1,
             total: likely.total + 1
           }

    assert Enum.map(table.rows, &hd/1) |> Enum.dedup() == ["Dinner", "Reception", "All events"]
  end

  test "no events: only the All events rows, each zero" do
    table = table(%Snapshot{headcount_presets: Preset.defaults()})

    assert table.rows == [
             ["All events", "Minimum", 0, 0, 0],
             ["All events", "Likely", 0, 0, 0],
             ["All events", "Maximum", 0, 0, 0]
           ]
  end

  test "no presets: a header-only table" do
    %{snapshot: snapshot} = BudgetSnapshots.b1()
    table = table(%{snapshot | headcount_presets: []})

    assert table.rows == []
    assert table.headers == ["Event", "Preset", "Adults", "Children", "Total"]
  end
end
