defmodule WeddingPlannerWeb.SeatingOverview do
  @moduledoc """
  The pure view model of `/seating`'s health panel and rule list (`docs/modules/seating.md`
  SEAT-60..SEAT-62): turns a `WeddingPlanner.Valuation.Seating.analyse/3` result plus the
  names it refers to into display-ready rows. No database, no socket.

  Names are resolved here once, through `names/3`: a seated party or a rule side to the
  label the screen shows — the couple by the users' names (SEAT-03), an unnamed +1 as
  "+1 of ⟨host⟩" (`PER-11`), a circle by its name.
  """

  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Seating.Rule
  alias WeddingPlanner.Seating.Table
  alias WeddingPlanner.Valuation.Seating
  alias WeddingPlanner.Valuation.SeatingPlan

  @type names :: %{optional(Rule.side()) => String.t()}

  @doc """
  The label of every person, circle and the couple: `%{side => name}`. `persons` are the
  snapshot's (an unnamed +1 is named after its host from the same list).
  """
  @spec names([Person.t()], [WeddingPlanner.Seating.Circle.t()], String.t()) :: names()
  def names(persons, circles, couple_name) do
    hosts = Map.new(persons, &{&1.id, &1})

    person_names =
      Map.new(persons, fn person ->
        host = if person.host_id, do: Map.get(hosts, person.host_id)
        {{:person, person.id}, Person.display_name(%{person | host: host})}
      end)

    circle_names = Map.new(circles, &{{:circle, &1.id}, &1.name})

    person_names |> Map.merge(circle_names) |> Map.put(:couple, couple_name)
  end

  @doc "The label of one side or party; a deleted one reads as such rather than raising."
  @spec name(names(), Rule.side()) :: String.t()
  def name(names, side) do
    Map.get_lazy(names, side, fn ->
      case side do
        {:circle, _} -> "a deleted circle"
        _ -> "a deleted person"
      end
    end)
  end

  @doc "A rule as a sentence of display parts: `{first, relation, second}`."
  @spec sentence(names(), Rule.t()) :: {String.t(), String.t(), String.t()}
  def sentence(names, %Rule{} = rule) do
    {name(names, Rule.side_a(rule)), Rule.relation_label(rule.relation),
     name(names, Rule.side_b(rule))}
  end

  @doc """
  The health panel (SEAT-60): counts, blocking problems, warnings, loose ends and the
  seated *fine anywhere* persons, each a list of display maps.
  """
  @spec health(Seating.t(), [Table.t()], [WeddingPlanner.Seating.Pin.t()], names()) :: map()
  def health(analysis, tables, pins, names) do
    persons = for {:person, _} <- analysis.parties, do: 1

    %{
      seats: Seating.seats(analysis),
      available: SeatingPlan.available_seats(tables),
      tables: length(tables),
      people: length(persons),
      couple?: :couple in analysis.parties,
      units: length(analysis.units),
      blocking:
        analysis
        |> SeatingPlan.problems_before_search(tables, pins)
        |> Enum.map(&problem(&1, names)),
      inactive_pins:
        for pin <- SeatingPlan.inactive_pins(analysis, pins) do
          table = Enum.find(tables, &(&1.id == pin.seating_table_id))

          %{
            id: "inactive-pin-#{pin.id}",
            title:
              "#{name(names, WeddingPlanner.Seating.Pin.side(pin))} → #{table && table.name}",
            detail: "Not seated under this preset; the pin is kept."
          }
        end,
      warnings: Enum.map(analysis.warnings, &warning(&1, names)),
      loose_ends: Enum.map(analysis.loose_ends, &loose_end(&1, names)),
      fine_anywhere:
        Enum.map(
          Seating.fine_anywhere(analysis),
          &%{id: &1.id, name: name(names, {:person, &1.id})}
        )
    }
  end

  @doc """
  One plan problem (`WeddingPlanner.Valuation.SeatingPlan.t:problem/0`) as a display map
  with a DOM id, a title and a detail line.
  """
  @spec problem(SeatingPlan.problem(), names()) :: map()
  def problem({:blocking, blocking}, names), do: blocking(blocking, names)

  def problem(:no_tables, _names) do
    %{
      id: "problem-no-tables",
      rule_id: nil,
      title: "No tables yet",
      detail: "Add this event's tables to see a plan."
    }
  end

  def problem({:too_many_seats, needed, available}, _names) do
    %{
      id: "problem-too-many-seats",
      rule_id: nil,
      title: "#{needed} seats needed, #{available} available",
      detail: "Add tables or raise their maximums."
    }
  end

  def problem({:no_table_types, needed}, _names) do
    %{
      id: "problem-no-table-types",
      rule_id: nil,
      title: "#{needed} seats needed, but there are no table types",
      detail: "A fixed table seats only who is pinned to it; add the sizes the venue offers."
    }
  end

  def problem({:pinned_twice, unit, tables}, names) do
    %{
      id: "problem-pinned-twice-" <> Enum.map_join(unit, "-", &party_dom_id/1),
      rule_id: nil,
      title:
        "#{Enum.map_join(unit, ", ", &name(names, &1))} pinned to #{Enum.map_join(tables, " and ", & &1.name)}",
      detail: "Someone can sit at one table only; remove one of the pins."
    }
  end

  def problem({:pinned_above_maximum, table, seats}, _names) do
    %{
      id: "problem-pinned-above-#{table.id}",
      rule_id: nil,
      title: "#{seats} pinned to #{table.name}, which seats at most #{table.max_seats}",
      detail: "Pin fewer people there, or raise its maximum."
    }
  end

  def problem({:pinned_below_minimum, table, seats}, _names) do
    %{
      id: "problem-pinned-below-#{table.id}",
      rule_id: nil,
      title: "#{seats} pinned to #{table.name}, which needs at least #{table.min_seats}",
      detail: "A fixed table seats only its pins: pin more people there, or lower its minimum."
    }
  end

  def problem({:unit_too_large, unit, size, largest}, names) do
    %{
      id: "problem-unit-" <> Enum.map_join(unit, "-", &party_dom_id/1),
      rule_id: nil,
      title: "#{size} people must sit together; the largest table seats #{largest}",
      detail: Enum.map_join(unit, ", ", &name(names, &1)) <> "."
    }
  end

  def problem({:below_minimum, table, seats}, _names) do
    %{
      id: "problem-below-#{table.id}",
      rule_id: nil,
      title: "#{table.name} has #{seats} of at least #{table.min_seats}",
      detail: "No plan was found that fills it or leaves it empty."
    }
  end

  def problem({:above_maximum, table, seats}, _names) do
    %{
      id: "problem-above-#{table.id}",
      rule_id: nil,
      title: "#{table.name} has #{seats} of at most #{table.max_seats}",
      detail: "No plan was found that fits everyone."
    }
  end

  def problem({:never_with_together, table, a, b}, names) do
    %{
      id: "problem-never-#{party_dom_id(a)}-#{party_dom_id(b)}",
      rule_id: nil,
      title: "#{name(names, a)} and #{name(names, b)} share #{table.name}",
      detail: "They should never sit together; no plan was found that separates them."
    }
  end

  @doc """
  The plan view model (SEAT-54, SEAT-70): per table its parties grouped into seating
  units (unit-mates stay together on screen), seats and fit; per party who pulls them
  there and which soft rules this plan breaks.
  """
  @spec plan(Seating.t(), SeatingPlan.t(), names()) :: map()
  def plan(analysis, %{status: status} = result, names) do
    explain = if status == :blocked, do: %{}, else: SeatingPlan.explain(analysis, result)
    pinned = Map.get(result, :pinned, MapSet.new())

    %{
      status: status,
      problems: Enum.map(result.problems, &problem(&1, names)),
      used: used_tables(result.tables),
      tables:
        for %{table: table, parties: parties, seats: seats, score: score} <- result.tables do
          %{
            table: table,
            seats: seats,
            score: score,
            units:
              parties
              |> group_by_unit(analysis.unit_index)
              |> Enum.map(fn unit -> Enum.map(unit, &party_row(&1, explain, pinned, names)) end)
          }
        end
    }
  end

  # SEAT-45: how many tables of each kind the plan uses — "Round ×5", "Head table" —
  # counting only tables with someone at them, in sort order.
  defp used_tables(tables) do
    tables
    |> Enum.reject(&(&1.seats == 0))
    |> Enum.chunk_by(& &1.table.source.id)
    |> Enum.map(fn [%{table: %{source: source}} | _] = group ->
      if WeddingPlanner.Seating.Table.fixed?(source),
        do: source.name,
        else: "#{source.name} ×#{length(group)}"
    end)
  end

  # Unit-mates together, units in the order of their first member at the table.
  defp group_by_unit(parties, unit_index) do
    groups = Enum.group_by(parties, &Map.fetch!(unit_index, &1))

    parties
    |> Enum.map(&Map.fetch!(unit_index, &1))
    |> Enum.uniq()
    |> Enum.map(&Map.fetch!(groups, &1))
  end

  defp party_row(party, explain, pinned, names) do
    %{pulled_by: pulled_by, broken: broken} =
      Map.get(explain, party, %{pulled_by: [], broken: []})

    %{
      id: party_dom_id(party),
      key: Rule.side_key(party),
      name: name(names, party),
      seats: Seating.party_seats(party),
      pinned?: MapSet.member?(pinned, party),
      knows: Enum.map(pulled_by, &name(names, &1)),
      broken: Enum.map(broken, &sentence_text(names, &1))
    }
  end

  defp sentence_text(names, rule) do
    {a, relation, b} = sentence(names, rule)
    "#{a} #{relation} #{b}"
  end

  defp blocking({:never_with_in_unit, rule, chain}, names) do
    %{
      id: "blocking-#{rule.id}",
      rule_id: rule.id,
      title: "#{quoted(names, rule)} cannot hold",
      detail:
        "They always sit together through " <>
          Enum.map_join(chain, " → ", &name(names, &1)) <> "."
    }
  end

  defp warning({:contradiction, a, b}, names) do
    %{
      id: "warning-#{a.id}-#{b.id}",
      rule_ids: [a.id, b.id],
      title: "Two rules disagree",
      detail:
        "#{quoted(names, a)} and #{quoted(names, b)} pull some people in opposite directions; " <>
          "they cancel out. A rule between those people themselves settles it."
    }
  end

  defp warning({:overruled, soft, hard}, names) do
    %{
      id: "warning-#{soft.id}-#{hard.id}",
      rule_ids: [soft.id, hard.id],
      title: "A rule is overruled",
      detail: "#{quoted(names, soft)} has no effect where #{quoted(names, hard)} applies."
    }
  end

  defp loose_end(unit, names) do
    %{
      id: "loose-" <> Enum.map_join(unit, "-", &party_dom_id/1),
      members:
        for party <- unit do
          %{party: party, name: name(names, party), person_id: person_id(party)}
        end
    }
  end

  defp quoted(names, rule) do
    {a, relation, b} = sentence(names, rule)
    "‘#{a} #{relation} #{b}’"
  end

  defp person_id({:person, id}), do: id
  defp person_id(:couple), do: nil

  @doc "A DOM-id-safe token for a party."
  @spec party_dom_id(Seating.party()) :: String.t()
  def party_dom_id(:couple), do: "couple"
  def party_dom_id({:person, id}), do: "person-#{id}"
end
