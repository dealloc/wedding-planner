defmodule WeddingPlanner.Valuation.SeatingPlan do
  @moduledoc """
  The seating solver (`docs/modules/seating.md` SEAT-50..SEAT-54, `D-38`): places the
  seating units of a `WeddingPlanner.Valuation.Seating.analyse/3` result at an event's
  tables. Pure (`NFR-41`) and computed every time, never stored (SEAT-50).

  ## Before searching (SEAT-61)

  The plan is not computed when no valid plan can exist, and `compute/3` says why
  (`status: :blocked`): a blocking problem from the analysis, no tables, more seats needed
  than all tables' maximums together, or a unit larger than the largest table.

  ## The search (SEAT-51, SEAT-52, `D-38`)

  Simulated annealing over unit → table assignments, from a greedy start. A move puts one
  unit at another table or swaps two units at different tables. The score of a plan is
  the sum of its tables' scores:

    * the pulls between every two units at the table (`Seating.pull/3`, summed over
      their members);
    * minus the stranger penalty for every unit with no positive pull towards anyone
      else at its table, unless all its members are *fine anywhere* (SEAT-52);
    * minus a large penalty per broken hard constraint (SEAT-53): a seat below the
      minimum or above the maximum of a non-empty table, two units under *never with*.

  Hard constraints are penalties rather than walls so the search can pass through an
  invalid plan on its way to a better valid one. Only a plan without any is valid.

  **Deterministic:** a fixed seed, a fixed number of steps that depends only on the
  number of units (never on time), and inputs in a fixed order — so both users always see
  the same plan (SEAT-51). Not provably optimal (SEAT-52); the best plan seen is kept.

  ## The result

  `status` is `:ok`, `:blocked` (with `problems`, no tables) or `:invalid` (no valid plan
  found: the best attempt, clearly marked, with every broken hard constraint in
  `problems`, SEAT-53). Each table lists its parties in seating order, its seats and its
  score; `explain/2` gives, per party, who pulls them there and which of their soft rules
  are broken (SEAT-54).
  """

  alias WeddingPlanner.Seating.Pin
  alias WeddingPlanner.Seating.Rule
  alias WeddingPlanner.Seating.Table
  alias WeddingPlanner.Valuation.Seating

  @type problem ::
          {:blocking, Seating.blocking()}
          | :no_tables
          | {:too_many_seats, needed :: non_neg_integer(), available :: non_neg_integer()}
          | {:no_table_types, needed :: pos_integer()}
          | {:pinned_twice, [Seating.party()], [Table.t()]}
          | {:pinned_above_maximum, Table.t(), seats :: pos_integer()}
          | {:pinned_below_minimum, Table.t(), seats :: pos_integer()}
          | {:unit_too_large, [Seating.party()], size :: pos_integer(), largest :: pos_integer()}
          | {:below_minimum, plan_table(), seats :: non_neg_integer()}
          | {:above_maximum, plan_table(), seats :: non_neg_integer()}
          | {:never_with_together, plan_table(), Seating.party(), Seating.party()}

  @typedoc """
  One concrete table of a plan: a fixed table, or the i-th table of a type (SEAT-45).
  `source` is the stored table type or fixed table it comes from.
  """
  @type plan_table :: %{
          id: String.t(),
          name: String.t(),
          min_seats: pos_integer(),
          max_seats: pos_integer(),
          source: Table.t()
        }

  @type table_result :: %{
          table: plan_table(),
          parties: [Seating.party()],
          seats: non_neg_integer(),
          score: integer()
        }

  @type t :: %{
          status: :ok | :blocked | :invalid,
          problems: [problem()],
          tables: [table_result()],
          table_of: %{Seating.party() => String.t()},
          pinned: MapSet.t(Seating.party())
        }

  # docs/06-decisions.md, "Seating weights (initial, internal)".
  @stranger 20
  @hard 1_000
  @hard_start 2.0

  @extra_tables 3
  @seed {1_031, 2_053, 4_099}
  @steps_per_unit 600
  @min_steps 5_000
  @max_steps 80_000
  @t_start 12.0
  @t_end 0.05

  @typedoc """
  One seating unit that sits differently in two scenarios (SEAT-72): its parties and the
  table each scenario puts it at, `nil` where it is not seated at all.
  """
  @type difference :: %{
          parties: [Seating.party()],
          a: plan_table() | nil,
          b: plan_table() | nil
        }

  @doc """
  Compares two scenarios' plans (SEAT-72): which seating units sit at a different table.

  Each side is `{analysis, plan}` as given to and returned by `compute/3`. Table type
  tables are numbered arbitrarily ("Round 2" in A may be another group than "Round 2" in
  B), so tables are first **matched** rather than compared by name: a fixed table matches
  itself (same stored table); the type tables with members are paired greedily by the
  number of members they share, most first, ties broken by table order (A, then B), each
  table used once. A unit then **differs** when it is seated in only one scenario, or its
  table in A is not matched to its table in B. Units are the units of A, or of B for those
  seated only there; unit-mates that part ways are listed separately. Pure and
  deterministic (SEAT-51).

  Returns `{:ok, differences}` ordered by their first party, or `{:error, unavailable}`
  naming each side (`:a` / `:b`) whose plan is not `:ok`, with its status: a blocked or
  invalid plan is never diffed.
  """
  @spec compare({Seating.t(), t()}, {Seating.t(), t()}) ::
          {:ok, [difference()]} | {:error, [{:a | :b, :blocked | :invalid}]}
  def compare({analysis_a, a}, {analysis_b, b}) do
    case for({side, %{status: status}} <- [a: a, b: b], status != :ok, do: {side, status}) do
      [] -> {:ok, differences({analysis_a, a}, {analysis_b, b})}
      unavailable -> {:error, unavailable}
    end
  end

  defp differences({analysis_a, a}, {analysis_b, b}) do
    match = match_tables(a, b)
    tables_a = seated_tables(a)
    tables_b = seated_tables(b)

    (Map.keys(a.table_of) ++ Map.keys(b.table_of))
    |> Enum.uniq()
    |> Enum.sort_by(&Rule.side_key/1)
    |> Enum.flat_map(fn party ->
      ta = Map.get(tables_a, Map.get(a.table_of, party))
      tb = Map.get(tables_b, Map.get(b.table_of, party))
      same? = ta != nil and tb != nil and Map.get(match, ta.id) == tb.id

      cond do
        same? ->
          []

        ta != nil ->
          [{{:a, Map.fetch!(analysis_a.unit_index, party), ta.id, tb && tb.id}, party, ta, tb}]

        true ->
          [{{:b, Map.fetch!(analysis_b.unit_index, party), nil, tb.id}, party, ta, tb}]
      end
    end)
    |> Enum.group_by(&elem(&1, 0), fn {_key, party, ta, tb} -> {party, ta, tb} end)
    |> Enum.map(fn {_key, [{_, ta, tb} | _] = rows} ->
      %{parties: Enum.map(rows, &elem(&1, 0)), a: ta, b: tb}
    end)
    |> Enum.sort_by(fn %{parties: [first | _]} -> Rule.side_key(first) end)
  end

  defp seated_tables(plan), do: Map.new(plan.tables, &{&1.table.id, &1.table})

  # %{a_table_id => b_table_id}: fixed tables by identity, type tables by greedy overlap.
  defp match_tables(a, b) do
    members_a = table_members(a)
    members_b = table_members(b)
    ids_b = MapSet.new(members_b, &elem(&1, 0))

    fixed =
      for {id, table, _} <- members_a,
          table.source.kind == :fixed,
          MapSet.member?(ids_b, id),
          into: %{},
          do: {id, id}

    typed_a = for {_, t, _} = e <- members_a, t.source.kind != :fixed, do: e
    typed_b = for {_, t, _} = e <- members_b, t.source.kind != :fixed, do: e

    pairs =
      for {{ia, _, pa}, pos_a} <- Enum.with_index(typed_a),
          {{ib, _, pb}, pos_b} <- Enum.with_index(typed_b),
          overlap = MapSet.size(MapSet.intersection(pa, pb)),
          overlap > 0,
          do: {-overlap, pos_a, pos_b, ia, ib}

    {typed, _used} =
      pairs
      |> Enum.sort()
      |> Enum.reduce({%{}, MapSet.new()}, fn {_, _, _, ia, ib}, {acc, used} ->
        if Map.has_key?(acc, ia) or MapSet.member?(used, ib),
          do: {acc, used},
          else: {Map.put(acc, ia, ib), MapSet.put(used, ib)}
      end)

    Map.merge(typed, fixed)
  end

  defp table_members(plan) do
    for %{table: table, parties: parties} <- plan.tables, parties != [] do
      {table.id, table, MapSet.new(parties)}
    end
  end

  @doc """
  Places `analysis`'s units at `tables` (the event's tables, in sort order). See the
  moduledoc.
  """
  @spec compute(Seating.t(), [Table.t()], [Pin.t()]) :: t()
  def compute(analysis, tables, pins \\ []) do
    case problems_before_search(analysis, tables, pins) do
      [] ->
        search_fewest_tables(analysis, tables, single_pins(analysis, tables, pins))

      problems ->
        %{status: :blocked, problems: problems, tables: [], table_of: %{}, pinned: MapSet.new()}
    end
  end

  # SEAT-45: as few tables as a valid plan needs. The fewest tables that hold everyone
  # not pinned come first; when no valid plan is found on them (two people who must never
  # share a table, with everyone fitting at one), up to `@extra_tables` more are tried,
  # one at a time. Failing all, the attempt with the fewest problems, then the fewest
  # tables.
  defp search_fewest_tables(analysis, tables, pinned) do
    free_seats = unpinned_seats(analysis, pinned)

    attempts =
      Enum.reduce_while(0..@extra_tables, [], fn extra, attempts ->
        plan = search(analysis, plan_tables(tables, free_seats, extra), pinned)
        if plan.status == :ok, do: {:halt, [plan]}, else: {:cont, [plan | attempts]}
      end)

    attempts
    |> Enum.reverse()
    |> Enum.min_by(&{length(&1.problems), length(&1.tables)})
  end

  # -- pins (SEAT-42, SEAT-43, D-44) -----------------------------------------------------

  @doc """
  The seated parties a pin puts at its table: the person or the couple when seated, or
  a circle's seated members (the wedding party's derived ones included). `[]` makes the
  pin inactive (SEAT-43).
  """
  @spec pinned_parties(Seating.t(), Pin.t()) :: [Seating.party()]
  def pinned_parties(analysis, %Pin{} = pin) do
    case Pin.side(pin) do
      {:circle, id} -> Map.get(analysis.circle_members, id, [])
      side -> if Map.has_key?(analysis.unit_index, side), do: [side], else: []
    end
  end

  @doc "The pins that seat nobody in this scenario (SEAT-43)."
  @spec inactive_pins(Seating.t(), [Pin.t()]) :: [Pin.t()]
  def inactive_pins(analysis, pins), do: Enum.filter(pins, &(pinned_parties(analysis, &1) == []))

  # Per seating unit, the fixed tables its active pins put it at — pinning anyone pins
  # their whole unit (SEAT-42).
  defp unit_pins(analysis, tables, pins) do
    fixed = for t <- tables, Table.fixed?(t), into: %{}, do: {t.id, t}

    for pin <- pins,
        table = Map.get(fixed, pin.seating_table_id),
        party <- pinned_parties(analysis, pin),
        reduce: %{} do
      acc ->
        unit = Map.fetch!(analysis.unit_index, party)
        Map.update(acc, unit, [table], &Enum.uniq_by([table | &1], fn t -> t.id end))
    end
    |> Map.new(fn {unit, ts} -> {unit, Enum.sort_by(ts, &{&1.sort_order, &1.id})} end)
  end

  # Units pinned to exactly one fixed table: unit index → that table.
  defp single_pins(analysis, tables, pins) do
    for {unit, [table]} <- unit_pins(analysis, tables, pins), into: %{}, do: {unit, table}
  end

  defp unpinned_seats(analysis, pinned) do
    analysis.units
    |> Enum.with_index()
    |> Enum.reject(fn {_unit, i} -> Map.has_key?(pinned, i) end)
    |> Enum.map(fn {unit, _i} -> unit_size(unit) end)
    |> Enum.sum()
  end

  # -- how many tables (SEAT-45, D-42) ---------------------------------------------------

  @doc """
  The concrete tables a plan is laid out on (SEAT-45), for `seats` seats not pinned to a
  fixed table, using `extra` more tables than the fewest (0 unless the fewest give no
  valid plan): every fixed table — which seats only its pins (`D-44`) — plus as few
  tables of the types as hold those `seats`, within each type's limit and with the types'
  minimums not exceeding `seats`. Among equally few tables, the fewest empty seats wins, then more tables
  of the types earlier in sort order. When no count meets the minimums (too few people
  for the smallest table), the fewest tables that hold everyone are used and the search
  reports the shortfall.

  Each is a `t:plan_table/0`: fixed tables keep their own name; a type's tables are
  numbered "Round 1", "Round 2", … (skipping names a fixed table has).
  """
  @spec plan_tables([Table.t()], non_neg_integer(), non_neg_integer()) :: [plan_table()]
  def plan_tables(tables, seats, extra \\ 0) do
    {fixed, types} = Enum.split_with(tables, &Table.fixed?/1)
    counts = type_counts(types, seats, seats, extra)

    taken = MapSet.new(fixed, &String.downcase(&1.name))

    Enum.map(fixed, &plan_table(&1, "fixed-#{&1.id}", &1.name)) ++
      for {type, count} <- Enum.zip(types, counts),
          {n, i} <- numbered(type, count, taken) do
        plan_table(type, "type-#{type.id}-#{i}", "#{type.name} #{n}")
      end
  end

  # `count` numbers for `type`'s tables, as `{number, index}`, skipping any number whose
  # name a fixed table already has (SEAT-40: a frozen "Round 1" leaves "Round 2", …).
  defp numbered(_type, 0, _taken), do: []

  defp numbered(type, count, taken) do
    1
    |> Stream.iterate(&(&1 + 1))
    |> Stream.reject(&MapSet.member?(taken, String.downcase("#{type.name} #{&1}")))
    |> Enum.take(count)
    |> Enum.with_index(1)
  end

  defp plan_table(table, id, name) do
    %{id: id, name: name, min_seats: table.min_seats, max_seats: table.max_seats, source: table}
  end

  # The count per type, by dynamic programming over the types: for every (tables used,
  # maximum seats offered) the smallest minimum, and on a tie more of the earlier types.
  # Offered seats are capped at `needed` plus the largest table — more never helps — so
  # the work stays bounded however many types there are. Then the fewest tables whose
  # maximums hold `needed` and whose minimums stay within `seats`, then the fewest offered
  # seats; failing the minimums, the fewest tables that hold everyone.
  defp type_counts([], _needed, _seats, _extra), do: []

  defp type_counts(types, needed, seats, extra) do
    # Room for `extra` more tables than the fewest, each up to the largest table.
    largest = types |> Enum.map(& &1.max_seats) |> Enum.max()
    cap = needed + largest * (extra + 1)

    states =
      Enum.reduce(types, %{{0, 0} => {0, []}}, fn type, states ->
        bound = type.limit || div(cap, type.min_seats) + 1

        for {{k, max}, {min, counts}} <- states,
            n <- 0..bound,
            max + n * type.max_seats <= cap,
            reduce: %{} do
          acc ->
            key = {k + n, max + n * type.max_seats}
            candidate = {min + n * type.min_seats, [n | counts]}
            Map.update(acc, key, candidate, &preferred(&1, candidate))
        end
      end)

    holding = Enum.filter(states, fn {{_k, max}, _} -> max >= needed end)
    fitting = Enum.filter(holding, fn {_key, {min, _}} -> min <= seats end)

    case Enum.sort(if(fitting != [], do: fitting, else: holding)) do
      [{{fewest, _}, _} | _] = sorted ->
        {_key, {_min, counts}} =
          Enum.find(sorted, List.last(sorted), fn {{k, _}, _} -> k >= fewest + extra end)

        Enum.reverse(counts)

      [] ->
        Enum.map(types, &(&1.limit || 0))
    end
  end

  # The smaller minimum; on a tie more of the earlier types (counts are kept reversed).
  defp preferred({min_a, counts_a} = a, {min_b, counts_b} = b) do
    cond do
      min_a < min_b -> a
      min_b < min_a -> b
      Enum.reverse(counts_a) >= Enum.reverse(counts_b) -> a
      true -> b
    end
  end

  @doc """
  Per seated party: the parties at the same table who pull them there (`pulled_by`,
  their unit-mates first) and their soft rules this plan breaks (`broken`) — SEAT-54.
  """
  @spec explain(Seating.t(), t()) :: %{
          Seating.party() => %{pulled_by: [Seating.party()], broken: [Rule.t()]}
        }
  def explain(analysis, %{table_of: table_of, tables: tables}) do
    at_table = Map.new(tables, &{&1.table.id, &1.parties})
    broken = broken_rules(analysis, table_of)

    Map.new(table_of, fn {party, table_id} ->
      mates = Map.fetch!(at_table, table_id) -- [party]
      unit = Map.fetch!(analysis.unit_index, party)
      {own_unit, others} = Enum.split_with(mates, &(Map.fetch!(analysis.unit_index, &1) == unit))
      pulled = Enum.filter(others, &(Seating.pull(analysis, party, &1) > 0))

      {party, %{pulled_by: own_unit ++ pulled, broken: Map.get(broken, party, [])}}
    end)
  end

  # -- before searching (SEAT-61) --------------------------------------------------------

  @doc """
  The problems that stop a plan before any search (SEAT-61), `[]` when there are none:
  the analysis's blocking problems; no tables at all; people not pinned anywhere but no
  table types for them; someone pinned to two tables; a fixed table pinned beyond its
  maximum or short of its minimum; more seats needed at the table types than they offer
  (only when every type has a limit); and every unpinned unit larger than the largest
  type. The health panel shows these live; `compute/3` returns them as
  `status: :blocked`.
  """
  @spec problems_before_search(Seating.t(), [Table.t()], [Pin.t()]) :: [problem()]
  def problems_before_search(analysis, tables, pins \\ []) do
    blocking = Enum.map(analysis.blocking, &{:blocking, &1})
    units = List.to_tuple(analysis.units)
    by_unit = unit_pins(analysis, tables, pins)
    types = Enum.reject(tables, &Table.fixed?/1)

    twice =
      for {unit, [_, _ | _] = ts} <- Enum.sort(by_unit),
          do: {:pinned_twice, elem(units, unit), ts}

    pinned = for {unit, [table]} <- by_unit, into: %{}, do: {unit, table}

    fixed_load =
      for table <- tables,
          Table.fixed?(table),
          seats =
            pinned
            |> Enum.filter(fn {_u, t} -> t.id == table.id end)
            |> Enum.map(fn {u, _} -> unit_size(elem(units, u)) end)
            |> Enum.sum(),
          problem <- fixed_problem(table, seats),
          do: problem

    free_units =
      analysis.units
      |> Enum.with_index()
      |> Enum.reject(fn {_u, i} -> Map.has_key?(by_unit, i) end)
      |> Enum.map(&elem(&1, 0))

    needed = free_units |> Enum.map(&unit_size/1) |> Enum.sum()
    available = types_capacity(types)
    largest = types |> Enum.map(& &1.max_seats) |> Enum.max(fn -> 0 end)

    too_large =
      for unit <- free_units,
          size = unit_size(unit),
          types != [],
          size > largest,
          do: {:unit_too_large, unit, size, largest}

    seats =
      cond do
        tables == [] and analysis.parties != [] -> [:no_tables]
        tables == [] -> []
        free_units != [] and types == [] -> [{:no_table_types, needed}]
        available != :unlimited and needed > available -> [{:too_many_seats, needed, available}]
        true -> []
      end

    blocking ++ twice ++ fixed_load ++ seats ++ too_large
  end

  defp fixed_problem(_table, 0), do: []

  defp fixed_problem(table, seats) when seats > table.max_seats,
    do: [{:pinned_above_maximum, table, seats}]

  defp fixed_problem(table, seats) when seats < table.min_seats,
    do: [{:pinned_below_minimum, table, seats}]

  defp fixed_problem(_table, _seats), do: []

  defp types_capacity(types) do
    if Enum.any?(types, &is_nil(&1.limit)),
      do: :unlimited,
      else: types |> Enum.map(&(&1.max_seats * &1.limit)) |> Enum.sum()
  end

  @doc """
  All the seats `tables` can offer: the fixed tables' maximums plus every type's limit
  times its maximum — `:unlimited` as soon as one type has no limit (SEAT-61).
  """
  @spec available_seats([Table.t()]) :: non_neg_integer() | :unlimited
  def available_seats(tables) do
    {fixed, types} = Enum.split_with(tables, &Table.fixed?/1)

    case types_capacity(types) do
      :unlimited -> :unlimited
      n -> n + (fixed |> Enum.map(& &1.max_seats) |> Enum.sum())
    end
  end

  defp unit_size(unit), do: unit |> Enum.map(&Seating.party_seats/1) |> Enum.sum()

  # -- search ----------------------------------------------------------------------------

  defp search(analysis, tables, pinned) do
    problem = build_problem(analysis, tables, pinned)

    best =
      if problem.n == 0,
        do: %{assign: %{}, score: 0},
        else: anneal(problem)

    result(analysis, tables, problem, best.assign)
  end

  # `pinned`: unit index → its fixed table. In the problem, `pinned` maps a unit to that
  # table's index, and `free` lists the indices of the types' tables — the only ones an
  # unpinned unit may sit at (`D-44`).
  defp build_problem(analysis, tables, pinned) do
    index_of = tables |> Enum.with_index() |> Map.new(fn {t, i} -> {t.id, i} end)

    pinned_at =
      Map.new(pinned, fn {unit, table} -> {unit, Map.fetch!(index_of, "fixed-#{table.id}")} end)

    free =
      for {t, i} <- Enum.with_index(tables), not Table.fixed?(t.source), do: i

    # SEAT-52's lone members: per circle or group its weight and seated size, and per unit
    # how many of its members belong to each.
    sets_info =
      analysis.cohesion_sets |> Enum.map(fn {w, ps} -> {w, length(ps)} end) |> List.to_tuple()

    unit_sets =
      analysis.cohesion_sets
      |> Enum.with_index()
      |> Enum.flat_map(fn {{_w, parties}, g} ->
        parties
        |> Enum.frequencies_by(&Map.fetch!(analysis.unit_index, &1))
        |> Enum.map(fn {unit, count} -> {unit, {g, count}} end)
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    unit_sets =
      for u <- 0..(length(analysis.units) - 1)//1, into: %{}, do: {u, Map.get(unit_sets, u, [])}

    units = List.to_tuple(analysis.units)
    n = tuple_size(units)

    unit_pairs =
      Enum.reduce(analysis.pulls, %{}, fn {{a, b}, value}, acc ->
        {i, j} = {Map.fetch!(analysis.unit_index, a), Map.fetch!(analysis.unit_index, b)}

        if i == j,
          do: acc,
          else:
            Map.update(acc, key(i, j), {value, value > 0}, fn {w, pos} ->
              {w + value, pos or value > 0}
            end)
      end)

    never =
      for {a, b} <- analysis.never_with,
          {i, j} = {Map.fetch!(analysis.unit_index, a), Map.fetch!(analysis.unit_index, b)},
          i != j,
          into: MapSet.new(),
          do: key(i, j)

    %{
      n: n,
      m: length(tables),
      sizes: units |> Tuple.to_list() |> Enum.map(&unit_size/1) |> List.to_tuple(),
      fine: units |> Tuple.to_list() |> Enum.map(&fine_unit?(&1, analysis)) |> List.to_tuple(),
      pairs: unit_pairs,
      never: never,
      mins: tables |> Enum.map(& &1.min_seats) |> List.to_tuple(),
      maxs: tables |> Enum.map(& &1.max_seats) |> List.to_tuple(),
      pinned: pinned_at,
      sets: sets_info,
      unit_sets: unit_sets,
      free: free,
      free_tuple: List.to_tuple(free)
    }
  end

  defp fine_unit?(unit, analysis) do
    Enum.all?(unit, fn
      :couple -> false
      {:person, id} -> analysis.persons[id].fine_anywhere
    end)
  end

  defp key(i, j) when i < j, do: {i, j}
  defp key(i, j), do: {j, i}

  # A table's score from its members (unit indices): its fit minus the hard penalties.
  # A table's {fit, never, capacity}: the fit is its pulls minus its strangers (SEAT-52);
  # `never` counts pairs under *never with*; `capacity` the seats below its minimum or
  # above its maximum (an empty table has none, SEAT-41).
  defp table_parts(_problem, _t, []), do: {0, 0, 0}

  defp table_parts(problem, t, members) do
    seats = Enum.reduce(members, 0, &(elem(problem.sizes, &1) + &2))
    capacity = max(0, seats - elem(problem.maxs, t)) + max(0, elem(problem.mins, t) - seats)

    {pull, never, positive} =
      for i <- members, j <- members, i < j, reduce: {0, 0, MapSet.new()} do
        {pull, never, positive} ->
          {w, pos} = Map.get(problem.pairs, {i, j}, {0, false})
          never = if MapSet.member?(problem.never, {i, j}), do: never + 1, else: never
          positive = if pos, do: positive |> MapSet.put(i) |> MapSet.put(j), else: positive
          {pull + w, never, positive}
      end

    strangers =
      Enum.count(members, &(not elem(problem.fine, &1) and not MapSet.member?(positive, &1)))

    {pull - strangers * @stranger - lone_members(problem, members), never, capacity}
  end

  # A unit that is the only one of its circle or group at the table, while others of it
  # sit elsewhere, costs the set's weight for each of them elsewhere (SEAT-52): six
  # colleagues split 5 + 1 lose more than 4 + 2.
  defp lone_members(problem, members) do
    members
    |> Enum.flat_map(&Map.fetch!(problem.unit_sets, &1))
    |> Enum.reduce(%{}, fn {g, count}, acc ->
      Map.update(acc, g, {1, count}, fn {units, parties} -> {units + 1, parties + count} end)
    end)
    |> Enum.reduce(0, fn
      {g, {1, here}}, acc ->
        {weight, total} = elem(problem.sets, g)
        acc + weight * (total - here)

      _, acc ->
        acc
    end)
  end

  # Seat limits are walls: the start respects them whenever the units allow it, and no
  # move may add a seat outside a table's bounds — swaps of equal-sized units keep every
  # count, so the search still moves freely. *Never with* is a penalty whose weight ramps
  # from low to `@hard`, so early on the search may pass through a plan that breaks one on
  # its way to a better one; by the end a broken rule outweighs any fit.
  defp anneal(problem) do
    assign = greedy(problem)
    members = members_by_table(assign, problem.m)
    parts = Map.new(members, fn {t, ms} -> {t, table_parts(problem, t, ms)} end)
    {fit, never, capacity} = sum_parts(Map.values(parts))
    steps = problem.n |> Kernel.*(@steps_per_unit) |> max(@min_steps) |> min(@max_steps)

    state = %{
      assign: assign,
      members: members,
      parts: parts,
      fit: fit,
      never: never,
      capacity: capacity
    }

    rand = :rand.seed_s(:exsss, @seed)
    schedule = %{steps: steps, cooling: :math.pow(@t_end / @t_start, 1 / steps)}

    initial = {state, best_of(state), rand, @t_start}

    {_state, best, _rand, _temp} =
      Enum.reduce(1..steps, initial, &step(problem, schedule, &1, &2))

    best
  end

  defp step(problem, schedule, i, {state, best, rand, temp}) do
    weight = @hard_start * :math.pow(@hard / @hard_start, i / schedule.steps)
    {candidate, rand} = propose(problem, state, rand)
    {state, rand} = accept(state, candidate, weight, temp, rand)
    best = if better?(state, best), do: best_of(state), else: best
    {state, best, rand, temp * schedule.cooling}
  end

  # Fewest broken hard constraints first, then the best fit.
  defp better?(state, best),
    do: {-(state.capacity + state.never), state.fit} > {-(best.capacity + best.never), best.fit}

  defp best_of(state), do: Map.take(state, [:assign, :fit, :never, :capacity])

  defp sum_parts(parts) do
    Enum.reduce(parts, {0, 0, 0}, fn {fit, never, capacity}, {f, n, c} ->
      {f + fit, n + never, c + capacity}
    end)
  end

  # The start: open the fewest tables (in sort order) whose maximums hold everyone, then
  # place the largest units first, each at the open table where it fits best — ties to
  # the emptier table, then the lower index. While the seats still to place only just
  # cover the open tables' shortfall below their minimums, only short tables are
  # candidates, so the minimums are met whenever the unit sizes allow it. A unit only goes
  # to an unopened table, or overfills one, when no open table has room.
  defp greedy(problem) do
    tables = problem.free
    open = open_tables(problem, tables)

    order =
      0..(problem.n - 1)
      |> Enum.reject(&Map.has_key?(problem.pinned, &1))
      |> Enum.sort_by(&{-elem(problem.sizes, &1), &1})

    total = Enum.sum(for u <- order, do: elem(problem.sizes, u))
    empty = Map.new(0..(problem.m - 1), &{&1, {[], 0}})

    # Pinned units first, at their fixed tables (D-44).
    {assign, empty} =
      Enum.reduce(problem.pinned, {%{}, empty}, fn {unit, t}, {assign, members} ->
        size = elem(problem.sizes, unit)

        {Map.put(assign, unit, t),
         Map.update!(members, t, fn {ms, seats} -> {[unit | ms], seats + size} end)}
      end)

    {assign, _members, _left} =
      Enum.reduce(order, {assign, empty, total}, fn unit, {assign, members, left} ->
        size = elem(problem.sizes, unit)
        seats = fn t -> elem(Map.fetch!(members, t), 1) end
        fits = fn t -> seats.(t) + size <= elem(problem.maxs, t) end
        short = fn t -> seats.(t) < elem(problem.mins, t) end
        shortfall = Enum.sum(for t <- open, do: max(0, elem(problem.mins, t) - seats.(t)))

        candidates =
          [
            if(left <= shortfall, do: Enum.filter(open, &(fits.(&1) and short.(&1))), else: []),
            Enum.filter(open, fits),
            Enum.filter(tables, fits),
            tables
          ]
          |> Enum.find([], &(&1 != []))

        table =
          Enum.max_by(candidates, fn t ->
            {current, seats} = Map.fetch!(members, t)
            {gain(problem, t, unit, current), -seats, -t}
          end)

        {Map.put(assign, unit, table),
         Map.update!(members, table, fn {ms, seats} -> {[unit | ms], seats + size} end),
         left - size}
      end)

    assign
  end

  defp open_tables(problem, tables) do
    needed =
      for u <- 0..(problem.n - 1)//1,
          not Map.has_key?(problem.pinned, u),
          reduce: 0,
          do: (acc -> acc + elem(problem.sizes, u))

    tables
    |> Enum.reduce_while({[], 0}, fn t, {open, capacity} ->
      if capacity >= needed,
        do: {:halt, {open, capacity}},
        else: {:cont, {[t | open], capacity + elem(problem.maxs, t)}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # What adding `unit` does to the table's fit (hard constraints are the search's job).
  defp gain(problem, t, unit, current) do
    {with_unit, _, _} = table_parts(problem, t, [unit | current])
    {without, _, _} = table_parts(problem, t, current)
    with_unit - without
  end

  defp members_by_table(assign, m) do
    base = Map.new(0..(m - 1)//1, &{&1, []})

    assign
    |> Enum.sort()
    |> Enum.reduce(base, fn {unit, t}, acc -> Map.update!(acc, t, &[unit | &1]) end)
  end

  defp propose(%{m: 1} = _problem, state, rand), do: {nil_move(state), rand}

  # Pinned units never move; an unpinned one moves only between the types' tables.
  defp propose(problem, state, rand) do
    {r, rand} = :rand.uniform_s(rand)
    {unit, rand} = uniform(problem.n, rand)
    from = Map.fetch!(state.assign, unit)

    cond do
      Map.has_key?(problem.pinned, unit) or problem.free == [] ->
        {nil_move(state), rand}

      r < 0.5 or problem.n < 2 ->
        {i, rand} = uniform(tuple_size(problem.free_tuple), rand)
        to = elem(problem.free_tuple, i)

        if to == from,
          do: {nil_move(state), rand},
          else: {move(problem, state, [{unit, from, to}]), rand}

      true ->
        {other, rand} = uniform(problem.n, rand)
        other_table = Map.fetch!(state.assign, other)

        if other_table == from or Map.has_key?(problem.pinned, other),
          do: {nil_move(state), rand},
          else:
            {move(problem, state, [{unit, from, other_table}, {other, other_table, from}]), rand}
    end
  end

  defp nil_move(state), do: %{state: state, fit: 0, never: 0, capacity: 0}

  defp move(problem, state, moves) do
    members =
      Enum.reduce(moves, state.members, fn {unit, from, to}, members ->
        members |> Map.update!(from, &List.delete(&1, unit)) |> Map.update!(to, &[unit | &1])
      end)

    touched = moves |> Enum.flat_map(fn {_u, from, to} -> [from, to] end) |> Enum.uniq()
    new_parts = Map.new(touched, &{&1, table_parts(problem, &1, Map.fetch!(members, &1))})
    {new_fit, new_never, new_capacity} = sum_parts(Map.values(new_parts))

    {old_fit, old_never, old_capacity} =
      sum_parts(for t <- touched, do: Map.fetch!(state.parts, t))

    assign = Enum.reduce(moves, state.assign, fn {unit, _from, to}, a -> Map.put(a, unit, to) end)

    {fit, never, capacity} =
      {new_fit - old_fit, new_never - old_never, new_capacity - old_capacity}

    %{
      state: %{
        assign: assign,
        members: members,
        parts: Map.merge(state.parts, new_parts),
        fit: state.fit + fit,
        never: state.never + never,
        capacity: state.capacity + capacity
      },
      fit: fit,
      never: never,
      capacity: capacity
    }
  end

  # The wall: never accept a move that puts a seat outside a table's bounds.
  defp accept(state, %{capacity: capacity}, _weight, _temp, rand) when capacity > 0,
    do: {state, rand}

  defp accept(state, candidate, weight, temp, rand) do
    delta = candidate.fit - weight * (candidate.never + candidate.capacity)

    if delta >= 0 do
      {candidate.state, rand}
    else
      {r, rand} = :rand.uniform_s(rand)
      if r < :math.exp(delta / temp), do: {candidate.state, rand}, else: {state, rand}
    end
  end

  defp uniform(n, rand) do
    {r, rand} = :rand.uniform_s(n, rand)
    {r - 1, rand}
  end

  # -- result ----------------------------------------------------------------------------

  defp result(analysis, tables, problem, assign) do
    units = List.to_tuple(analysis.units)
    members = members_by_table(assign, problem.m)
    order = analysis.parties |> Enum.with_index() |> Map.new()

    table_results =
      for {table, t} <- Enum.with_index(tables) do
        unit_ids = Map.fetch!(members, t)

        parties =
          unit_ids |> Enum.flat_map(&elem(units, &1)) |> Enum.sort_by(&Map.fetch!(order, &1))

        %{
          table: table,
          parties: parties,
          seats: Enum.reduce(unit_ids, 0, &(elem(problem.sizes, &1) + &2)),
          score: problem |> table_parts(t, unit_ids) |> elem(0)
        }
      end

    table_of =
      for %{table: table, parties: parties} <- table_results,
          party <- parties,
          into: %{},
          do: {party, table.id}

    problems = violations(analysis, table_results, table_of)

    pinned =
      for {unit, _t} <- problem.pinned, party <- elem(units, unit), into: MapSet.new(), do: party

    %{
      status: if(problems == [], do: :ok, else: :invalid),
      problems: problems,
      tables: table_results,
      table_of: table_of,
      pinned: pinned
    }
  end

  defp violations(analysis, table_results, table_of) do
    capacity =
      Enum.flat_map(table_results, fn
        %{seats: 0} -> []
        %{table: t, seats: s} when s < t.min_seats -> [{:below_minimum, t, s}]
        %{table: t, seats: s} when s > t.max_seats -> [{:above_maximum, t, s}]
        _ -> []
      end)

    tables = Map.new(table_results, &{&1.table.id, &1.table})

    never =
      for {a, b} <- Enum.sort(analysis.never_with),
          Map.fetch!(table_of, a) == Map.fetch!(table_of, b),
          do: {:never_with_together, Map.fetch!(tables, Map.fetch!(table_of, a)), a, b}

    capacity ++ never
  end

  defp broken?(:seat_with, together?), do: not together?
  defp broken?(:keep_apart, together?), do: together?

  defp broken_rules(analysis, table_of) do
    for {rule, {a, b}} <- analysis.soft_pairs,
        broken?(rule.relation, Map.fetch!(table_of, a) == Map.fetch!(table_of, b)),
        party <- [a, b],
        reduce: %{} do
      acc -> Map.update(acc, party, [rule], &Enum.uniq([rule | &1]))
    end
    |> Map.new(fn {party, rules} -> {party, Enum.sort_by(rules, & &1.id)} end)
  end
end
