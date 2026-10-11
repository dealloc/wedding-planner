defmodule WeddingPlanner.Valuation.SeatingTest do
  @moduledoc """
  `WeddingPlanner.Valuation.Seating.analyse/3` (`docs/modules/seating.md` SEAT-02,
  SEAT-03, SEAT-10, SEAT-11, SEAT-22, SEAT-23, SEAT-32..SEAT-35, SEAT-51, SEAT-61,
  SEAT-62) over in-memory snapshots — no database (`NFR-41`).

  Normative examples are tagged `@tag example: "<id>"`. S3, S4 and S10 are covered in
  full; S5's and S9's unit and pull halves are covered here, their table halves land with
  the plan in a later slice.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Invitations.PlusOneOptOut
  alias WeddingPlanner.Seating.Circle
  alias WeddingPlanner.Seating.CircleMembership
  alias WeddingPlanner.Seating.Rule
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Seating
  alias WeddingPlanner.Valuation.Snapshot

  @dinner %Event{couple_attends: false, id: 1, name: "Dinner", sort_order: 0}

  # -- helpers ---------------------------------------------------------------------------

  defp person(id, attrs \\ []), do: struct!(%Person{id: id, first_name: "P#{id}"}, attrs)

  defp invited(persons),
    do:
      for(
        p <- persons,
        do: %Invitation{id: p.id, person_id: p.id, event_id: 1, status: :accepted}
      )

  defp circle(id, cohesion), do: %Circle{id: id, name: "C#{id}", cohesion: cohesion}

  defp memberships(circle_id, person_ids) do
    for id <- person_ids,
        do: %CircleMembership{id: {circle_id, id}, circle_id: circle_id, person_id: id}
  end

  defp rule(id, a, b, relation) do
    %Rule{id: id}
    |> Rule.changeset(%{subject: Rule.side_key(a), object: Rule.side_key(b), relation: relation})
    |> Ecto.Changeset.apply_action!(:insert)
  end

  defp snapshot(persons, extra \\ []) do
    struct!(%Snapshot{events: [@dinner], persons: persons, invitations: invited(persons)}, extra)
  end

  defp likely, do: Enum.find(Preset.defaults(), &(&1.role == :likely))

  defp analyse(snapshot, event \\ @dinner), do: Seating.analyse(snapshot, likely(), event)

  defp p(id), do: {:person, id}

  # -- who is seated (SEAT-02, SEAT-03) -------------------------------------------------

  describe "who is seated" do
    test "exactly the persons the preset counts for the event" do
      declined = person(3)
      snapshot = snapshot([person(1), person(2), declined])

      snapshot = %{
        snapshot
        | invitations:
            List.replace_at(snapshot.invitations, 2, %Invitation{
              id: 3,
              person_id: 3,
              event_id: 1,
              status: :declined
            })
      }

      assert analyse(snapshot).parties == [p(1), p(2)]
    end

    test "the couple is seated, as two seats, when the event's couple attends flag is set" do
      dinner = %Event{@dinner | couple_attends: true}
      analysis = analyse(%{snapshot([person(1)]) | events: [dinner]}, dinner)

      assert analysis.parties == [:couple, p(1)]
      assert Seating.seats(analysis) == 3
    end
  end

  # -- units (SEAT-10, SEAT-11) -----------------------------------------------------------

  describe "seating units" do
    @tag example: "S3"
    test "a +1 is in its host's unit; opted out, the host is a unit of one" do
      anna = person(1)
      tom = person(2, host_id: 1, plus_one_status: :confirmed)
      snapshot = snapshot([anna, tom]) |> Map.put(:invitations, invited([anna]))

      assert analyse(snapshot).units == [[p(1), p(2)]]

      opted_out = %{
        snapshot
        | plus_one_opt_outs: [%PlusOneOptOut{id: 1, person_id: 2, event_id: 1}]
      }

      assert analyse(opted_out).units == [[p(1)]]
    end

    test "always with joins units transitively" do
      snapshot =
        snapshot([person(1), person(2), person(3), person(4)],
          seating_rules: [rule(1, p(1), p(2), :always_with), rule(2, p(2), p(3), :always_with)]
        )

      assert analyse(snapshot).units == [[p(1), p(2), p(3)], [p(4)]]
    end

    @tag example: "S5"
    test "always with the couple puts that person in the couple's unit; without the couple it is inactive" do
      dinner = %Event{@dinner | couple_attends: true}

      snapshot =
        snapshot([person(1), person(2)], seating_rules: [rule(1, p(1), :couple, :always_with)])

      assert analyse(%{snapshot | events: [dinner]}, dinner).units == [[:couple, p(1)], [p(2)]]
      assert analyse(snapshot).units == [[p(1)], [p(2)]]
    end

    test "always with a circle joins every seated member" do
      snapshot =
        snapshot([person(1), person(2), person(3)],
          circles: [circle(1, :like_together)],
          circle_memberships: memberships(1, [2, 3]),
          seating_rules: [rule(1, p(1), {:circle, 1}, :always_with)]
        )

      assert analyse(snapshot).units == [[p(1), p(2), p(3)]]
    end
  end

  # -- blocking (SEAT-61) -----------------------------------------------------------------

  describe "blocking problems" do
    @tag example: "S4"
    test "never with inside one unit is blocking and names the chain A → B → C" do
      never = rule(3, p(1), p(3), :never_with)

      snapshot =
        snapshot([person(1), person(2), person(3)],
          seating_rules: [
            rule(1, p(1), p(2), :always_with),
            rule(2, p(2), p(3), :always_with),
            never
          ]
        )

      assert analyse(snapshot).blocking == [{:never_with_in_unit, never, [p(1), p(2), p(3)]}]
    end

    test "a +1 link counts in the chain" do
      never = rule(1, p(1), p(2), :never_with)

      snapshot =
        snapshot([person(1), person(2, host_id: 1, plus_one_status: :confirmed)],
          seating_rules: [never]
        )

      snapshot = %{snapshot | invitations: invited([person(1)])}

      assert analyse(snapshot).blocking == [{:never_with_in_unit, never, [p(1), p(2)]}]
    end

    test "never with across units is not a problem" do
      snapshot =
        snapshot([person(1), person(2)], seating_rules: [rule(1, p(1), p(2), :never_with)])

      assert analyse(snapshot).blocking == []
    end
  end

  # -- pulls and precedence (SEAT-22, SEAT-23, SEAT-33) --------------------------------

  describe "pulls" do
    test "a shared group gives the weakest pull; a +1 is in its host's group" do
      host = person(1, group_id: 7)

      snapshot =
        snapshot([
          host,
          person(2, group_id: 7),
          person(3, host_id: 1, plus_one_status: :confirmed)
        ])

      snapshot = %{snapshot | invitations: invited([host, person(2)])}
      analysis = analyse(snapshot)

      assert Seating.pull(analysis, p(1), p(2)) == 1
      assert Seating.pull(analysis, p(3), p(2)) == 1
    end

    test "shared circles add up and beat a shared group" do
      snapshot =
        snapshot([person(1, group_id: 7), person(2, group_id: 7)],
          circles: [circle(1, :keep_together), circle(2, :know_each_other)],
          circle_memberships: memberships(1, [1, 2]) ++ memberships(2, [1, 2])
        )

      assert Seating.pull(analyse(snapshot), p(2), p(1)) == 9
    end

    @tag example: "S9"
    test "a person ↔ person rule beats a keep together circle" do
      snapshot =
        snapshot([person(1), person(2), person(3)],
          circles: [circle(1, :keep_together)],
          circle_memberships: memberships(1, [1, 2, 3]),
          seating_rules: [rule(1, p(1), p(2), :keep_apart)]
        )

      analysis = analyse(snapshot)
      assert Seating.pull(analysis, p(1), p(2)) < 0
      assert Seating.pull(analysis, p(1), p(3)) > 0
      assert analysis.warnings == []
    end

    test "never with leaves no pull" do
      snapshot =
        snapshot([person(1), person(2)],
          circles: [circle(1, :keep_together)],
          circle_memberships: memberships(1, [1, 2]),
          seating_rules: [rule(1, p(1), p(2), :never_with)]
        )

      assert Seating.pull(analyse(snapshot), p(1), p(2)) == 0
    end
  end

  # -- warnings (SEAT-61) -----------------------------------------------------------------

  describe "warnings" do
    test "contradictory soft rules of the same specificity, once per pair of rules" do
      seat = rule(1, p(1), {:circle, 1}, :seat_with)
      apart = rule(2, p(1), {:circle, 2}, :keep_apart)

      snapshot =
        snapshot([person(1), person(2), person(3)],
          circles: [circle(1, :like_together), circle(2, :like_together)],
          circle_memberships: memberships(1, [2, 3]) ++ memberships(2, [2, 3]),
          seating_rules: [seat, apart]
        )

      assert analyse(snapshot).warnings == [{:contradiction, seat, apart}]
    end

    test "a more specific rule settles it: no contradiction" do
      snapshot =
        snapshot([person(1), person(2)],
          circles: [circle(1, :like_together)],
          circle_memberships: memberships(1, [2]),
          seating_rules: [
            rule(1, p(1), {:circle, 1}, :keep_apart),
            rule(2, p(1), p(2), :seat_with)
          ]
        )

      assert analyse(snapshot).warnings == []
    end

    test "a soft rule overruled by a hard one" do
      soft = rule(1, p(1), {:circle, 1}, :seat_with)
      hard = rule(2, p(1), p(2), :never_with)

      snapshot =
        snapshot([person(1), person(2)],
          circles: [circle(1, :like_together)],
          circle_memberships: memberships(1, [2]),
          seating_rules: [soft, hard]
        )

      assert analyse(snapshot).warnings == [{:overruled, soft, hard}]
    end
  end

  # -- loose ends (SEAT-35, SEAT-62) -----------------------------------------------------

  describe "loose ends" do
    @tag example: "S10"
    test "a unit with no pull is a loose end until marked fine anywhere" do
      snapshot =
        snapshot([person(1, group_id: 7), person(2, group_id: 7), person(3)])

      assert analyse(snapshot).loose_ends == [[p(3)]]

      fine = %{
        snapshot
        | persons: List.replace_at(snapshot.persons, 2, person(3, fine_anywhere: true))
      }

      assert analyse(fine).loose_ends == []
    end

    test "a pull inside one's own unit does not count" do
      snapshot =
        snapshot(
          [
            person(1, group_id: 7),
            person(2, group_id: 7),
            person(3, group_id: 8),
            person(4, group_id: 8)
          ],
          seating_rules: [rule(1, p(1), p(2), :always_with)]
        )

      assert analyse(snapshot).loose_ends == [[p(1), p(2)]]
    end

    test "a single unit is never a loose end" do
      assert analyse(snapshot([person(1)])).loose_ends == []
    end
  end

  @tag example: "S11"
  test "the same inputs always give the same analysis (SEAT-51)" do
    snapshot =
      snapshot(Enum.map(1..12, &person(&1, group_id: rem(&1, 3))),
        circles: [circle(1, :keep_together)],
        circle_memberships: memberships(1, [1, 4, 7]),
        seating_rules: [
          rule(1, p(1), p(2), :always_with),
          rule(2, p(3), {:circle, 1}, :keep_apart)
        ]
      )

    assert analyse(snapshot) == analyse(snapshot)
  end
end
