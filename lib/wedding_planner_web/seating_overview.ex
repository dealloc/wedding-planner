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
  alias WeddingPlanner.Valuation.Seating

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
  @spec health(Seating.t(), names()) :: map()
  def health(analysis, names) do
    persons = for {:person, _} <- analysis.parties, do: 1

    %{
      seats: Seating.seats(analysis),
      people: length(persons),
      couple?: :couple in analysis.parties,
      units: length(analysis.units),
      blocking: Enum.map(analysis.blocking, &blocking(&1, names)),
      warnings: Enum.map(analysis.warnings, &warning(&1, names)),
      loose_ends: Enum.map(analysis.loose_ends, &loose_end(&1, names)),
      fine_anywhere:
        Enum.map(
          Seating.fine_anywhere(analysis),
          &%{id: &1.id, name: name(names, {:person, &1.id})}
        )
    }
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
