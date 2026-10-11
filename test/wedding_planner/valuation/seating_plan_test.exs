defmodule WeddingPlanner.Valuation.SeatingPlanTest do
  @moduledoc """
  `WeddingPlanner.Valuation.SeatingPlan` (`docs/modules/seating.md` SEAT-41, SEAT-51..
  SEAT-54, SEAT-61) over in-memory snapshots — no database (`NFR-41`). Normative examples
  are tagged `@tag example: "<id>"`; each asserts only what every correct plan shares, so
  the internal weights can change without breaking them.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Seating.Circle
  alias WeddingPlanner.Seating.CircleMembership
  alias WeddingPlanner.Seating.Pin
  alias WeddingPlanner.Seating.Rule
  alias WeddingPlanner.Seating.Table
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Seating
  alias WeddingPlanner.Valuation.SeatingPlan
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

  # `{min, max}` is one specific table guests may fill — a type limited to 1;
  # `{:type, min, max}` / `{:type, min, max, limit}` a type; `{:fixed, min, max}` a fixed
  # table, which seats only its pins (D-44).
  defp tables(specs) do
    for {spec, i} <- Enum.with_index(specs, 1) do
      base = %Table{id: i, event_id: 1, name: "T#{i}", sort_order: i}

      case spec do
        {:fixed, min, max} ->
          %{base | kind: :fixed, min_seats: min, max_seats: max}

        {:type, min, max} ->
          %{base | kind: :type, min_seats: min, max_seats: max}

        {:type, min, max, limit} ->
          %{base | kind: :type, min_seats: min, max_seats: max, limit: limit}

        {min, max} ->
          %{base | kind: :type, min_seats: min, max_seats: max, limit: 1}
      end
    end
  end

  defp plan(persons, table_specs, extra \\ [], event \\ @dinner) do
    snapshot =
      struct!(
        %Snapshot{events: [event], persons: persons, invitations: invited(persons)},
        extra
      )

    preset = Enum.find(Preset.defaults(), &(&1.role == :likely))
    analysis = Seating.analyse(snapshot, preset, event)
    {analysis, SeatingPlan.compute(analysis, tables(table_specs))}
  end

  defp p(id), do: {:person, id}

  # The parties at each table, as a set of sets — tables are interchangeable.
  defp groups(plan), do: plan.tables |> Enum.map(&MapSet.new(&1.parties)) |> MapSet.new()

  defp same_table?(plan, a, b), do: plan.table_of[a] == plan.table_of[b]

  # -- normative examples ---------------------------------------------------------------

  @tag example: "S1"
  test "two keep-together circles fill their own tables" do
    {_, plan} =
      plan(Enum.map(1..6, &person/1), [{:type, 3, 3}],
        circles: [circle(1, :keep_together), circle(2, :keep_together)],
        circle_memberships: memberships(1, [1, 2, 3]) ++ memberships(2, [4, 5, 6])
      )

    assert plan.status == :ok

    assert groups(plan) ==
             MapSet.new([MapSet.new([p(1), p(2), p(3)]), MapSet.new([p(4), p(5), p(6)])])
  end

  @tag example: "S2"
  test "never with is never broken" do
    {_, plan} =
      plan(Enum.map(1..6, &person/1), [{:type, 3, 3}],
        circles: [circle(1, :keep_together), circle(2, :keep_together)],
        circle_memberships: memberships(1, [1, 2, 3]) ++ memberships(2, [4, 5, 6]),
        seating_rules: [rule(1, p(1), p(3), :never_with)]
      )

    assert plan.status == :ok
    refute same_table?(plan, p(1), p(3))
  end

  @tag example: "S5"
  test "always with the couple seats that person at the couple's table" do
    dinner = %Event{@dinner | couple_attends: true}
    persons = Enum.map(1..5, &person(&1, group_id: 1))

    {_, plan} =
      plan(
        persons,
        [{3, 4}, {3, 4}],
        [seating_rules: [rule(1, p(1), :couple, :always_with)]],
        dinner
      )

    assert plan.status == :ok
    assert same_table?(plan, p(1), :couple)
  end

  @tag example: "S7"
  test "more people than seats: blocked, not computed" do
    {_, plan} = plan(Enum.map(1..11, &person/1), [{:type, 4, 5, 2}])

    assert plan.status == :blocked
    assert plan.problems == [{:too_many_seats, 11, 10}]
    assert plan.tables == []
  end

  @tag example: "S8"
  test "a table that can neither be empty nor reach its minimum: no valid plan" do
    {_, plan} = plan(Enum.map(1..3, &person/1), [{:type, 8, 10}])

    assert plan.status == :invalid
    assert [{:below_minimum, %{name: "T1 1"}, 3}] = plan.problems
  end

  @tag example: "S9"
  test "a person rule beats a keep-together circle" do
    {_, plan} =
      plan(Enum.map(1..4, &person/1), [{:type, 2, 3}],
        circles: [circle(1, :keep_together)],
        circle_memberships: memberships(1, [1, 2, 3, 4]),
        seating_rules: [rule(1, p(3), p(4), :keep_apart)]
      )

    assert plan.status == :ok
    refute same_table?(plan, p(3), p(4))
  end

  @tag example: "S11"
  test "the same inputs always give the same plan" do
    persons = Enum.map(1..40, &person(&1, group_id: rem(&1, 5)))
    specs = [{:type, 6, 10}]

    extra = [
      circles: [circle(1, :keep_together), circle(2, :like_together)],
      circle_memberships: memberships(1, Enum.to_list(1..12)) ++ memberships(2, [3, 9, 27, 33]),
      seating_rules: [rule(1, p(1), p(2), :never_with), rule(2, p(5), p(6), :always_with)]
    ]

    {_, first} = plan(persons, specs, extra)
    {_, second} = plan(persons, specs, extra)

    assert first == second
  end

  # -- behaviour -------------------------------------------------------------------------

  @tag example: "S16"
  test "a fixed table with nothing pinned stays empty, however many guests there are" do
    {_, plan} =
      plan(Enum.map(1..10, &person(&1, group_id: 1)), [{:fixed, 2, 12}, {:type, 4, 6}])

    assert plan.status == :ok
    assert [%{table: %{name: "T1"}, seats: 0} | rest] = plan.tables
    assert Enum.all?(rest, &(&1.seats in 4..6))
  end

  @tag example: "S17"
  test "a split circle leaves nobody as its only member at a table (SEAT-52)" do
    colleagues = Enum.map(1..6, &person/1)
    others = Enum.map(7..10, &person(&1, group_id: 1))

    {_, plan} =
      plan(colleagues ++ others, [{:type, 5, 5}],
        circles: [circle(1, :keep_together)],
        circle_memberships: memberships(1, Enum.to_list(1..6))
      )

    assert plan.status == :ok

    for %{parties: parties} <- plan.tables do
      here = Enum.count(parties, &(&1 in Enum.map(1..6, fn id -> p(id) end)))
      refute here == 1, "a colleague sits alone: #{inspect(parties)}"
    end
  end

  # -- pins (SEAT-24, SEAT-42, D-44) -----------------------------------------------------

  defp wedding_party,
    do: %Circle{id: 99, name: "Wedding party", cohesion: :keep_together, role: :wedding_party}

  defp pin(id, table_id, side), do: %{Pin.new(%Table{id: table_id}, side) | id: id}

  defp plan_with_pins(persons, table_specs, pins, extra \\ [], event \\ @dinner) do
    snapshot =
      struct!(%Snapshot{events: [event], persons: persons, invitations: invited(persons)}, extra)

    analysis =
      Seating.analyse(snapshot, Enum.find(Preset.defaults(), &(&1.role == :likely)), event)

    {analysis, SeatingPlan.compute(analysis, tables(table_specs), pins)}
  end

  @tag example: "S15"
  test "the wedding party pinned to the head table seats exactly the couple, the witnesses and their +1s" do
    dinner = %Event{@dinner | couple_attends: true}
    witness_a = person(1, witness_of_id: 1, group_id: 1)
    witness_b = person(2, witness_of_id: 2, group_id: 2)
    plus_one = person(3, host_id: 2, plus_one_status: :confirmed)
    guests = Enum.map(4..15, &person(&1, group_id: 3))
    persons = [witness_a, witness_b, plus_one | guests]

    {_, plan} =
      plan_with_pins(
        persons,
        [{:fixed, 2, 8}, {:type, 6, 8}],
        [pin(1, 1, {:circle, 99})],
        [circles: [wedding_party()], invitations: invited([witness_a, witness_b | guests])],
        dinner
      )

    assert plan.status == :ok
    [head | _] = plan.tables
    assert MapSet.new(head.parties) == MapSet.new([:couple, p(1), p(2), p(3)])
    assert head.seats == 5
    assert MapSet.member?(plan.pinned, :couple)
  end

  test "someone pinned to two tables is blocking" do
    {_, plan} =
      plan_with_pins([person(1), person(2)], [{:fixed, 1, 4}, {:fixed, 1, 4}], [
        pin(1, 1, p(1)),
        pin(2, 2, p(1))
      ])

    assert plan.status == :blocked

    assert [{:pinned_twice, [{:person, 1}], [%{id: 1}, %{id: 2}]}, {:no_table_types, 1}] =
             plan.problems
  end

  test "a fixed table pinned beyond its maximum or short of its minimum is blocking" do
    persons = Enum.map(1..3, &person/1)
    pins = for id <- 1..3, do: pin(id, 1, p(id))

    {_, over} = plan_with_pins(persons, [{:fixed, 1, 2}], pins)
    assert [{:pinned_above_maximum, %{id: 1}, 3}] = over.problems

    {_, under} = plan_with_pins(persons, [{:fixed, 4, 6}], pins)
    assert [{:pinned_below_minimum, %{id: 1}, 3}] = under.problems
  end

  test "a pin for someone not seated is inactive (SEAT-43)" do
    {analysis, plan} =
      plan_with_pins([person(1)], [{:fixed, 1, 4}], [pin(1, 1, p(1)), pin(2, 1, p(42))])

    assert plan.status == :ok
    assert [%{id: 2}] = SeatingPlan.inactive_pins(analysis, [pin(1, 1, p(1)), pin(2, 1, p(42))])
  end

  test "units stay whole and the couple takes two seats" do
    dinner = %Event{@dinner | couple_attends: true}
    host = person(1, group_id: 1)
    plus_one = person(2, host_id: 1, plus_one_status: :confirmed)
    others = Enum.map(3..6, &person(&1, group_id: 1))
    snapshot_persons = [host, plus_one | others]

    {_, plan} = plan(snapshot_persons, [{4, 4}, {4, 4}], [], dinner)
    plan = %{plan | tables: plan.tables}

    assert plan.status == :ok
    assert same_table?(plan, p(1), p(2))
    assert Enum.map(plan.tables, & &1.seats) == [4, 4]
  end

  test "a unit larger than the largest table is blocking" do
    persons = Enum.map(1..3, &person/1)
    rules = [rule(1, p(1), p(2), :always_with), rule(2, p(2), p(3), :always_with)]

    {_, plan} = plan(persons, [{1, 2}, {1, 2}], seating_rules: rules)

    assert plan.status == :blocked
    assert [{:unit_too_large, [{:person, 1}, {:person, 2}, {:person, 3}], 3, 2}] = plan.problems
  end

  test "a blocking analysis is not computed" do
    persons = Enum.map(1..2, &person/1)
    rules = [rule(1, p(1), p(2), :always_with), rule(2, p(1), p(2), :never_with)]

    # Only one rule per pair exists in practice; two here exercise the blocking path.
    {_, plan} = plan(persons, [{1, 4}], seating_rules: rules)

    assert plan.status == :blocked
    assert [{:blocking, {:never_with_in_unit, _, _}}] = plan.problems
  end

  test "no tables: blocked with nothing to place at" do
    {_, plan} = plan([person(1)], [])
    assert %{status: :blocked, problems: [:no_tables], tables: []} = plan
  end

  # -- how many tables (SEAT-45) ---------------------------------------------------------

  @tag example: "S12"
  test "the plan uses as few tables of a type as hold everyone" do
    {_, plan} = plan(Enum.map(1..44, &person(&1, group_id: rem(&1, 6))), [{:type, 8, 10}])

    assert plan.status == :ok
    assert Enum.map(plan.tables, & &1.table.name) == ["T1 1", "T1 2", "T1 3", "T1 4", "T1 5"]
    assert Enum.all?(plan.tables, &(&1.seats in 8..10))
  end

  @tag example: "S13"
  test "a limited type is used up to its limit, another type makes up the rest" do
    persons = Enum.map(1..30, &person(&1, group_id: rem(&1, 4)))
    {_, plan} = plan(persons, [{:type, 10, 12, 2}, {:type, 6, 8}])

    assert plan.status == :ok
    assert Enum.map(plan.tables, & &1.table.name) == ["T1 1", "T1 2", "T2 1"]
  end

  test "fixed tables are always listed first; types hold everyone not pinned" do
    head = %Table{id: 9, kind: :fixed, name: "Head", min_seats: 2, max_seats: 4}
    tables = [head | tables([{:type, 4, 4}])]

    assert [%{name: "Head"}, %{name: "T1 1"}, %{name: "T1 2"}, %{name: "T1 3"}] =
             SeatingPlan.plan_tables(tables, 12)

    assert [%{name: "Head"}] = SeatingPlan.plan_tables(tables, 0)
  end

  test "numbering skips names a fixed table already has (SEAT-40)" do
    frozen = %Table{id: 9, kind: :fixed, name: "t1 1", min_seats: 2, max_seats: 4}
    tables = [frozen | tables([{:type, 4, 4}])]

    plan_tables = SeatingPlan.plan_tables(tables, 8)

    assert Enum.map(plan_tables, & &1.name) == ["t1 1", "T1 2", "T1 3"]
    assert plan_tables |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 3
  end

  @tag example: "S14"
  test "one more table when the fewest give no valid plan (SEAT-45)" do
    persons = Enum.map(1..6, &person(&1, group_id: 1))
    {_, plan} = plan(persons, [{:type, 1, 6}], seating_rules: [rule(1, p(1), p(2), :never_with)])

    assert plan.status == :ok
    assert length(plan.tables) == 2
    refute same_table?(plan, p(1), p(2))
  end

  test "many table types stay fast (SEAT-45)" do
    types = for i <- 1..12, do: {:type, 2 + rem(i, 5), 6 + rem(i, 7)}
    {micros, counts} = :timer.tc(fn -> SeatingPlan.plan_tables(tables(types), 150) end)

    assert counts != []
    assert micros < 2_000_000, "took #{div(micros, 1000)} ms"
  end

  test "available seats are unlimited while any type has no limit (SEAT-61)" do
    assert SeatingPlan.available_seats(tables([{:type, 8, 10}, {:fixed, 2, 4}])) == :unlimited
    assert SeatingPlan.available_seats(tables([{:type, 8, 10, 3}, {:fixed, 2, 4}])) == 34
  end

  test "strangers are avoided: someone who knows nobody is not left with a closed group" do
    # 1..3 know each other, 4..6 know each other; 7 knows 4. Tables of 3–4.
    {_, plan} =
      plan(Enum.map(1..7, &person/1), [{3, 4}, {3, 4}],
        circles: [circle(1, :keep_together), circle(2, :keep_together)],
        circle_memberships: memberships(1, [1, 2, 3]) ++ memberships(2, [4, 5, 6, 7])
      )

    assert plan.status == :ok
    assert same_table?(plan, p(7), p(4))
  end

  test "explain names who pulls a person there and the soft rules this plan breaks (SEAT-54)" do
    {analysis, plan} =
      plan(Enum.map(1..4, &person/1), [{2, 2}, {2, 2}],
        circles: [circle(1, :keep_together), circle(2, :keep_together)],
        circle_memberships: memberships(1, [1, 2]) ++ memberships(2, [3, 4]),
        seating_rules: [rule(1, p(1), p(3), :seat_with)]
      )

    explain = SeatingPlan.explain(analysis, plan)

    assert plan.status == :ok
    assert same_table?(plan, p(1), p(2))
    assert explain[p(1)].pulled_by == [p(2)]
    assert [%Rule{id: 1}] = explain[p(1)].broken
    assert explain[p(2)].broken == []
  end

  @tag timeout: 120_000
  test "150 guests at tables of 8–12 finish in reasonable time (SEAT-50, NFR-33)" do
    persons = Enum.map(1..150, &person(&1, group_id: div(&1, 12)))
    circles = for c <- 1..10, do: circle(c, Enum.at([:keep_together, :like_together], rem(c, 2)))
    memberships = for c <- 1..10, m <- memberships(c, Enum.to_list((c * 13)..(c * 13 + 9))), do: m

    {micros, {_, plan}} =
      :timer.tc(fn ->
        plan(persons, [{:type, 8, 12}],
          circles: circles,
          circle_memberships: memberships
        )
      end)

    assert plan.status == :ok
    # Generous bound: the view computes asynchronously (SEAT-50), but it must stay usable.
    assert micros < 20_000_000, "took #{div(micros, 1000)} ms"
  end

  # -- SEAT-72: comparing two scenarios (S19) ----------------------------------------------

  # A hand-made plan: `tables` is `[{table_id, kind, [person ids]}]`, every person a unit.
  defp fake_plan(tables, status \\ :ok) do
    parties = for {_, _, ids} <- tables, id <- ids, do: p(id)

    {%{unit_index: Map.new(parties, &{&1, elem(&1, 1)})},
     %{
       status: status,
       problems: [],
       pinned: MapSet.new(),
       table_of: for({id, _, ids} <- tables, n <- ids, into: %{}, do: {p(n), id}),
       tables:
         for {id, kind, ids} <- tables do
           source = %Table{id: id, kind: kind, name: id}
           %{table: %{id: id, name: id, source: source}, parties: Enum.map(ids, &p/1)}
         end
     }}
  end

  defp moved(diff), do: Enum.map(diff, &Enum.map(&1.parties, fn {:person, id} -> id end))

  describe "compare/2 (SEAT-72, S19)" do
    @tag example: "S19"
    test "identical plans have no difference" do
      one = fake_plan([{"type-1-1", :type, [1, 2]}, {"type-1-2", :type, [3, 4]}])
      assert SeatingPlan.compare(one, one) == {:ok, []}
    end

    @tag example: "S19"
    test "the same groups under other table numbers are no difference" do
      a = fake_plan([{"type-1-1", :type, [1, 2]}, {"type-1-2", :type, [3, 4]}])
      b = fake_plan([{"type-1-1", :type, [3, 4]}, {"type-1-2", :type, [1, 2]}])
      assert SeatingPlan.compare(a, b) == {:ok, []}
    end

    @tag example: "S19"
    test "a unit that moves to the other group is listed with both tables" do
      a = fake_plan([{"type-1-1", :type, [1, 2, 3]}, {"type-1-2", :type, [4, 5, 6]}])
      b = fake_plan([{"type-1-1", :type, [4, 5, 3]}, {"type-1-2", :type, [1, 2, 6]}])

      assert {:ok, diff} = SeatingPlan.compare(a, b)
      assert moved(diff) == [[3], [6]]
      assert [%{a: %{id: "type-1-1"}, b: %{id: "type-1-1"}} | _] = diff
    end

    @tag example: "S19"
    test "a unit seated in only one scenario is listed with no table in the other" do
      a = fake_plan([{"type-1-1", :type, [1, 2]}, {"type-1-2", :type, [3, 4]}])
      b = fake_plan([{"type-1-1", :type, [1, 2]}, {"type-1-2", :type, [3]}])
      assert {:ok, [%{parties: [{:person, 4}], a: %{id: "type-1-2"}, b: nil}]} = compare_ab(a, b)

      assert {:ok, [%{parties: [{:person, 4}], a: nil, b: %{id: "type-1-2"}}]} =
               compare_ab(b, a)
    end

    @tag example: "S19"
    test "a fixed table matches itself, not a type table with the same people" do
      a = fake_plan([{"fixed-1", :fixed, [1, 2]}, {"type-1-1", :type, [3, 4]}])
      b = fake_plan([{"fixed-1", :fixed, [1]}, {"type-1-1", :type, [2, 3, 4]}])
      assert {:ok, diff} = SeatingPlan.compare(a, b)
      assert moved(diff) == [[2]]
    end

    @tag example: "S19"
    test "ties in overlap are broken by table order, so the result is deterministic" do
      a = fake_plan([{"type-1-1", :type, [1, 2]}, {"type-1-2", :type, [3, 4]}])
      b = fake_plan([{"type-1-1", :type, [1, 3]}, {"type-1-2", :type, [2, 4]}])
      assert compare_ab(a, b) == compare_ab(a, b)
      assert {:ok, diff} = compare_ab(a, b)
      assert moved(diff) == [[2], [3]]
    end

    @tag example: "S19"
    test "a blocked or invalid plan is named, never diffed" do
      ok = fake_plan([{"type-1-1", :type, [1]}])
      blocked = fake_plan([], :blocked)
      invalid = fake_plan([{"type-1-1", :type, [1]}], :invalid)

      assert SeatingPlan.compare(ok, blocked) == {:error, [b: :blocked]}
      assert SeatingPlan.compare(invalid, blocked) == {:error, [a: :invalid, b: :blocked]}
    end

    @tag example: "S19"
    test "computed scenarios: dropping a guest lists exactly that guest (SEAT-51)" do
      persons = Enum.map(1..6, &person/1)

      extra = [
        circles: [circle(1, :keep_together), circle(2, :keep_together)],
        circle_memberships: memberships(1, [1, 2, 3]) ++ memberships(2, [4, 5, 6])
      ]

      full = plan(persons, [{:type, 2, 3}], extra)

      declined =
        for p <- persons,
            do: %Invitation{
              id: p.id,
              person_id: p.id,
              event_id: 1,
              status: if(p.id == 6, do: :declined, else: :accepted)
            }

      without = plan(persons, [{:type, 2, 3}], [invitations: declined] ++ extra)

      assert {:ok, [%{parties: [{:person, 6}], b: nil}]} = SeatingPlan.compare(full, without)
    end
  end

  defp compare_ab(a, b), do: SeatingPlan.compare(a, b)
end
