defmodule WeddingPlanner.Invitations.MatrixTest do
  @moduledoc """
  `WeddingPlanner.Invitations.Matrix` (task 45; `INVT-02`, `INVT-04`, `PER-04`, `DR-34`,
  `DR-39`) — pure, no database. Uses real `WeddingPlanner.Guests.Person` structs (built
  in-memory, never persisted) because `Matrix` calls
  `WeddingPlanner.Guests.Person.plus_one?/1`, `WeddingPlanner.Guests.PlusOne.want_tier/2`
  and `WeddingPlanner.Guests.Person.display_name/1`, all of which pattern-match on the
  real struct — unlike `WeddingPlanner.Invitations.EffectiveTest`, which can get away
  with bare maps.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Guests.Group
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Effective
  alias WeddingPlanner.Invitations.Matrix

  @dinner 100
  @reception 101

  defp person(id, attrs \\ %{}) do
    struct(%Person{id: id, first_name: "Person#{id}", last_name: "Test"}, attrs)
  end

  defp plus_one(id, host, attrs \\ %{}) do
    struct(
      %Person{
        id: id,
        first_name: "Plus#{id}",
        last_name: "One",
        host_id: host.id,
        host: host,
        want_tier: host.want_tier,
        group_id: nil
      },
      attrs
    )
  end

  defp group(id, name), do: %Group{id: id, name: name}

  defp event(id, name), do: %{id: id, name: name, date: nil}

  defp lookup(persons, invitations \\ [], opt_outs \\ []),
    do: Effective.index(persons, invitations, opt_outs)

  # -- host_units/1 (DR-34: explicit walk, never Enum.group_by/2) -------------------------

  describe "host_units/1" do
    test "keeps every +1 directly under its own host, in encounter order" do
      # Deliberately non-sequential, non-sorted ids: a `Map`-keyed intermediate step
      # (what `Enum.group_by/2` followed by `Map.values/1` would produce) is not
      # guaranteed to come back out in this relative order — only an explicit walk is.
      a = person(30)
      a1 = plus_one(31, a)
      b = person(10)
      c = person(20)
      c1 = plus_one(21, c)

      assert Matrix.host_units([a, a1, b, c, c1]) == [
               {a, [a1]},
               {b, []},
               {c, [c1]}
             ]
    end

    test "a host with two +1s keeps both, in the order they appeared" do
      host = person(1)
      first = plus_one(2, host)
      second = plus_one(3, host)

      assert Matrix.host_units([host, first, second]) == [{host, [first, second]}]
    end

    test "raises if a +1 appears before any host" do
      orphan = plus_one(2, person(1))

      assert_raise ArgumentError, ~r/immediately follow its own host/, fn ->
        Matrix.host_units([orphan])
      end
    end
  end

  # -- filtering (DR-34's "any member matches every active filter") -----------------------

  describe "build/6 — text filter" do
    test "a unit is shown if the host's name matches, case-insensitively" do
      anna = person(1, %{first_name: "Anna", last_name: "Peeters"})
      ben = person(2, %{first_name: "Ben", last_name: "Aerts"})

      result =
        Matrix.build([anna, ben], [], [], lookup([anna, ben]), %{text: "anna"}, :flat)

      assert result.total == 2
      assert result.shown == 1
      assert [{:unit, ^anna, [], _cells}] = result.items
    end

    test "a unit is shown if only a +1's name matches (DR-34: any member matches)" do
      anna = person(1, %{first_name: "Anna", last_name: "Peeters"})
      plus_one = plus_one(2, anna, %{first_name: "Tomas", last_name: "Verlinden"})

      result =
        Matrix.build(
          [anna, plus_one],
          [],
          [],
          lookup([anna, plus_one]),
          %{text: "tomas"},
          :flat
        )

      assert result.shown == 1
      assert [{:unit, ^anna, [^plus_one], _cells}] = result.items
    end
  end

  describe "build/6 — want tier filter reads the effective (inherited) want tier" do
    test "a +1's own (stale) want_tier column is ignored — the host's is used (PER-15)" do
      host = person(1, %{want_tier: :maybe})
      # A +1's want_tier is never independently editable (PER-15); simulate a stale
      # column value to prove Matrix reads the effective one via PlusOne, not this field.
      plus_one = plus_one(2, host, %{want_tier: :yes})

      result =
        Matrix.build(
          [host, plus_one],
          [],
          [],
          lookup([host, plus_one]),
          %{want_tier: :maybe},
          :flat
        )

      assert result.shown == 1
    end
  end

  describe "build/6 — status-for-event filter (INVT-04 B-list)" do
    test "want tier maybe + not invited to the Reception narrows to the B-list" do
      maybe_not_invited = person(1, %{want_tier: :maybe})
      maybe_but_invited = person(2, %{want_tier: :maybe})
      yes_not_invited = person(3, %{want_tier: :yes})

      persons = [maybe_not_invited, maybe_but_invited, yes_not_invited]
      invitations = [%{person_id: 2, event_id: @reception, status: :invited}]

      result =
        Matrix.build(
          persons,
          [],
          [],
          lookup(persons, invitations),
          %{want_tier: :maybe, event_id: @reception, status: :not_invited},
          :flat
        )

      assert result.shown == 1
      assert [{:unit, ^maybe_not_invited, [], _cells}] = result.items
    end

    test "a lone status pick with no event chosen filters nothing" do
      anna = person(1)

      result =
        Matrix.build([anna], [], [], lookup([anna]), %{status: :not_invited}, :flat)

      assert result.shown == 1
    end

    test "not invited matches a person with no invitation row at all" do
      anna = person(1)

      result =
        Matrix.build(
          [anna],
          [],
          [],
          lookup([anna]),
          %{event_id: @dinner, status: :not_invited},
          :flat
        )

      assert result.shown == 1
    end
  end

  # -- grouping (DR-39) --------------------------------------------------------------------

  describe "build/6 — grouped view" do
    test "groups render in list order, always (even with zero shown members), then Ungrouped" do
      peeters = group(1, "Family Peeters")
      friends = group(2, "Friends")

      anna = person(1, %{group_id: peeters.id})
      unassigned = person(2, %{group_id: nil})

      persons = [anna, unassigned]

      result =
        Matrix.build(persons, [peeters, friends], [], lookup(persons), %{}, :grouped)

      assert result.items == [
               {:group_header, peeters, 1},
               {:unit, anna, [], %{1 => %{}}},
               {:group_header, friends, 0},
               {:group_header, :ungrouped, 1},
               {:unit, unassigned, [], %{2 => %{}}}
             ]
    end

    test "a +1 rides along inside its host's unit, never filtered into a group of its own" do
      peeters = group(1, "Family Peeters")
      host = person(1, %{group_id: peeters.id})
      plus_one = plus_one(2, host, %{group_id: nil})

      persons = [host, plus_one]

      result = Matrix.build(persons, [peeters], [], lookup(persons), %{}, :grouped)

      assert [
               {:group_header, ^peeters, 1},
               {:unit, ^host, [^plus_one], _cells},
               {:group_header, :ungrouped, 0}
             ] = result.items
    end

    test "flat view sorts units in the given persons order, no group headers at all" do
      peeters = group(1, "Family Peeters")
      anna = person(1, %{group_id: peeters.id})
      ben = person(2, %{group_id: nil})

      persons = [anna, ben]
      result = Matrix.build(persons, [peeters], [], lookup(persons), %{}, :flat)

      assert [{:unit, ^anna, [], _}, {:unit, ^ben, [], _}] = result.items
    end
  end

  # -- cells --------------------------------------------------------------------------------

  describe "build/6 — cells" do
    test "each cell carries the effective status and, for a +1, whether it opted out" do
      dinner = event(@dinner, "Dinner")
      reception = event(@reception, "Reception")
      host = person(1)
      plus_one = plus_one(2, host)
      persons = [host, plus_one]

      invitations = [%{person_id: 1, event_id: @dinner, status: :accepted}]
      opt_outs = [%{person_id: 2, event_id: @reception}]

      result =
        Matrix.build(
          persons,
          [],
          [dinner, reception],
          lookup(persons, invitations, opt_outs),
          %{},
          :flat
        )

      assert [{:unit, ^host, [^plus_one], cells}] = result.items

      assert cells[1][@dinner] == %{status: :accepted, opted_out: false}
      assert cells[1][@reception] == %{status: :not_invited, opted_out: false}
      # PER-13: no opt-out, +1 follows the host's own status at Dinner.
      assert cells[2][@dinner] == %{status: :accepted, opted_out: false}
      # The +1 opted out of Reception, but the host was never invited there either
      # (PER-14: "not invited" propagates first) — opted_out is still recorded true even
      # though it makes no difference to the effective status.
      assert cells[2][@reception] == %{status: :not_invited, opted_out: true}
    end

    test "a host cell's opted_out is always false (only a +1 can opt out, PER-13)" do
      host = person(1)

      result =
        Matrix.build([host], [], [event(@dinner, "Dinner")], lookup([host]), %{}, :flat)

      assert [{:unit, ^host, [], cells}] = result.items
      assert cells[1][@dinner] == %{status: :not_invited, opted_out: false}
    end
  end

  # -- item_for_unit/4 (the LiveView's single-unit re-render path) ------------------------

  describe "item_for_unit/4" do
    test "matches what build/6 would have produced for the same unit" do
      host = person(1)
      plus_one = plus_one(2, host)
      persons = [host, plus_one]
      events = [event(@dinner, "Dinner")]
      matrix_lookup = lookup(persons)

      built = Matrix.build(persons, [], events, matrix_lookup, %{}, :flat)
      single = Matrix.item_for_unit(host, [plus_one], events, matrix_lookup)

      assert built.items == [single]
    end
  end

  # -- matching_units/3 (the group bulk action's own scoping) -----------------------------

  describe "matching_units/3" do
    test "returns exactly the host units build/6 would have shown, unbuilt" do
      anna = person(1, %{first_name: "Anna", last_name: "Peeters"})
      ben = person(2, %{first_name: "Ben", last_name: "Aerts"})
      persons = [anna, ben]

      units = Matrix.matching_units(persons, lookup(persons), %{text: "anna"})

      assert units == [{anna, []}]
    end
  end
end
