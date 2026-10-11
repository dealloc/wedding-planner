defmodule WeddingPlanner.Valuation.Seating do
  @moduledoc """
  The seating engine (`docs/modules/seating.md`). Pure and UI-independent (`NFR-41`):
  a function of a `WeddingPlanner.Valuation.Snapshot`, a preset and an event, computed
  every time and never stored (SEAT-50, `D-35`).

  Slice 1 computes everything the input screen's health panel needs — who is seated,
  the seating units, the pull between every two people, blocking problems, warnings and
  loose ends. Tables, pins and the plan itself build on `analyse/3` in a later slice.

  ## Who is seated (SEAT-02, SEAT-03)

  Exactly the persons `WeddingPlanner.Valuation.Headcount.counted/3` counts for the event
  under the preset, plus `:couple` when the event's *couple attends* flag is set. A seated
  party is a `t:party/0`: `{:person, id}` or `:couple` — the same tokens a rule's sides
  use (`WeddingPlanner.Seating.Rule.t:side/0`).

  ## Pairs and precedence (SEAT-32, SEAT-33)

  A rule with a circle on a side applies to every seated member of it. For every two
  seated parties the engine collects the hard rules that cover them, and the soft
  contributions in order of specificity: person ↔ person rules (the couple counts as a
  person), person ↔ circle rules, circle ↔ circle rules, then shared circles (which add
  up, SEAT-23), then a shared group (SEAT-22, read through
  `WeddingPlanner.Guests.PlusOne` so a +1 is in its host's group). The most specific
  level present decides the pair's pull; its contributions are summed. The weights are
  internal (`D-37`; `docs/06-decisions.md` "Seating weights").

  A pair covered by *never with* has no pull at all: a pull towards someone you may not
  sit with does not place you anywhere.

  ## Units (SEAT-10, SEAT-11)

  Union–find over the seated parties, joined by each +1's link to its seated host and
  by every *always with* pair. A unit's members are listed in seating order: the couple
  first, then persons in snapshot order.

  ## Health (SEAT-61, SEAT-62)

    * **Blocking:** a *never with* rule both of whose sides end up in one unit, with the
      chain of links that joined them (`A → B → C`).
    * **Warnings:** two soft rules of the same specificity pulling one pair in opposite
      directions; a soft rule overruled by a hard one.
    * **Loose ends:** a unit with no pull towards anyone outside it, unless every member
      is *fine anywhere*. With only one unit seated there is nobody to be a stranger to,
      so there are no loose ends.

  Every list is deduplicated per rule (pair of rules), not per pair of people: a circle
  rule over twenty pairs is one warning.
  """

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Guests.PlusOne
  alias WeddingPlanner.Seating.Rule
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot

  @typedoc "A seated party: a person or the couple."
  @type party :: {:person, term()} | :couple

  @type link :: {:plus_one, party(), party()} | {:rule, Rule.t(), party(), party()}

  @type blocking ::
          {:never_with_in_unit, Rule.t(), [party()]}

  @type warning ::
          {:contradiction, Rule.t(), Rule.t()}
          | {:overruled, soft :: Rule.t(), hard :: Rule.t()}

  @type t :: %{
          event: Event.t(),
          preset: Preset.t(),
          parties: [party()],
          persons: %{term() => Person.t()},
          units: [[party()]],
          unit_index: %{party() => non_neg_integer()},
          pulls: %{{party(), party()} => integer()},
          never_with: MapSet.t({party(), party()}),
          circle_members: %{term() => [party()]},
          cohesion_sets: [{pos_integer(), [party()]}],
          soft_pairs: [{Rule.t(), {party(), party()}}],
          blocking: [blocking()],
          warnings: [warning()],
          loose_ends: [[party()]]
        }

  # docs/06-decisions.md, "Seating weights (initial, internal)" — D-37: never shown.
  @cohesion_weights %{keep_together: 8, like_together: 4, know_each_other: 1}
  @group_weight 1
  @relation_weights %{seat_with: 10, keep_apart: -10}

  @doc "Analyses `event`'s seating under `preset`. See the moduledoc."
  @spec analyse(Snapshot.t(), Preset.t(), Event.t()) :: t()
  def analyse(%Snapshot{} = snapshot, %Preset{} = preset, %Event{} = event) do
    counted = Headcount.counted(snapshot, preset, event)
    persons = Map.new(counted, &{&1.person.id, &1.person})
    person_parties = Enum.map(counted, &{:person, &1.person.id})
    parties = if event.couple_attends, do: [:couple | person_parties], else: person_parties
    seated = MapSet.new(parties)

    circle_members = circle_members(snapshot, seated)
    expanded = expand_rules(snapshot.seating_rules, circle_members, seated)

    {hard, soft} = Enum.split_with(expanded, fn {rule, _pair} -> Rule.hard?(rule.relation) end)
    never_with = for {%Rule{relation: :never_with}, pair} <- hard, into: MapSet.new(), do: pair

    links = plus_one_links(snapshot, persons) ++ always_with_links(hard)
    {units, unit_index} = units(parties, links)

    pulls =
      pulls(soft, circle_pulls(snapshot, circle_members), group_pulls(persons, snapshot))
      |> Map.drop(MapSet.to_list(never_with))

    %{
      event: event,
      preset: preset,
      parties: parties,
      persons: persons,
      units: units,
      unit_index: unit_index,
      pulls: pulls,
      never_with: never_with,
      circle_members: circle_members,
      cohesion_sets: cohesion_sets(snapshot, circle_members, persons),
      soft_pairs: soft,
      blocking: blocking(hard, unit_index, links),
      warnings: contradictions(soft) ++ overruled(soft, hard),
      loose_ends: loose_ends(units, unit_index, pulls, persons)
    }
  end

  @doc "The pull between two seated parties (0 when there is none, SEAT-33)."
  @spec pull(t(), party(), party()) :: integer()
  def pull(%{pulls: pulls}, a, b), do: Map.get(pulls, pair(a, b), 0)

  @doc "Every seated person marked *fine anywhere* (SEAT-35), in seating order."
  @spec fine_anywhere(t()) :: [Person.t()]
  def fine_anywhere(%{parties: parties, persons: persons}) do
    for {:person, id} <- parties, persons[id].fine_anywhere, do: persons[id]
  end

  @doc "How many seats `analyse/3`'s parties take: one per person, two for the couple."
  @spec seats(t()) :: non_neg_integer()
  def seats(%{parties: parties}), do: Enum.sum(Enum.map(parties, &party_seats/1))

  @doc "The seats one party takes."
  @spec party_seats(party()) :: pos_integer()
  def party_seats(:couple), do: Headcount.couple(%Snapshot{}, %Event{couple_attends: true})
  def party_seats({:person, _id}), do: 1

  # -- membership and rule expansion ---------------------------------------------------

  # The seated members of every circle. The wedding party also holds the couple and every
  # witness, derived here rather than stored (SEAT-24).
  defp circle_members(snapshot, seated) do
    stored =
      snapshot.circle_memberships
      |> Enum.filter(&MapSet.member?(seated, {:person, &1.person_id}))
      |> Enum.group_by(& &1.circle_id, &{:person, &1.person_id})

    case Enum.find(snapshot.circles, &(&1.role == :wedding_party)) do
      nil ->
        stored

      party ->
        derived =
          [:couple | for(p <- snapshot.persons, p.witness_of_id, do: {:person, p.id})]
          |> Enum.filter(&MapSet.member?(seated, &1))

        Map.update(stored, party.id, derived, &Enum.uniq(derived ++ &1))
    end
  end

  defp side_members({:circle, id}, circle_members, _seated), do: Map.get(circle_members, id, [])

  defp side_members(side, _circle_members, seated),
    do: if(MapSet.member?(seated, side), do: [side], else: [])

  # SEAT-32: every pair of members across the two sides; nobody is paired with themselves.
  defp expand_rules(rules, circle_members, seated) do
    for rule <- rules,
        a <- side_members(Rule.side_a(rule), circle_members, seated),
        b <- side_members(Rule.side_b(rule), circle_members, seated),
        a != b,
        uniq: true,
        do: {rule, pair(a, b)}
  end

  # SEAT-33: lower is more specific; the couple counts as a person.
  defp specificity(%Rule{} = rule) do
    case Enum.count([Rule.side_a(rule), Rule.side_b(rule)], &match?({:circle, _}, &1)) do
      0 -> 1
      1 -> 2
      2 -> 3
    end
  end

  # -- pulls -----------------------------------------------------------------------------

  defp circle_pulls(snapshot, circle_members) do
    for circle <- snapshot.circles,
        {a, b} <- pairs_within(Map.get(circle_members, circle.id, [])),
        reduce: %{} do
      acc -> Map.update(acc, pair(a, b), weight(circle), &(&1 + weight(circle)))
    end
  end

  # Every circle and group with at least two seated members, with its weight — what the
  # plan's lone-member penalty is measured against (SEAT-52).
  defp cohesion_sets(snapshot, circle_members, persons) do
    circles =
      for circle <- snapshot.circles,
          members = Map.get(circle_members, circle.id, []),
          length(members) >= 2,
          do: {weight(circle), members}

    hosts = Map.new(snapshot.persons, &{&1.id, &1})

    groups =
      persons
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.group_by(&group_of(&1, hosts))
      |> Map.delete(nil)
      |> Enum.sort()
      |> Enum.map(fn {_group, members} -> Enum.map(members, &{:person, &1.id}) end)
      |> Enum.filter(&(length(&1) >= 2))
      |> Enum.map(&{@group_weight, &1})

    circles ++ groups
  end

  defp weight(circle), do: Map.fetch!(@cohesion_weights, circle.cohesion)

  defp group_pulls(persons, snapshot) do
    hosts = Map.new(snapshot.persons, &{&1.id, &1})

    persons
    |> Map.values()
    |> Enum.group_by(&group_of(&1, hosts))
    |> Map.delete(nil)
    |> Enum.flat_map(fn {_group, members} ->
      members |> Enum.map(&{:person, &1.id}) |> pairs_within()
    end)
    |> Map.new(fn {a, b} -> {pair(a, b), @group_weight} end)
  end

  defp group_of(%Person{host_id: nil} = person, _hosts), do: person.group_id

  defp group_of(%Person{host_id: host_id} = person, hosts) do
    case Map.fetch(hosts, host_id) do
      {:ok, host} -> PlusOne.group_id(person, host)
      :error -> nil
    end
  end

  defp pulls(soft, circle_pulls, group_pulls) do
    rule_pulls =
      soft
      |> Enum.group_by(fn {_rule, pair} -> pair end, fn {rule, _pair} -> rule end)
      |> Map.new(fn {pair, rules} -> {pair, most_specific_sum(rules)} end)

    group_pulls
    |> Map.merge(circle_pulls)
    |> Map.merge(rule_pulls)
    |> Map.reject(fn {_pair, value} -> value == 0 end)
  end

  defp most_specific_sum(rules) do
    level = rules |> Enum.map(&specificity/1) |> Enum.min()

    rules
    |> Enum.filter(&(specificity(&1) == level))
    |> Enum.map(&Map.fetch!(@relation_weights, &1.relation))
    |> Enum.sum()
  end

  # -- units -----------------------------------------------------------------------------

  defp plus_one_links(snapshot, persons) do
    for person <- snapshot.persons,
        person.host_id,
        Map.has_key?(persons, person.id),
        Map.has_key?(persons, person.host_id),
        do: {:plus_one, {:person, person.host_id}, {:person, person.id}}
  end

  defp always_with_links(hard) do
    for {%Rule{relation: :always_with} = rule, {a, b}} <- hard, do: {:rule, rule, a, b}
  end

  defp units(parties, links) do
    roots =
      Enum.reduce(links, Map.new(parties, &{&1, &1}), fn link, roots ->
        {a, b} = link_ends(link)
        union(roots, a, b)
      end)

    groups = Enum.group_by(parties, &find(roots, &1))

    units =
      parties
      |> Enum.map(&find(roots, &1))
      |> Enum.uniq()
      |> Enum.map(&Map.fetch!(groups, &1))

    unit_index =
      for {unit, index} <- Enum.with_index(units), party <- unit, into: %{}, do: {party, index}

    {units, unit_index}
  end

  defp link_ends({:plus_one, a, b}), do: {a, b}
  defp link_ends({:rule, _rule, a, b}), do: {a, b}

  defp find(roots, party) do
    case Map.fetch!(roots, party) do
      ^party -> party
      parent -> find(roots, parent)
    end
  end

  defp union(roots, a, b) do
    {root_a, root_b} = {find(roots, a), find(roots, b)}
    if root_a == root_b, do: roots, else: Map.put(roots, root_b, root_a)
  end

  # -- health ----------------------------------------------------------------------------

  defp blocking(hard, unit_index, links) do
    for {%Rule{relation: :never_with} = rule, {a, b}} <- hard,
        Map.fetch!(unit_index, a) == Map.fetch!(unit_index, b) do
      {:never_with_in_unit, rule, chain(links, a, b)}
    end
    |> Enum.uniq_by(fn {:never_with_in_unit, rule, _chain} -> rule.id end)
  end

  # The shortest chain of links from `from` to `to` (breadth-first over the unit graph).
  defp chain(links, from, to) do
    neighbours =
      Enum.reduce(links, %{}, fn link, acc ->
        {a, b} = link_ends(link)

        acc
        |> Map.update(a, [b], &[b | &1])
        |> Map.update(b, [a], &[a | &1])
      end)

    bfs(:queue.from_list([[from]]), MapSet.new([from]), to, neighbours)
  end

  defp bfs(queue, visited, to, neighbours) do
    case :queue.out(queue) do
      {:empty, _} ->
        []

      {{:value, [^to | _] = path}, _rest} ->
        Enum.reverse(path)

      {{:value, [current | _] = path}, rest} ->
        next = neighbours |> Map.get(current, []) |> Enum.sort() |> Enum.reject(&(&1 in visited))
        queue = Enum.reduce(next, rest, &:queue.in([&1 | path], &2))
        bfs(queue, MapSet.union(visited, MapSet.new(next)), to, neighbours)
    end
  end

  defp contradictions(soft) do
    soft
    |> Enum.group_by(fn {_rule, pair} -> pair end, fn {rule, _pair} -> rule end)
    |> Enum.flat_map(fn {_pair, rules} ->
      level = rules |> Enum.map(&specificity/1) |> Enum.min()
      at_level = Enum.filter(rules, &(specificity(&1) == level))

      for pull <- at_level,
          push <- at_level,
          pull.relation == :seat_with,
          push.relation == :keep_apart,
          do: ordered(pull, push)
    end)
    |> Enum.uniq()
    |> Enum.sort_by(fn {a, b} -> {a.id, b.id} end)
    |> Enum.map(fn {a, b} -> {:contradiction, a, b} end)
  end

  defp overruled(soft, hard) do
    hard_by_pair = Enum.group_by(hard, fn {_rule, pair} -> pair end, fn {rule, _} -> rule end)

    soft
    |> Enum.flat_map(fn {soft_rule, pair} ->
      for hard_rule <- Map.get(hard_by_pair, pair, []),
          opposed?(soft_rule, hard_rule),
          do: {soft_rule, hard_rule}
    end)
    |> Enum.uniq_by(fn {soft_rule, hard_rule} -> {soft_rule.id, hard_rule.id} end)
    |> Enum.sort_by(fn {soft_rule, hard_rule} -> {soft_rule.id, hard_rule.id} end)
    |> Enum.map(fn {soft_rule, hard_rule} -> {:overruled, soft_rule, hard_rule} end)
  end

  defp opposed?(%Rule{relation: :seat_with}, %Rule{relation: :never_with}), do: true
  defp opposed?(%Rule{relation: :keep_apart}, %Rule{relation: :always_with}), do: true
  defp opposed?(_soft, _hard), do: false

  defp loose_ends([_only_unit], _unit_index, _pulls, _persons), do: []

  defp loose_ends(units, unit_index, pulls, persons) do
    pulled_units =
      for {{a, b}, value} <- pulls,
          value > 0,
          Map.fetch!(unit_index, a) != Map.fetch!(unit_index, b),
          index <- [Map.fetch!(unit_index, a), Map.fetch!(unit_index, b)],
          into: MapSet.new(),
          do: index

    units
    |> Enum.with_index()
    |> Enum.reject(fn {unit, index} ->
      MapSet.member?(pulled_units, index) or Enum.all?(unit, &fine_anywhere?(&1, persons))
    end)
    |> Enum.map(fn {unit, _index} -> unit end)
  end

  defp fine_anywhere?(:couple, _persons), do: false
  defp fine_anywhere?({:person, id}, persons), do: persons[id].fine_anywhere

  # -- helpers ---------------------------------------------------------------------------

  # One key per unordered pair, whichever way round it is asked for.
  defp pair(a, b) when a <= b, do: {a, b}
  defp pair(a, b), do: {b, a}

  defp ordered(a, b), do: if(a.id <= b.id, do: {a, b}, else: {b, a})

  defp pairs_within(members) do
    members = Enum.uniq(members)
    for {a, i} <- Enum.with_index(members), {b, j} <- Enum.with_index(members), i < j, do: {a, b}
  end
end
