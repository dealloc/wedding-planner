defmodule WeddingPlannerWeb.HeadcountOverviewTest do
  @moduledoc """
  `WeddingPlannerWeb.HeadcountOverview.build/2` (`docs/modules/headcount.md` `HC-03`,
  `HC-08`, `HC-09`; `DR-55`) over in-memory snapshots — no database (`NFR-41`).
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.HeadcountOverview

  @dinner %Event{couple_attends: false, id: 1, name: "Dinner", sort_order: 0}

  # -- helpers -------------------------------------------------------------------------------

  defp person(id, attrs \\ []), do: struct!(%Person{id: id}, attrs)

  defp plus_one(id, host_id, plus_one_status, attrs) do
    person(id, [host_id: host_id, plus_one_status: plus_one_status] ++ attrs)
  end

  defp invitation(id, person_id, event_id, status) do
    %Invitation{id: id, person_id: person_id, event_id: event_id, status: status}
  end

  # HC-06's three stored defaults, with ids the way the database would give them (DR-53:
  # identity is the role, not the name, but for this builder only id/name/criteria matter).
  defp stored_defaults do
    Preset.defaults() |> Enum.with_index(1) |> Enum.map(fn {p, id} -> %{p | id: id} end)
  end

  defp minimum, do: Enum.find(stored_defaults(), &(&1.name == "Minimum"))
  defp likely, do: Enum.find(stored_defaults(), &(&1.name == "Likely"))
  defp maximum, do: Enum.find(stored_defaults(), &(&1.name == "Maximum"))

  defp cell(overview, row_id, col_id) do
    overview.rows |> Enum.find(&(&1.id == row_id)) |> Map.fetch!(:cells) |> Map.fetch!(col_id)
  end

  # H1 (docs/07-normative-examples.md): 4 accepted (certain/likely/uncertain adult +
  # uncertain child), 3 invited+certain (adults), 2 invited+likely (adult + child), 1
  # planned+uncertain (child). Minimum 6+1=7, Likely 7+2=9, Maximum 7+3=10.
  defp h1_snapshot do
    rows = [
      {1, :accepted, :certain, :adult},
      {2, :accepted, :likely, :adult},
      {3, :accepted, :uncertain, :adult},
      {4, :accepted, :uncertain, :child},
      {5, :invited, :certain, :adult},
      {6, :invited, :certain, :adult},
      {7, :invited, :certain, :adult},
      {8, :invited, :likely, :adult},
      {9, :invited, :likely, :child},
      {10, :planned, :uncertain, :child}
    ]

    %Snapshot{
      events: [@dinner],
      persons:
        for(
          {id, _, c, age} <- rows,
          do: person(id, first_name: "H1-#{id}", certainty: c, age_category: age)
        ),
      invitations:
        for({id, status, _, _} <- rows, do: invitation(100 + id, id, @dinner.id, status)),
      headcount_presets: stored_defaults()
    }
  end

  # -- columns -------------------------------------------------------------------------------

  describe "columns" do
    test "one column per stored preset, in the snapshot's order, ids from the preset id" do
      overview = HeadcountOverview.build(h1_snapshot(), nil)

      assert overview.columns == [
               %{id: "1", label: "Minimum"},
               %{id: "2", label: "Likely"},
               %{id: "3", label: "Maximum"}
             ]
    end

    test "an ad hoc preset (HC-07) appends one more column, id 'adhoc'" do
      adhoc = %Preset{id: nil, name: "Ad hoc filter", want_tiers: MapSet.new([:maybe])}
      overview = HeadcountOverview.build(h1_snapshot(), adhoc)

      assert overview.columns == [
               %{id: "1", label: "Minimum"},
               %{id: "2", label: "Likely"},
               %{id: "3", label: "Maximum"},
               %{id: "adhoc", label: "Ad hoc filter"}
             ]
    end

    test "no stored presets and no ad hoc filter -> no columns at all" do
      snapshot = %Snapshot{events: [@dinner], headcount_presets: []}
      assert HeadcountOverview.build(snapshot, nil).columns == []
    end
  end

  # -- rows ----------------------------------------------------------------------------------

  describe "rows" do
    test "one row per event (EVT-04 order, as the snapshot already carries it) plus 'All events'" do
      overview = HeadcountOverview.build(h1_snapshot(), nil)

      assert Enum.map(overview.rows, &{&1.id, &1.label, &1.target}) == [
               {"1", "Dinner", @dinner},
               {"all", "All events", :all_events}
             ]
    end
  end

  # -- cells: H1 (required test) --------------------------------------------------------------

  describe "H1 cells under the stored Minimum/Likely/Maximum presets" do
    test "totals are 7 / 9 / 10, matching Headcount.evaluate/3 exactly (never hard-coded)" do
      snapshot = h1_snapshot()
      overview = HeadcountOverview.build(snapshot, nil)

      for {col_id, preset} <- [{"1", minimum()}, {"2", likely()}, {"3", maximum()}] do
        expected = Headcount.evaluate(snapshot, preset, @dinner)

        assert cell(overview, "1", col_id).total_text ==
                 "#{expected.adults} + #{expected.children} = #{expected.total}"
      end

      assert cell(overview, "1", "1").total_text == "6 + 1 = 7"
      assert cell(overview, "1", "2").total_text == "7 + 2 = 9"
      assert cell(overview, "1", "3").total_text == "7 + 3 = 10"
    end

    test "the Likely cell's formula names the preset and has the accepted/invited steps" do
      overview = HeadcountOverview.build(h1_snapshot(), nil)
      formula = cell(overview, "1", "2").formula

      assert %{label: "Headcount preset", value: "Likely"} = hd(formula.steps)
      assert Enum.any?(formula.steps, &String.starts_with?(&1.label, "Accepted"))
      assert Enum.any?(formula.steps, &String.starts_with?(&1.label, "Invited"))
      refute Enum.any?(formula.steps, &String.starts_with?(&1.label, "Planned"))
      assert formula.total == "9"
    end

    test "the Likely cell's names contain the counted persons but not the planned uncertain one" do
      overview = HeadcountOverview.build(h1_snapshot(), nil)
      names = cell(overview, "1", "2").names

      # Person 10 (planned, uncertain) is not counted under Likely (certain/likely only).
      refute "H1-10" in names
      assert length(names) == 9
      assert Enum.all?(names, &(&1 != ""))
    end

    test "the Maximum cell's names include everyone, 10 entries, adults before children" do
      snapshot = h1_snapshot()
      overview = HeadcountOverview.build(snapshot, nil)
      names = cell(overview, "1", "3").names

      assert length(names) == 10

      # snapshot.persons order: 7 adults (1,2,3,5,6,7,8) then 3 children (4,9,10) — the
      # builder must list every adult before every child, in that relative order.
      adults =
        snapshot.persons
        |> Enum.filter(&(&1.age_category == :adult))
        |> Enum.map(&Person.display_name/1)

      children =
        snapshot.persons
        |> Enum.filter(&(&1.age_category == :child))
        |> Enum.map(&Person.display_name/1)

      assert names == adults ++ children
    end
  end

  # -- All events (required test) -------------------------------------------------------------

  describe "the All events row (HC-03)" do
    test "a person counted for two events is counted once" do
      ceremony = %Event{couple_attends: false, id: 1, name: "Ceremony", sort_order: 0}
      dinner = %Event{couple_attends: false, id: 2, name: "Dinner", sort_order: 1}

      snapshot = %Snapshot{
        events: [ceremony, dinner],
        persons: [person(1), person(2, age_category: :child), person(3)],
        invitations: [
          invitation(11, 1, ceremony.id, :invited),
          invitation(12, 1, dinner.id, :accepted),
          invitation(22, 2, dinner.id, :planned),
          invitation(31, 3, ceremony.id, :declined)
        ],
        headcount_presets: stored_defaults()
      }

      overview = HeadcountOverview.build(snapshot, nil)

      # Person 1: counted for both (2), person 2: Dinner only (1) -> distinct = 2, not 3.
      assert cell(overview, "all", "3").total_text == "1 + 1 = 2"

      expected = Headcount.evaluate(snapshot, maximum(), :all_events)

      assert cell(overview, "all", "3").total_text ==
               "#{expected.adults} + #{expected.children} = #{expected.total}"
    end
  end

  # -- +1 display name (PER-11) -----------------------------------------------------------

  describe "an unnamed +1's display name (PER-11)" do
    test "renders as '+1 of <host>', host resolved from the snapshot (no preloaded :host)" do
      host = person(1, first_name: "Anna", last_name: "Peeters", certainty: :certain)
      guest = plus_one(2, 1, :confirmed, age_category: :adult)

      snapshot = %Snapshot{
        events: [@dinner],
        persons: [host, guest],
        invitations: [invitation(10, 1, @dinner.id, :accepted)],
        headcount_presets: stored_defaults()
      }

      overview = HeadcountOverview.build(snapshot, nil)
      names = cell(overview, "1", "1").names

      assert "+1 of Anna Peeters" in names
    end
  end

  # -- ad hoc filter equals Headcount.evaluate/3 (required test) -----------------------------

  describe "the ad hoc column" do
    test "matches Headcount.evaluate/3 for the same Preset" do
      snapshot = h1_snapshot()
      adhoc = %Preset{id: nil, name: "Ad hoc filter", certainties: MapSet.new([:uncertain])}
      overview = HeadcountOverview.build(snapshot, adhoc)

      expected = Headcount.evaluate(snapshot, adhoc, @dinner)

      assert cell(overview, "1", "adhoc").total_text ==
               "#{expected.adults} + #{expected.children} = #{expected.total}"
    end
  end
end
