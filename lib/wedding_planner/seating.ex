defmodule WeddingPlanner.Seating do
  @moduledoc """
  The seating inputs that hold across every event (`docs/modules/seating.md` SEAT-20..
  SEAT-35, SEAT-80, SEAT-81): circles, their members and seating rules. Resources
  `:circle` and `:seating_rule`, entity types `"circle"` and `"seating_rule"`. Follows
  `WeddingPlanner.Events`'s exemplar pattern: every write is logged (`XC-10`) and
  broadcast (`XC-01`) only after it succeeds.

  The plan and its health are computed, never stored (SEAT-50) — that is
  `WeddingPlanner.Valuation.Seating`. *Fine anywhere* (SEAT-35) is a person field, so it
  is written through `WeddingPlanner.Guests.update_person/3`.

  ## Membership

  `add_member/3`, `add_group_members/3` and `remove_member/3` write
  `WeddingPlanner.Seating.CircleMembership` rows, logged against the **circle** ("Wannes
  added 'Anna Peeters' to 'Uni friends'"), and broadcast the circle as `{:updated,
  circle}` with its members preloaded — membership is part of what a circle is on screen.
  Adding a whole group is a bulk action (`XC-12`): one summary, one child per person
  added; people already in the circle are skipped.

  ## Rules

  A rule's sides are checked to exist here (`validate_sides_exist/1`), not by a foreign
  key, for the reason `WeddingPlanner.Guests`'s moduledoc gives. Each rule is described
  in the log as a sentence: "Wannes added the rule 'Jan Peeters' never with 'Mia
  Peeters'".

  ## Deletion (SEAT-81, `XC-40`)

  `delete_circle/2` removes the circle's memberships and every rule mentioning it, in one
  `Log.action/3` with a child entry per removed rule. Deleting a person removes their
  memberships and rules too: `WeddingPlanner.Guests` calls `delete_for_persons/1` inside
  its own transaction, and names what goes in its confirmation through
  `deletion_counts/1`, the same contract `WeddingPlanner.Invitations` offers.
  """

  import Ecto.Query

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Accounts.Users
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Group
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Log
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Seating.Circle
  alias WeddingPlanner.Seating.CircleMembership
  alias WeddingPlanner.Seating.Pin
  alias WeddingPlanner.Seating.Rule
  alias WeddingPlanner.Seating.Table

  @circle_resource :circle
  @table_resource :seating_table
  @rule_resource :seating_rule
  @pin_resource :seating_pin

  @type deletion_counts :: %{
          memberships: non_neg_integer(),
          rules: non_neg_integer(),
          pins: non_neg_integer()
        }

  # -- circles ---------------------------------------------------------------------------

  @doc "Every circle with its members, by name (case-insensitive, Unicode-aware), then id."
  @spec list_circles() :: [Circle.t()]
  def list_circles do
    Circle
    |> Repo.all()
    |> Repo.preload(members: :host)
    |> Enum.sort_by(&{String.downcase(&1.name), &1.id})
  end

  @doc "One circle with its members. Raises if it does not exist."
  @spec get_circle!(term()) :: Circle.t()
  def get_circle!(id), do: Circle |> Repo.get!(id) |> Repo.preload(members: :host)

  @doc "A changeset for building/validating a circle form — never persists on its own."
  @spec change_circle(Circle.t(), map()) :: Ecto.Changeset.t()
  def change_circle(%Circle{} = circle, attrs \\ %{}), do: Circle.changeset(circle, attrs)

  @doc "Creates a circle (SEAT-20, SEAT-21), logs it and broadcasts `{:created, circle}`."
  @spec create_circle(Scope.t(), map()) :: {:ok, Circle.t()} | {:error, Ecto.Changeset.t()}
  def create_circle(%Scope{} = scope, attrs) do
    with {:ok, circle} <- %Circle{} |> Circle.changeset(attrs) |> Repo.insert() do
      {:ok, _} =
        Log.entry(
          scope,
          {:circle, circle.id},
          "#{actor(scope)} created circle '#{circle.name}' (#{cohesion(circle)})"
        )

      circle = Repo.preload(circle, members: :host)
      Realtime.broadcast_change(@circle_resource, {:created, circle})
      {:ok, circle}
    end
  end

  @doc "Renames a circle or changes its cohesion; one log entry per changed field."
  @spec update_circle(Scope.t(), Circle.t(), map()) ::
          {:ok, Circle.t()} | {:error, Ecto.Changeset.t()}
  def update_circle(%Scope{} = scope, %Circle{} = circle, attrs) do
    changeset = Circle.changeset(circle, attrs)

    with {:ok, updated} <- Repo.update(changeset) do
      if Map.has_key?(changeset.changes, :name) do
        {:ok, _} =
          Log.entry(
            scope,
            {:circle, updated.id},
            "#{actor(scope)} renamed circle '#{circle.name}' to '#{updated.name}'"
          )
      end

      if Map.has_key?(changeset.changes, :cohesion) do
        {:ok, _} =
          Log.entry(
            scope,
            {:circle, updated.id},
            "#{actor(scope)} changed the cohesion of '#{updated.name}': #{cohesion(circle)} → #{cohesion(updated)}"
          )
      end

      updated = Repo.preload(updated, [members: :host], force: true)
      Realtime.broadcast_change(@circle_resource, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc """
  What deleting `circle` also removes (SEAT-81, `XC-40`), in
  `WeddingPlannerWeb.CoreComponents.destructive_confirm/1`'s shape: its rules and its
  pins, each present only when non-zero. Its members are not deleted, only taken out.
  """
  @spec circle_deletion_effects(Circle.t()) :: [%{label: String.t(), count: non_neg_integer()}]
  def circle_deletion_effects(%Circle{} = circle) do
    rules = circle |> rules_mentioning() |> length()
    pins = Pin |> where([p], p.circle_id == ^circle.id) |> Repo.aggregate(:count)

    [
      {rules, "Also deletes #{rules} #{rules_word(rules)}"},
      {pins, "Also removes #{pins} #{plural(pins, "pin", "pins")}"}
    ]
    |> Enum.reject(fn {n, _label} -> n == 0 end)
    |> Enum.map(fn {n, label} -> %{label: label, count: n} end)
  end

  @doc """
  Deletes a circle, its memberships, its pins and every rule that mentions it (SEAT-81),
  in one `Log.action/3`: a summary, then one child per removed rule and pin. Broadcasts
  each removal and the circle's after commit. The wedding party is built in and cannot be
  deleted (SEAT-24): `{:error, :built_in}`.
  """
  @spec delete_circle(Scope.t(), Circle.t()) :: {:ok, Circle.t()} | {:error, :built_in}
  def delete_circle(%Scope{}, %Circle{role: :wedding_party}), do: {:error, :built_in}

  def delete_circle(%Scope{} = scope, %Circle{} = circle) do
    rules = rules_mentioning(circle)
    descriptions = Map.new(rules, &{&1.id, describe(&1)})

    pins =
      Pin |> where([p], p.circle_id == ^circle.id) |> Repo.all() |> Repo.preload(:seating_table)

    {:ok, deleted} =
      Log.action(scope, "#{actor(scope)} deleted circle '#{circle.name}'", fn ->
        Enum.each(rules, fn rule ->
          {:ok, _} = Repo.delete(rule)

          {:ok, _} =
            Log.entry(
              scope,
              {:seating_rule, rule.id},
              "#{actor(scope)} deleted the rule #{Map.fetch!(descriptions, rule.id)} (circle deleted)"
            )
        end)

        Enum.each(pins, fn pin ->
          {:ok, _} = Repo.delete(pin)

          {:ok, _} =
            Log.entry(
              scope,
              {:seating_table, pin.seating_table_id},
              "#{actor(scope)} unpinned '#{circle.name}' from '#{pin.seating_table.name}' (circle deleted)"
            )
        end)

        _ = CircleMembership |> where([m], m.circle_id == ^circle.id) |> Repo.delete_all()
        {:ok, deleted} = Repo.delete(circle)
        deleted
      end)

    Enum.each(rules, &Realtime.broadcast_change(@rule_resource, {:deleted, &1.id}))
    Enum.each(pins, &Realtime.broadcast_change(@pin_resource, {:deleted, &1.id}))
    Realtime.broadcast_change(@circle_resource, {:deleted, deleted.id})
    {:ok, deleted}
  end

  # -- membership ------------------------------------------------------------------------

  @doc """
  Adds `person` to `circle` (SEAT-20). Adding someone already in it is a no-op that
  writes and logs nothing.
  """
  @spec add_member(Scope.t(), Circle.t(), Person.t()) :: {:ok, Circle.t()}
  def add_member(%Scope{} = scope, %Circle{} = circle, %Person{} = person) do
    if member?(circle, person) do
      {:ok, get_circle!(circle.id)}
    else
      {:ok, _} = insert_membership(circle, person)

      {:ok, _} =
        Log.entry(
          scope,
          {:circle, circle.id},
          "#{actor(scope)} added '#{name(person)}' to '#{circle.name}'"
        )

      broadcast_circle(circle)
    end
  end

  @doc """
  Adds every member of `group` not yet in `circle`, as one bulk action (`XC-12`): a
  summary plus one child per person added. A no-op when nobody is left to add.
  """
  @spec add_group_members(Scope.t(), Circle.t(), Group.t()) :: {:ok, Circle.t()}
  def add_group_members(%Scope{} = scope, %Circle{} = circle, %Group{} = group) do
    present = circle |> member_ids() |> MapSet.new()

    to_add =
      Person
      |> where([p], p.group_id == ^group.id)
      |> Repo.all()
      |> Repo.preload(:host)
      |> Enum.reject(&MapSet.member?(present, &1.id))
      |> Enum.sort_by(&{String.downcase(name(&1)), &1.id})

    if to_add == [] do
      {:ok, get_circle!(circle.id)}
    else
      count = length(to_add)

      summary =
        "#{actor(scope)} added #{count} #{people_word(count)} from group '#{group.name}' to '#{circle.name}'"

      {:ok, _} =
        Log.action(scope, summary, fn ->
          Enum.each(to_add, fn person ->
            {:ok, _} = insert_membership(circle, person)

            {:ok, _} =
              Log.entry(
                scope,
                {:circle, circle.id},
                "#{actor(scope)} added '#{name(person)}' to '#{circle.name}'"
              )
          end)
        end)

      broadcast_circle(circle)
    end
  end

  @doc "Takes `person` out of `circle`; a no-op when they are not in it."
  @spec remove_member(Scope.t(), Circle.t(), Person.t()) :: {:ok, Circle.t()}
  def remove_member(%Scope{} = scope, %Circle{} = circle, %Person{} = person) do
    {count, _} =
      CircleMembership
      |> where([m], m.circle_id == ^circle.id and m.person_id == ^person.id)
      |> Repo.delete_all()

    if count == 0 do
      {:ok, get_circle!(circle.id)}
    else
      {:ok, _} =
        Log.entry(
          scope,
          {:circle, circle.id},
          "#{actor(scope)} removed '#{name(person)}' from '#{circle.name}'"
        )

      broadcast_circle(circle)
    end
  end

  # -- rules -----------------------------------------------------------------------------

  @doc "Every seating rule, oldest first."
  @spec list_rules() :: [Rule.t()]
  def list_rules, do: Rule |> order_by([r], asc: r.id) |> Repo.all()

  @doc "One rule. Raises if it does not exist."
  @spec get_rule!(term()) :: Rule.t()
  def get_rule!(id), do: Repo.get!(Rule, id)

  @doc """
  A changeset for building/validating a rule form — never persists on its own. Adds the
  existence check of both sides on top of `Rule.changeset/2`.
  """
  @spec change_rule(Rule.t(), map()) :: Ecto.Changeset.t()
  def change_rule(%Rule{} = rule, attrs \\ %{}) do
    rule
    |> Rule.with_form_fields()
    |> Rule.changeset(attrs)
    |> validate_sides_exist()
  end

  @doc "Creates a rule (SEAT-30, SEAT-31), logs it and broadcasts `{:created, rule}`."
  @spec create_rule(Scope.t(), map()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def create_rule(%Scope{} = scope, attrs) do
    with {:ok, rule} <- %Rule{} |> change_rule(attrs) |> Repo.insert() do
      {:ok, _} =
        Log.entry(
          scope,
          {:seating_rule, rule.id},
          "#{actor(scope)} added the rule #{describe(rule)}" <> reason_suffix(rule)
        )

      Realtime.broadcast_change(@rule_resource, {:created, rule})
      {:ok, rule}
    end
  end

  @doc """
  Changes a rule's sides, relation or reason. Logs one entry describing the rule before
  and after, when anything changed.
  """
  @spec update_rule(Scope.t(), Rule.t(), map()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def update_rule(%Scope{} = scope, %Rule{} = rule, attrs) do
    changeset = change_rule(rule, attrs)
    stored = Map.drop(changeset.changes, [:subject, :object])

    with {:ok, updated} <- Repo.update(changeset) do
      if stored != %{} do
        {:ok, _} =
          Log.entry(
            scope,
            {:seating_rule, updated.id},
            "#{actor(scope)} changed the rule #{describe(rule)} to #{describe(updated)}" <>
              reason_suffix(updated)
          )
      end

      Realtime.broadcast_change(@rule_resource, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc "Deletes a rule, logs it and broadcasts `{:deleted, id}`."
  @spec delete_rule(Scope.t(), Rule.t()) :: {:ok, Rule.t()}
  def delete_rule(%Scope{} = scope, %Rule{} = rule) do
    description = describe(rule)
    {:ok, deleted} = Repo.delete(rule)

    {:ok, _} =
      Log.entry(
        scope,
        {:seating_rule, deleted.id},
        "#{actor(scope)} deleted the rule #{description}"
      )

    Realtime.broadcast_change(@rule_resource, {:deleted, deleted.id})
    {:ok, deleted}
  end

  @doc """
  A rule as a sentence: `'Jan Peeters' never with 'Mia Peeters'`. Reads the names of its
  sides, so it reflects renames.
  """
  @spec describe(Rule.t()) :: String.t()
  def describe(%Rule{} = rule) do
    "#{quoted_side(Rule.side_a(rule))} #{Rule.relation_label(rule.relation)} #{quoted_side(Rule.side_b(rule))}"
  end

  @doc """
  The couple's name (SEAT-03): the users' display names joined with " & ", in display
  name order — "the couple" only while no user has a passkey yet.
  """
  @spec couple_name() :: String.t()
  def couple_name do
    case Users.list_assignable() do
      [] -> "the couple"
      users -> Enum.map_join(users, " & ", & &1.display_name)
    end
  end

  # -- tables (SEAT-40, SEAT-41) ----------------------------------------------------------

  @doc "Every table of the event with `event_id`, in sort order, then id."
  @spec list_tables(term()) :: [Table.t()]
  def list_tables(event_id) do
    Table
    |> where([t], t.event_id == ^event_id)
    |> order_by([t], asc: t.sort_order, asc: t.id)
    |> Repo.all()
  end

  @doc "One table. Raises if it does not exist."
  @spec get_table!(term()) :: Table.t()
  def get_table!(id), do: Repo.get!(Table, id)

  @doc "A changeset for building/validating a table form — never persists on its own."
  @spec change_table(Table.t(), map()) :: Ecto.Changeset.t()
  def change_table(%Table{} = table, attrs \\ %{}), do: Table.changeset(table, attrs)

  @doc """
  Adds a table type or a fixed table (SEAT-40) to `event`, after its last one; logs and
  broadcasts it.
  """
  @spec create_table(Scope.t(), Event.t(), map()) ::
          {:ok, Table.t()} | {:error, Ecto.Changeset.t()}
  def create_table(%Scope{} = scope, %Event{} = event, attrs) do
    %Table{event_id: event.id, sort_order: next_table_sort_order(event.id)}
    |> Table.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, table} ->
        {:ok, _} =
          Log.entry(scope, {:seating_table, table.id}, created_table_entry(scope, table, event))

        Realtime.broadcast_change(@table_resource, {:created, table})
        {:ok, table}

      error ->
        error
    end
  end

  @doc "Changes a table type or fixed table; one log entry describing it before and after."
  @spec update_table(Scope.t(), Table.t(), map()) ::
          {:ok, Table.t()} | {:error, Ecto.Changeset.t()}
  def update_table(%Scope{} = scope, %Table{} = table, attrs) do
    changeset = Table.changeset(table, attrs)

    with {:ok, updated} <- Repo.update(changeset) do
      if changeset.changes != %{} do
        {:ok, _} =
          Log.entry(
            scope,
            {:seating_table, updated.id},
            "#{actor(scope)} changed #{describe_table(table)} to #{describe_table(updated)}"
          )
      end

      Realtime.broadcast_change(@table_resource, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc "Deletes a table, logs it and broadcasts `{:deleted, id}`."
  @spec delete_table(Scope.t(), Table.t()) :: {:ok, Table.t()}
  def delete_table(%Scope{} = scope, %Table{} = table) do
    pins = Pin |> where([p], p.seating_table_id == ^table.id) |> Repo.all()

    suffix =
      if pins == [],
        do: "",
        else: " (#{length(pins)} #{plural(length(pins), "pin", "pins")} removed)"

    {:ok, deleted} =
      Repo.transaction(fn ->
        _ = Pin |> where([p], p.seating_table_id == ^table.id) |> Repo.delete_all()
        {:ok, deleted} = Repo.delete(table)
        deleted
      end)

    {:ok, _} =
      Log.entry(
        scope,
        {:seating_table, deleted.id},
        "#{actor(scope)} deleted #{describe_table(table)}#{suffix}"
      )

    Enum.each(pins, &Realtime.broadcast_change(@pin_resource, {:deleted, &1.id}))
    Realtime.broadcast_change(@table_resource, {:deleted, deleted.id})
    {:ok, deleted}
  end

  @doc "What deleting `table` also removes: its pins (SEAT-81, `XC-40`)."
  @spec table_deletion_effects(Table.t()) :: [%{label: String.t(), count: non_neg_integer()}]
  def table_deletion_effects(%Table{} = table) do
    case Pin |> where([p], p.seating_table_id == ^table.id) |> Repo.aggregate(:count) do
      0 -> []
      n -> [%{label: "Also removes #{n} #{plural(n, "pin", "pins")}", count: n}]
    end
  end

  # -- pins (SEAT-42, D-44) ----------------------------------------------------------------

  @doc "Every pin of the event with `event_id`, oldest first."
  @spec list_pins(term()) :: [Pin.t()]
  def list_pins(event_id) do
    Pin
    |> join(:inner, [p], t in Table, on: t.id == p.seating_table_id)
    |> where([_p, t], t.event_id == ^event_id)
    |> order_by([p], asc: p.id)
    |> Repo.all()
  end

  @doc """
  Pins `side_key` (a `Rule.side_key/1`: a person, the couple or a circle) to `table`,
  which must be a fixed table (SEAT-42). Pinning the same side to the same table twice is
  a no-op. Logged against the table ("Wannes pinned 'Wedding party' to 'Head table'") and
  broadcast.
  """
  @spec pin(Scope.t(), Table.t(), String.t()) ::
          {:ok, Pin.t()} | {:error, :not_fixed | :unknown_side}
  def pin(%Scope{}, %Table{kind: :type}, _side_key), do: {:error, :not_fixed}

  def pin(%Scope{} = scope, %Table{} = table, side_key) do
    with {:ok, side} <- Rule.parse_side(side_key),
         true <- side_exists?(side) do
      case Repo.get_by(Pin, seating_table_id: table.id, target_key: Rule.side_key(side)) do
        %Pin{} = existing ->
          {:ok, existing}

        nil ->
          {:ok, pin} = table |> Pin.new(side) |> Repo.insert()

          {:ok, _} =
            Log.entry(
              scope,
              {:seating_table, table.id},
              "#{actor(scope)} pinned #{quoted_side(side)} to '#{table.name}'"
            )

          Realtime.broadcast_change(@pin_resource, {:created, pin})
          {:ok, pin}
      end
    else
      _ -> {:error, :unknown_side}
    end
  end

  @doc "Removes a pin; logged against its table and broadcast."
  @spec unpin(Scope.t(), Pin.t()) :: {:ok, Pin.t()}
  def unpin(%Scope{} = scope, %Pin{} = pin) do
    table = Repo.get!(Table, pin.seating_table_id)
    {:ok, deleted} = Repo.delete(pin)

    {:ok, _} =
      Log.entry(
        scope,
        {:seating_table, table.id},
        "#{actor(scope)} unpinned #{quoted_side(Pin.side(pin))} from '#{table.name}'"
      )

    Realtime.broadcast_change(@pin_resource, {:deleted, deleted.id})
    {:ok, deleted}
  end

  @doc """
  Moves `side_key` to the fixed `table` (SEAT-71): pins it there, first removing its
  direct pins to other tables of the event — and those of `unit_keys`, its unit-mates,
  because pinning anyone pins their whole unit (SEAT-42) and a unit pinned to two tables
  is a blocking problem (SEAT-61). With nothing to remove it is a plain `pin/3`; otherwise
  one `Log.action/3` ("Wannes moved 'Ann' to 'Head'") with a child per removed and created
  pin. Moving to the table the side is already pinned at is a no-op.
  """
  @spec move_person(Scope.t(), Table.t(), String.t(), [String.t()]) ::
          {:ok, Pin.t()} | {:error, :not_fixed | :unknown_side}
  def move_person(scope, table, side_key, unit_keys \\ [])
  def move_person(%Scope{}, %Table{kind: :type}, _side_key, _unit_keys), do: {:error, :not_fixed}

  def move_person(%Scope{} = scope, %Table{} = table, side_key, unit_keys) do
    keys = Enum.uniq([side_key | unit_keys])

    stale =
      Pin
      |> join(:inner, [p], t in Table, on: t.id == p.seating_table_id)
      |> where([p, t], t.event_id == ^table.event_id and p.target_key in ^keys)
      |> where([p], p.seating_table_id != ^table.id)
      |> order_by([p], asc: p.id)
      |> Repo.all()
      |> Repo.preload(:seating_table)

    case stale do
      [] ->
        pin(scope, table, side_key)

      _ ->
        with {:ok, side} <- Rule.parse_side(side_key),
             true <- side_exists?(side) do
          summary = "#{actor(scope)} moved #{quoted_side(side)} to '#{table.name}'"

          {:ok, pin} =
            Log.action(scope, summary, fn ->
              Enum.each(stale, &delete_pin!(scope, &1))
              {pin, _created?} = pin!(scope, table, side)
              pin
            end)

          Enum.each(stale, &Realtime.broadcast_change(@pin_resource, {:deleted, &1.id}))
          Realtime.broadcast_change(@pin_resource, {:created, pin})
          {:ok, pin}
        else
          _ -> {:error, :unknown_side}
        end
    end
  end

  @doc """
  Freezes a table of the plan being viewed (SEAT-44, SEAT-71). `plan_table` is a
  `t:WeddingPlanner.Valuation.SeatingPlan.plan_table/0` (its `name` and `source`) and
  `side_keys` the `Rule.side_key/1` of every party seated at it in that plan.

  A fixed table keeps itself; each side not yet pinned to it directly is pinned. A table
  of a type first becomes a fixed table of the same name and seats (a name already taken
  in the event gets " (2)", " (3)"… appended), taking one from the type's limit — and
  when that was the type's last allowed table (limit 1) the type is deleted, since a
  limit cannot be 0. Everything is one transaction and one `Log.action/3` (`XC-12`), and
  broadcast after commit.

  `{:ok, %{table: table, pinned: n}}`; `{:error, :empty}` with nobody to pin;
  `{:error, changeset}` if the new fixed table is invalid.
  """
  @spec freeze_table(Scope.t(), Event.t(), map(), [String.t()]) ::
          {:ok, %{table: Table.t(), pinned: non_neg_integer()}}
          | {:error, :empty | Ecto.Changeset.t()}
  def freeze_table(%Scope{}, %Event{}, _plan_table, []), do: {:error, :empty}

  def freeze_table(%Scope{} = scope, %Event{} = event, %{name: name, source: source}, side_keys) do
    summary = "#{actor(scope)} froze '#{name}' in '#{event.name}'"
    source = Repo.get!(Table, source.id)

    result =
      Log.action(scope, summary, fn ->
        case fixed_table_for_freeze(scope, event, name, source) do
          {:ok, table, events} ->
            pins =
              for key <- Enum.uniq(side_keys),
                  {:ok, side} <- [Rule.parse_side(key)],
                  side_exists?(side),
                  {pin, true} <- [pin!(scope, table, side)],
                  do: pin

            {table, pins, events}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, {table, pins, events}} ->
        Enum.each(events, &Realtime.broadcast_change(@table_resource, &1))
        Enum.each(pins, &Realtime.broadcast_change(@pin_resource, {:created, &1}))
        {:ok, %{table: table, pinned: length(pins)}}

      {:error, %Ecto.Changeset{}} = error ->
        error
    end
  end

  # A fixed table stays as it is; a type's table becomes one (SEAT-44).
  defp fixed_table_for_freeze(_scope, _event, _name, %Table{kind: :fixed} = table),
    do: {:ok, table, []}

  defp fixed_table_for_freeze(scope, event, name, %Table{kind: :type} = type) do
    attrs = %{
      "kind" => "fixed",
      "name" => free_table_name(event.id, name),
      "min_seats" => type.min_seats,
      "max_seats" => type.max_seats
    }

    with {:ok, fixed} <-
           %Table{event_id: event.id, sort_order: type.sort_order}
           |> Table.changeset(attrs)
           |> Repo.insert() do
      {:ok, _} =
        Log.entry(
          scope,
          {:seating_table, fixed.id},
          "#{actor(scope)} added #{describe_table(fixed)} to '#{event.name}' (frozen from #{describe_table(type)})"
        )

      {:ok, fixed, [{:created, fixed} | take_from_limit(scope, type)]}
    end
  end

  defp take_from_limit(_scope, %Table{limit: nil}), do: []

  defp take_from_limit(scope, %Table{limit: 1} = type) do
    {:ok, deleted} = Repo.delete(type)

    {:ok, _} =
      Log.entry(
        scope,
        {:seating_table, deleted.id},
        "#{actor(scope)} deleted #{describe_table(type)} (its last table was frozen)"
      )

    [{:deleted, deleted.id}]
  end

  defp take_from_limit(scope, %Table{limit: limit} = type) do
    {:ok, updated} = type |> Ecto.Changeset.change(limit: limit - 1) |> Repo.update()

    {:ok, _} =
      Log.entry(
        scope,
        {:seating_table, updated.id},
        "#{actor(scope)} changed #{describe_table(type)} to #{describe_table(updated)}"
      )

    [{:updated, updated}]
  end

  defp free_table_name(event_id, name) do
    taken = event_id |> list_tables() |> MapSet.new(&String.downcase(&1.name))

    [name | Enum.map(2..1000, &"#{name} (#{&1})")]
    |> Enum.find(&(not MapSet.member?(taken, String.downcase(&1))))
  end

  @doc """
  Unfreezes a fixed `table` (SEAT-44, SEAT-71): removes every pin to it as one bulk
  action (`XC-12`); the table stays. `{:ok, n}` with how many pins went (0 writes and
  logs nothing); `{:error, :not_fixed}` for a table type.
  """
  @spec unfreeze_table(Scope.t(), Table.t()) :: {:ok, non_neg_integer()} | {:error, :not_fixed}
  def unfreeze_table(%Scope{}, %Table{kind: :type}), do: {:error, :not_fixed}

  def unfreeze_table(%Scope{} = scope, %Table{} = table) do
    pins =
      Pin
      |> where([p], p.seating_table_id == ^table.id)
      |> order_by([p], asc: p.id)
      |> Repo.all()
      |> Repo.preload(:seating_table)

    case pins do
      [] ->
        {:ok, 0}

      _ ->
        count = length(pins)

        summary =
          "#{actor(scope)} unfroze '#{table.name}' (#{count} #{plural(count, "pin", "pins")} removed)"

        {:ok, _} = Log.action(scope, summary, fn -> Enum.each(pins, &delete_pin!(scope, &1)) end)
        Enum.each(pins, &Realtime.broadcast_change(@pin_resource, {:deleted, &1.id}))
        {:ok, count}
    end
  end

  @doc """
  The rule between exactly the two sides `key_a` and `key_b` (`Rule.side_key/1`s), in
  either order, or `nil` (SEAT-30: at most one per unordered pair).
  """
  @spec get_rule_between(String.t(), String.t()) :: Rule.t() | nil
  def get_rule_between(key_a, key_b) do
    [first, second] = Enum.sort([key_a, key_b])
    Repo.get_by(Rule, pair_key: first <> "|" <> second)
  end

  # Insert + log without broadcasting, for callers inside a transaction. `{pin, created?}`.
  defp pin!(scope, table, side) do
    case Repo.get_by(Pin, seating_table_id: table.id, target_key: Rule.side_key(side)) do
      %Pin{} = existing ->
        {existing, false}

      nil ->
        {:ok, pin} = table |> Pin.new(side) |> Repo.insert()

        {:ok, _} =
          Log.entry(
            scope,
            {:seating_table, table.id},
            "#{actor(scope)} pinned #{quoted_side(side)} to '#{table.name}'"
          )

        {pin, true}
    end
  end

  defp delete_pin!(scope, %Pin{} = pin) do
    {:ok, _} = Repo.delete(pin)

    {:ok, _} =
      Log.entry(
        scope,
        {:seating_table, pin.seating_table_id},
        "#{actor(scope)} unpinned #{quoted_side(Pin.side(pin))} from '#{pin.seating_table.name}'"
      )
  end

  @doc "One pin. Raises if it does not exist."
  @spec get_pin!(term()) :: Pin.t()
  def get_pin!(id), do: Repo.get!(Pin, id)

  @doc """
  `EVT-05` provider: how many seating tables `event` has, or `nil` if none. Registered
  via `config :wedding_planner, event_reference_providers:`.
  """
  @spec event_table_reference(Event.t()) :: %{label: String.t(), count: pos_integer()} | nil
  def event_table_reference(%Event{} = event) do
    case Table |> where([t], t.event_id == ^event.id) |> Repo.aggregate(:count) do
      0 -> nil
      n -> %{label: "#{n} seating #{plural(n, "table", "tables")}", count: n}
    end
  end

  @doc """
  SEAT-81: deletes every table of `event`, each logged as a child of the caller's
  `Log.action/3` (`WeddingPlanner.Events.delete_event/2`). Returns the deleted tables;
  the caller broadcasts after commit.
  """
  @spec detach_event(Scope.t(), Event.t()) :: [Table.t()]
  def detach_event(%Scope{} = scope, %Event{} = event) do
    tables = list_tables(event.id)
    table_ids = Enum.map(tables, & &1.id)
    _ = Pin |> where([p], p.seating_table_id in ^table_ids) |> Repo.delete_all()

    for table <- tables do
      {:ok, deleted} = Repo.delete(table)

      {:ok, _} =
        Log.entry(
          scope,
          {:seating_table, deleted.id},
          "#{actor(scope)} deleted #{describe_table(table)} (event '#{event.name}' deleted)"
        )

      deleted
    end
  end

  @doc "`WeddingPlanner.Log.EntityRef` resolver for `\"seating_table\"`."
  @spec resolve_table_log_entity(term()) :: {:ok, String.t(), String.t()} | :error
  def resolve_table_log_entity(id) do
    case Repo.get(Table, id) do
      nil -> :error
      table -> {:ok, table.name, "/seating?event=#{table.event_id}#table-#{table.id}"}
    end
  end

  defp created_table_entry(scope, table, event),
    do: "#{actor(scope)} added #{describe_table(table)} to '#{event.name}'"

  @doc """
  A table as the log and the screen describe it: "table type 'Round' (8–10 seats, at
  most 6)", "fixed table 'Head' (4 seats)".
  """
  @spec describe_table(Table.t()) :: String.t()
  def describe_table(%Table{} = table) do
    kind = if Table.fixed?(table), do: "fixed table", else: "table type"
    limit = if table.limit, do: ", at most #{table.limit}", else: ""
    "#{kind} '#{table.name}' (#{seat_range(table)}#{limit})"
  end

  @doc "A table's seats: \"8–10 seats\", or \"4 seats\" when min and max agree."
  @spec seat_range(Table.t()) :: String.t()
  def seat_range(%Table{min_seats: same, max_seats: same}), do: "#{same} seats"
  def seat_range(%Table{min_seats: min, max_seats: max}), do: "#{min}–#{max} seats"

  defp next_table_sort_order(event_id) do
    case Table |> where([t], t.event_id == ^event_id) |> Repo.aggregate(:max, :sort_order) do
      nil -> 0
      max -> max + 1
    end
  end

  defp plural(1, one, _many), do: one
  defp plural(_n, _one, many), do: many

  # -- person deletion (SEAT-81) ---------------------------------------------------------

  @doc """
  Removes every circle membership and seating rule of any person in `person_ids` — a
  building block only, like `WeddingPlanner.Invitations.delete_for_persons/1`: **no
  transaction, no logging, no broadcast**. Returns how many of each went.
  """
  @spec delete_for_persons([term()]) :: deletion_counts()
  def delete_for_persons(person_ids) when is_list(person_ids) do
    {memberships, _} = person_ids |> memberships_query() |> Repo.delete_all()
    {rules, _} = person_ids |> rules_query() |> Repo.delete_all()
    {pins, _} = Pin |> where([p], p.person_id in ^person_ids) |> Repo.delete_all()
    %{memberships: memberships, rules: rules, pins: pins}
  end

  @doc "Read-only counterpart of `delete_for_persons/1`."
  @spec deletion_counts([term()]) :: deletion_counts()
  def deletion_counts(person_ids) when is_list(person_ids) do
    %{
      memberships: person_ids |> memberships_query() |> Repo.aggregate(:count),
      rules: person_ids |> rules_query() |> Repo.aggregate(:count),
      pins: Pin |> where([p], p.person_id in ^person_ids) |> Repo.aggregate(:count)
    }
  end

  # -- activity log resolvers (XC-10) ----------------------------------------------------

  @doc "`WeddingPlanner.Log.EntityRef` resolver for `\"circle\"`."
  @spec resolve_circle_log_entity(term()) :: {:ok, String.t(), String.t()} | :error
  def resolve_circle_log_entity(id) do
    case Repo.get(Circle, id) do
      nil -> :error
      circle -> {:ok, circle.name, "/seating#circle-#{circle.id}"}
    end
  end

  @doc "`WeddingPlanner.Log.EntityRef` resolver for `\"seating_rule\"`."
  @spec resolve_rule_log_entity(term()) :: {:ok, String.t(), String.t()} | :error
  def resolve_rule_log_entity(id) do
    case Repo.get(Rule, id) do
      nil -> :error
      rule -> {:ok, "Rule #{describe(rule)}", "/seating#rule-#{rule.id}"}
    end
  end

  # -- private ---------------------------------------------------------------------------

  defp insert_membership(circle, person),
    do: Repo.insert(%CircleMembership{circle_id: circle.id, person_id: person.id})

  defp member?(circle, person) do
    CircleMembership
    |> where([m], m.circle_id == ^circle.id and m.person_id == ^person.id)
    |> Repo.exists?()
  end

  defp member_ids(circle) do
    CircleMembership
    |> where([m], m.circle_id == ^circle.id)
    |> select([m], m.person_id)
    |> Repo.all()
  end

  defp broadcast_circle(circle) do
    circle = get_circle!(circle.id)
    Realtime.broadcast_change(@circle_resource, {:updated, circle})
    {:ok, circle}
  end

  defp rules_mentioning(%Circle{id: id}) do
    Rule
    |> where([r], r.a_circle_id == ^id or r.b_circle_id == ^id)
    |> order_by(:id)
    |> Repo.all()
  end

  defp memberships_query(person_ids),
    do: where(CircleMembership, [m], m.person_id in ^person_ids)

  defp rules_query(person_ids),
    do: where(Rule, [r], r.a_person_id in ^person_ids or r.b_person_id in ^person_ids)

  # Checked on the sides as entered (`subject`/`object`), so an error sits next to the
  # field the user picked, whatever the canonical storage order.
  defp validate_sides_exist(changeset) do
    Enum.reduce([:subject, :object], changeset, fn field, changeset ->
      with key when is_binary(key) <- Ecto.Changeset.get_field(changeset, field),
           {:ok, side} <- Rule.parse_side(key),
           false <- side_exists?(side) do
        Ecto.Changeset.add_error(changeset, field, "no longer exists")
      else
        _ -> changeset
      end
    end)
  end

  defp side_exists?(:couple), do: true
  defp side_exists?({:person, id}), do: Repo.exists?(where(Person, [p], p.id == ^id))
  defp side_exists?({:circle, id}), do: Repo.exists?(where(Circle, [c], c.id == ^id))

  defp quoted_side(side), do: "'#{side_name(side)}'"

  defp side_name(:couple), do: couple_name()

  defp side_name({:person, id}) do
    case Person |> Repo.get(id) |> Repo.preload(:host) do
      nil -> "a deleted person"
      person -> name(person)
    end
  end

  defp side_name({:circle, id}) do
    case Repo.get(Circle, id) do
      nil -> "a deleted circle"
      circle -> circle.name
    end
  end

  defp name(%Person{} = person), do: Person.display_name(Repo.preload(person, :host))

  defp reason_suffix(%Rule{reason: nil}), do: ""
  defp reason_suffix(%Rule{reason: reason}), do: " — #{reason}"

  defp cohesion(%Circle{cohesion: cohesion}),
    do: cohesion |> Circle.cohesion_label() |> String.downcase()

  defp rules_word(1), do: "seating rule"
  defp rules_word(_n), do: "seating rules"

  defp people_word(1), do: "person"
  defp people_word(_n), do: "people"

  defp actor(%Scope{user: %User{display_name: name}}), do: name
end
