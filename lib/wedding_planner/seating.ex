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
  alias WeddingPlanner.Guests.Group
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Log
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Seating.Circle
  alias WeddingPlanner.Seating.CircleMembership
  alias WeddingPlanner.Seating.Rule

  @circle_resource :circle
  @rule_resource :seating_rule

  @type deletion_counts :: %{memberships: non_neg_integer(), rules: non_neg_integer()}

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
  `WeddingPlannerWeb.CoreComponents.destructive_confirm/1`'s shape: its rules, each
  present only when non-zero. Its members are not deleted, only taken out of it.
  """
  @spec circle_deletion_effects(Circle.t()) :: [%{label: String.t(), count: non_neg_integer()}]
  def circle_deletion_effects(%Circle{} = circle) do
    count = circle |> rules_mentioning() |> length()

    if count == 0,
      do: [],
      else: [%{label: "Also deletes #{count} #{rules_word(count)}", count: count}]
  end

  @doc """
  Deletes a circle, its memberships and every rule that mentions it (SEAT-81), in one
  `Log.action/3`: a summary, then one child per removed rule. Broadcasts each removed
  rule's `{:deleted, id}` and the circle's after commit.
  """
  @spec delete_circle(Scope.t(), Circle.t()) :: {:ok, Circle.t()}
  def delete_circle(%Scope{} = scope, %Circle{} = circle) do
    rules = rules_mentioning(circle)
    descriptions = Map.new(rules, &{&1.id, describe(&1)})

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

        _ = CircleMembership |> where([m], m.circle_id == ^circle.id) |> Repo.delete_all()
        {:ok, deleted} = Repo.delete(circle)
        deleted
      end)

    Enum.each(rules, &Realtime.broadcast_change(@rule_resource, {:deleted, &1.id}))
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
    %{memberships: memberships, rules: rules}
  end

  @doc "Read-only counterpart of `delete_for_persons/1`."
  @spec deletion_counts([term()]) :: deletion_counts()
  def deletion_counts(person_ids) when is_list(person_ids) do
    %{
      memberships: person_ids |> memberships_query() |> Repo.aggregate(:count),
      rules: person_ids |> rules_query() |> Repo.aggregate(:count)
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
