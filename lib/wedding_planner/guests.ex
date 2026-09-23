defmodule WeddingPlanner.Guests do
  @moduledoc """
  The guest list's core entities (`docs/modules/guests-and-events.md` `PER-01` through
  `PER-07`), resources `:person` and `:group`, entity types `"person"` and `"group"`.

  This is slice G1's data layer only, following `WeddingPlanner.Events`'s exemplar
  pattern: context CRUD, per-field activity logging (`XC-10`), bulk actions
  (`XC-12`) and PubSub (`XC-01`) — the `/people` screen itself is task 27. +1s
  (`PER-10` through `PER-16`, slice G2) and invitations (slice G3) are out of scope: in
  this task every person needs at least one of first/last name (`PER-02`), and
  `person_deletion_effects/1` is always `[]`.

  ## Sorting and filtering happen in Elixir, not SQL (`DR-26` Q7, Q8)

  `list_persons/1` reads every person once and then filters/sorts in memory. This is
  deliberate, not a shortcut: SQLite's `lower()` only folds ASCII, so a SQL `ORDER BY
  lower(last_name)` would mis-sort accented and other non-ASCII names, and there are at
  most ~150 persons (`NFR-33`) — cheap to hold in memory and sort with
  `String.downcase/1`, which is Unicode-aware. `list_groups/0` sorts the same way for
  the same reason.

  ## Bulk actions (`PER-04`, `XC-12`)

  `bulk_create_persons/3`, `bulk_update_persons/4`, `bulk_delete_persons/2` and
  `delete_group/2` (which touches every member) each wrap their multi-row write in
  `WeddingPlanner.Log.action/3` — one summarising entry plus one child entry per
  affected person, per `WeddingPlanner.Log`'s own guidance for why `Log.entry/3` alone
  inside a caller's own transaction would broadcast too early. None of them create any
  group-level state that overrides a person's own fields (`PER-04`'s last sentence).

  ## Deleting a group (`PER-07`)

  `delete_group/2` ungroups every member **explicitly**, inside the same transaction as
  the group's own delete, rather than relying on the `groups_id` foreign key's
  `on_delete: :nilify_all` — that FK is a backstop only. Ungrouping has to happen in
  application code because each member's own activity history must show it (`XC-10`,
  `XC-11`); a bare FK cascade would silently change the row with no log entry.

  ## `group_id` existence (`PER-03`) is checked here, not in the schema

  `Person.changeset/2` casts `group_id` and (defensively) declares
  `foreign_key_constraint/2` on it, but this project's SQLite adapter cannot report
  which constraint a raw `INSERT`/`UPDATE` violated, so that declaration never actually
  converts a violation into a changeset error — a documented `ecto_sqlite3` limitation,
  the same reason `WeddingPlanner.Tasks.change_task/2` checks its owner with a query
  rather than a schema-level constraint. `change_person/2` here adds the real check
  (`Repo.exists?/1`) on top of `Person.changeset/2`'s structural rules, exactly
  mirroring that precedent.
  """

  import Ecto.Query

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Guests.Group
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Log
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo

  @person_resource :person
  @group_resource :group

  @person_loggable_fields [
    :first_name,
    :last_name,
    :age_category,
    :want_tier,
    :certainty,
    :notes,
    :group_id
  ]
  @group_loggable_fields [:name, :type_label]

  @type sort_attr ::
          :name | :first_name | :last_name | :group | :age_category | :want_tier | :certainty
  @type sort_direction :: :asc | :desc
  @type sort :: sort_attr() | {sort_attr(), sort_direction()}
  @type filters :: %{
          optional(:text) => String.t(),
          optional(:group_id) => term() | :ungrouped,
          optional(:age_category) => Person.age_category(),
          optional(:want_tier) => Person.want_tier(),
          optional(:certainty) => Person.certainty()
        }

  # -- persons -------------------------------------------------------------------------

  @doc """
  Every person, sorted and filtered (`PER-05`).

  `opts` is `%{sort: sort(), filters: filters()}`, both optional. `sort` defaults to
  `:name` (`DR-26` Q8): last name, falling back to first name when there is none,
  case-insensitive and Unicode-aware, particles not ignored ("Van Damme" sorts under V),
  then first name, then id. Any other single `PER-02` attribute is also accepted, with
  the same case-insensitive last-name/first-name/id tiebreak, ascending unless
  `{attr, :desc}` is given.

  `filters` narrows by free text (matched case-insensitively against first name, last
  name and notes), `group_id` (an id, or `:ungrouped` for no group), `age_category`,
  `want_tier` and `certainty`. A filter key that is absent (or `nil`) does not narrow.
  """
  @spec list_persons(%{optional(:sort) => sort(), optional(:filters) => filters()}) ::
          [Person.t()]
  def list_persons(opts \\ %{}) do
    {sort_attr, direction} = normalize_sort(Map.get(opts, :sort, :name))
    filters = Map.get(opts, :filters, %{})

    Person
    |> preload(:group)
    |> Repo.all()
    |> Enum.filter(&matches_filters?(&1, filters))
    |> Enum.sort_by(&person_sort_key(&1, sort_attr), direction)
  end

  @doc "Fetches one person by id, `:group` preloaded. Raises if it does not exist."
  @spec get_person!(term()) :: Person.t()
  def get_person!(id) do
    Person
    |> preload(:group)
    |> Repo.get!(id)
  end

  @doc """
  A changeset for building/validating a form — never persists on its own. Adds the
  `group_id` existence check (`PER-03`) on top of `Person.changeset/2`'s structural
  rules, the same split `WeddingPlanner.Tasks.change_task/2` uses for its owner check:
  that needs a query, so it cannot live in the schema's own changeset (see the
  moduledoc's note on `foreign_key_constraint/2`).
  """
  @spec change_person(Person.t(), map()) :: Ecto.Changeset.t()
  def change_person(%Person{} = person, attrs \\ %{}) do
    person |> Person.changeset(attrs) |> validate_group_exists()
  end

  @doc """
  Creates a person, logs it (`XC-10`, worded the same as `bulk_create_persons/3`'s child
  entries: "Wannes added 'Bo'") and broadcasts `{:created, person}` (`XC-01`).
  """
  @spec create_person(Scope.t(), map()) :: {:ok, Person.t()} | {:error, Ecto.Changeset.t()}
  def create_person(%Scope{} = scope, attrs) do
    %Person{}
    |> change_person(attrs)
    |> Repo.insert()
    |> case do
      {:ok, person} ->
        person = preload_person(person)

        {:ok, _} =
          Log.entry(
            scope,
            {:person, person.id},
            "#{actor(scope)} added '#{Person.display_name(person)}'"
          )

        Realtime.broadcast_change(@person_resource, {:created, person})
        {:ok, person}

      error ->
        error
    end
  end

  @doc """
  Updates a person. Logs one activity entry per user-facing field that actually changed
  (`XC-10`), e.g. "Wannes changed the want tier of 'Anna Peeters': Yes → Maybe" or
  "Wannes changed the group of 'Anna Peeters': none → Family Peeters" — old/new values
  rendered the way the UI shows them. Broadcasts `{:updated, person}` (`XC-01`) once,
  after every log entry is written.
  """
  @spec update_person(Scope.t(), Person.t(), map()) ::
          {:ok, Person.t()} | {:error, Ecto.Changeset.t()}
  def update_person(%Scope{} = scope, %Person{} = person, attrs) do
    changeset = change_person(person, attrs)

    with {:ok, updated} <- Repo.update(changeset) do
      :ok = log_person_field_changes(scope, person, updated, changeset)
      updated = preload_person(updated)
      Realtime.broadcast_change(@person_resource, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc "Deletes a person, logs it (`XC-10`) and broadcasts `{:deleted, id}` (`XC-01`)."
  @spec delete_person(Scope.t(), Person.t()) :: {:ok, Person.t()} | {:error, Ecto.Changeset.t()}
  def delete_person(%Scope{} = scope, %Person{} = person) do
    with {:ok, deleted} <- Repo.delete(person) do
      {:ok, _} =
        Log.entry(
          scope,
          {:person, deleted.id},
          "#{actor(scope)} deleted '#{Person.display_name(deleted)}'"
        )

      Realtime.broadcast_change(@person_resource, {:deleted, deleted.id})
      {:ok, deleted}
    end
  end

  @doc """
  What deleting `person` would affect, in the shape
  `WeddingPlannerWeb.CoreComponents.destructive_confirm/1` takes. Always `[]` in this
  slice — G2 (+1s) and G3 (invitations) are what will give a person something to lose.
  """
  @spec person_deletion_effects(Person.t()) :: [%{label: String.t(), count: non_neg_integer()}]
  def person_deletion_effects(%Person{}), do: []

  @doc """
  Adds every entry in `name_maps` (e.g. `WeddingPlanner.Guests.PasteParser.parse/1`'s
  `:ok` results) as a new person, `shared_attrs` merged onto each (age/want/certainty/
  group/notes shared across the whole paste). One `WeddingPlanner.Log.action/3`:
  a summary ("Wannes added 6 people") plus one child entry per person ("Wannes added
  'Bo'"). All-or-nothing (`XC-12`) — an invalid entry rolls the whole batch back.
  """
  @spec bulk_create_persons(Scope.t(), [Person.name_map()], map()) ::
          {:ok, [Person.t()]} | {:error, Ecto.Changeset.t()}
  def bulk_create_persons(scope, name_maps, shared_attrs \\ %{})

  def bulk_create_persons(%Scope{}, [], _shared_attrs), do: {:ok, []}

  def bulk_create_persons(%Scope{} = scope, name_maps, shared_attrs) when is_list(name_maps) do
    count = length(name_maps)
    summary = "#{actor(scope)} added #{count} #{pluralize_person(count)}"

    result =
      Log.action(scope, summary, fn ->
        name_maps
        |> Enum.reduce_while([], fn name_map, acc ->
          attrs = Map.merge(shared_attrs, name_map)

          case %Person{} |> change_person(attrs) |> Repo.insert() do
            {:ok, person} ->
              {:ok, _} =
                Log.entry(
                  scope,
                  {:person, person.id},
                  "#{actor(scope)} added '#{Person.display_name(person)}'"
                )

              {:cont, [person | acc]}

            {:error, changeset} ->
              {:halt, {:error, changeset}}
          end
        end)
        |> case do
          {:error, changeset} -> Repo.rollback(changeset)
          persons -> Enum.reverse(persons)
        end
      end)

    case result do
      {:ok, persons} ->
        Enum.each(persons, &Realtime.broadcast_change(@person_resource, {:created, &1}))
        {:ok, persons}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Sets `field` (`:want_tier` or `:certainty`) to `value` on every person in `persons`
  (`PER-04`). One `WeddingPlanner.Log.action/3`: children only for persons whose value
  actually changes, the summary counting those ("Wannes set 3 people to want tier
  Maybe"); when `persons` is exactly every member of one group, the summary names it
  ("Wannes set 4 people in 'Family Peeters' to want tier Maybe", `XC-12`'s own example).
  Writes no group-level state (`PER-04`'s last sentence) — only the persons themselves.
  """
  @spec bulk_update_persons(
          Scope.t(),
          [Person.t()],
          :want_tier | :certainty,
          Person.want_tier() | Person.certainty()
        ) :: {:ok, [Person.t()]}
  def bulk_update_persons(%Scope{} = scope, persons, field, value)
      when is_list(persons) and field in [:want_tier, :certainty] do
    changed = Enum.filter(persons, &(Map.fetch!(&1, field) != value))
    summary = bulk_update_summary(scope, persons, field, value, length(changed))

    {:ok, updated} =
      Log.action(scope, summary, fn ->
        Enum.map(changed, fn person ->
          {:ok, updated} = person |> Person.changeset(%{field => value}) |> Repo.update()

          {:ok, _} =
            Log.entry(
              scope,
              {:person, updated.id},
              "#{actor(scope)} changed the #{field_label(field)} of '#{Person.display_name(person)}': " <>
                "#{display_value(field, Map.fetch!(person, field))} → #{display_value(field, value)}"
            )

          updated
        end)
      end)

    updated = Enum.map(updated, &preload_person/1)
    Enum.each(updated, &Realtime.broadcast_change(@person_resource, {:updated, &1}))
    {:ok, updated}
  end

  @doc """
  Deletes every person in `persons` by name (`PER-07`'s "always ... through a bulk
  action that names them"). One `WeddingPlanner.Log.action/3`: a summary naming the
  count and every name ("Wannes deleted 3 people: Griet Van Acker, Ines Van Acker, Bo"),
  plus one child entry per person.
  """
  @spec bulk_delete_persons(Scope.t(), [Person.t()]) :: {:ok, [Person.t()]}
  def bulk_delete_persons(%Scope{} = scope, persons) when is_list(persons) do
    names = persons |> Enum.map(&Person.display_name/1) |> Enum.join(", ")
    count = length(persons)
    summary = "#{actor(scope)} deleted #{count} #{pluralize_person(count)}: #{names}"

    {:ok, deleted} =
      Log.action(scope, summary, fn ->
        Enum.map(persons, fn person ->
          {:ok, deleted} = Repo.delete(person)

          {:ok, _} =
            Log.entry(
              scope,
              {:person, deleted.id},
              "#{actor(scope)} deleted '#{Person.display_name(deleted)}'"
            )

          deleted
        end)
      end)

    Enum.each(deleted, &Realtime.broadcast_change(@person_resource, {:deleted, &1.id}))
    {:ok, deleted}
  end

  # -- groups --------------------------------------------------------------------------

  @doc "Every group, ordered by name, case-insensitively (see moduledoc)."
  @spec list_groups() :: [Group.t()]
  def list_groups do
    Group
    |> Repo.all()
    |> Enum.sort_by(&{String.downcase(&1.name), &1.id})
  end

  @doc "Fetches one group by id. Raises if it does not exist."
  @spec get_group!(term()) :: Group.t()
  def get_group!(id), do: Repo.get!(Group, id)

  @doc "A changeset for building/validating a form — never persists on its own."
  @spec change_group(Group.t(), map()) :: Ecto.Changeset.t()
  def change_group(%Group{} = group, attrs \\ %{}), do: Group.changeset(group, attrs)

  @doc "Creates a group, logs it (`XC-10`) and broadcasts `{:created, group}` (`XC-01`)."
  @spec create_group(Scope.t(), map()) :: {:ok, Group.t()} | {:error, Ecto.Changeset.t()}
  def create_group(%Scope{} = scope, attrs) do
    %Group{}
    |> Group.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, group} ->
        {:ok, _} =
          Log.entry(scope, {:group, group.id}, "#{actor(scope)} created group '#{group.name}'")

        Realtime.broadcast_change(@group_resource, {:created, group})
        {:ok, group}

      error ->
        error
    end
  end

  @doc """
  Updates a group's name and/or type label. Logs one entry per changed field (`XC-10`)
  and broadcasts `{:updated, group}` (`XC-01`) once.
  """
  @spec update_group(Scope.t(), Group.t(), map()) ::
          {:ok, Group.t()} | {:error, Ecto.Changeset.t()}
  def update_group(%Scope{} = scope, %Group{} = group, attrs) do
    changeset = Group.changeset(group, attrs)

    with {:ok, updated} <- Repo.update(changeset) do
      :ok = log_group_field_changes(scope, group, updated, changeset)
      Realtime.broadcast_change(@group_resource, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc """
  Deletes a group. Its members are **not** deleted (`PER-07`): one
  `WeddingPlanner.Log.action/3` writes a summary ("Wannes deleted group 'Family
  Peeters' (4 people ungrouped)"), then explicitly sets `group_id: nil` on each member
  (a child entry per member, "Wannes removed 'Anna Peeters' from 'Family Peeters' (group
  deleted)"), then the group's own delete entry. Broadcasts `{:updated, person}` for
  every ungrouped member and `{:deleted, id}` for the group (`XC-01`).
  """
  @spec delete_group(Scope.t(), Group.t()) :: {:ok, Group.t()}
  def delete_group(%Scope{} = scope, %Group{} = group) do
    members = members_of(group)
    count = length(members)

    summary =
      "#{actor(scope)} deleted group '#{group.name}' (#{count} #{pluralize_person(count)} ungrouped)"

    {:ok, {deleted, ungrouped}} =
      Log.action(scope, summary, fn ->
        ungrouped =
          Enum.map(members, fn person ->
            {:ok, updated} = person |> Ecto.Changeset.change(group_id: nil) |> Repo.update()

            {:ok, _} =
              Log.entry(
                scope,
                {:person, updated.id},
                "#{actor(scope)} removed '#{Person.display_name(updated)}' from '#{group.name}' (group deleted)"
              )

            updated
          end)

        {:ok, deleted} = Repo.delete(group)

        {:ok, _} =
          Log.entry(
            scope,
            {:group, deleted.id},
            "#{actor(scope)} deleted group '#{deleted.name}'"
          )

        {deleted, ungrouped}
      end)

    ungrouped = Enum.map(ungrouped, &preload_person/1)
    Enum.each(ungrouped, &Realtime.broadcast_change(@person_resource, {:updated, &1}))
    Realtime.broadcast_change(@group_resource, {:deleted, deleted.id})
    {:ok, deleted}
  end

  @doc """
  What deleting `group` would affect (`PER-07`, `XC-40`): `[]` when it has no members,
  else one `%{label:, count:}` entry, e.g. `%{label: "4 people become ungrouped, not
  deleted", count: 4}`.
  """
  @spec group_deletion_effects(Group.t()) :: [%{label: String.t(), count: non_neg_integer()}]
  def group_deletion_effects(%Group{} = group) do
    case members_of(group) do
      [] ->
        []

      members ->
        count = length(members)

        [
          %{
            label: "#{count} #{pluralize_person(count)} become ungrouped, not deleted",
            count: count
          }
        ]
    end
  end

  # -- activity-log links ---------------------------------------------------------------

  @doc """
  `WeddingPlanner.Log.EntityRef` resolver for the `"person"` entity type (`DR-26` Q9):
  an existing person resolves to their display name and `/people/<id>`; a deleted one
  is `:error` (degrades to plain text).
  """
  @spec resolve_person_log_entity(term()) :: {:ok, String.t(), String.t() | nil} | :error
  def resolve_person_log_entity(id) do
    case Repo.get(Person, id) do
      nil -> :error
      person -> {:ok, Person.display_name(person), "/people/#{person.id}"}
    end
  end

  @doc """
  `WeddingPlanner.Log.EntityRef` resolver for the `"group"` entity type (`DR-26` Q9):
  groups have no page of their own, so an existing group resolves to its name and the
  grouped view anchored at it; a deleted one is `:error`.
  """
  @spec resolve_group_log_entity(term()) :: {:ok, String.t(), String.t() | nil} | :error
  def resolve_group_log_entity(id) do
    case Repo.get(Group, id) do
      nil -> :error
      group -> {:ok, group.name, "/people?view=grouped#group-#{group.id}"}
    end
  end

  # -- private ---------------------------------------------------------------------------

  defp preload_person(%Person{} = person), do: Repo.preload(person, :group)

  # `PER-03`: `group_id` must refer to a real group. This needs a query, so — like
  # `WeddingPlanner.Tasks.change_task/2`'s owner check — it lives here rather than in
  # `Person.changeset/2`. `Ecto.Changeset.foreign_key_constraint/2` (also present on that
  # changeset) is a defensive backstop only: this project's SQLite adapter cannot report
  # which constraint a raw INSERT/UPDATE violated, so it never actually converts a
  # violation into a changeset error (see `Ecto.Adapters.SQLite3`'s own moduledoc,
  # "Handling foreign key constraints in changesets").
  defp validate_group_exists(changeset) do
    case Ecto.Changeset.get_change(changeset, :group_id) do
      nil ->
        changeset

      group_id ->
        if Repo.exists?(where(Group, [g], g.id == ^group_id)) do
          changeset
        else
          Ecto.Changeset.add_error(changeset, :group_id, "does not exist")
        end
    end
  end

  defp members_of(%Group{id: id}) do
    Person
    |> where([p], p.group_id == ^id)
    |> Repo.all()
  end

  defp normalize_sort({attr, direction}) when direction in [:asc, :desc], do: {attr, direction}
  defp normalize_sort(attr) when is_atom(attr), do: {attr, :asc}

  defp matches_filters?(person, filters) do
    Enum.all?(filters, fn {key, value} -> matches_filter?(person, key, value) end)
  end

  defp matches_filter?(_person, _key, nil), do: true
  defp matches_filter?(person, :text, text), do: matches_text?(person, text)
  defp matches_filter?(person, :group_id, :ungrouped), do: is_nil(person.group_id)
  defp matches_filter?(person, :group_id, group_id), do: person.group_id == group_id
  defp matches_filter?(person, :age_category, value), do: person.age_category == value
  defp matches_filter?(person, :want_tier, value), do: person.want_tier == value
  defp matches_filter?(person, :certainty, value), do: person.certainty == value

  defp matches_text?(_person, ""), do: true

  defp matches_text?(person, text) do
    needle = String.downcase(text)

    [person.first_name, person.last_name, person.notes]
    |> Enum.any?(fn
      nil -> false
      value -> value |> String.downcase() |> String.contains?(needle)
    end)
  end

  # `DR-26` Q8: last name, falling back to first name when there is none, then first
  # name, then id — all case-insensitively. Every other single-attribute sort shares the
  # same tiebreak so the order is always fully deterministic.
  defp person_sort_key(person, :name),
    do: {name_primary(person), name_secondary(person), person.id}

  defp person_sort_key(person, :first_name),
    do: {downcase(person.first_name), name_secondary(person), person.id}

  defp person_sort_key(person, :last_name),
    do: {downcase(person.last_name), name_secondary(person), person.id}

  defp person_sort_key(person, :group),
    do: {group_sort_value(person), name_primary(person), name_secondary(person), person.id}

  defp person_sort_key(person, :age_category) do
    {enum_rank(person.age_category, Person.age_categories()), name_primary(person),
     name_secondary(person), person.id}
  end

  defp person_sort_key(person, :want_tier) do
    {enum_rank(person.want_tier, Person.want_tiers()), name_primary(person),
     name_secondary(person), person.id}
  end

  defp person_sort_key(person, :certainty) do
    {enum_rank(person.certainty, Person.certainties()), name_primary(person),
     name_secondary(person), person.id}
  end

  defp name_primary(%Person{last_name: nil, first_name: first}), do: downcase(first)
  defp name_primary(%Person{last_name: last}), do: downcase(last)

  defp name_secondary(%Person{first_name: first}), do: downcase(first)

  defp group_sort_value(%Person{group: %Group{name: name}}), do: downcase(name)
  defp group_sort_value(%Person{group: nil}), do: ""

  defp enum_rank(value, order), do: Enum.find_index(order, &(&1 == value)) || length(order)

  defp downcase(nil), do: ""
  defp downcase(value), do: String.downcase(value)

  defp bulk_update_summary(scope, persons, field, value, changed_count) do
    base = "#{actor(scope)} set #{changed_count} #{pluralize_person(changed_count)}"

    scope_phrase =
      case sole_group(persons) do
        {:ok, group} -> " in '#{group.name}'"
        :error -> ""
      end

    "#{base}#{scope_phrase} to #{field_label(field)} #{display_value(field, value)}"
  end

  defp sole_group([]), do: :error

  defp sole_group(persons) do
    case persons |> Enum.map(& &1.group_id) |> Enum.uniq() do
      [group_id] when not is_nil(group_id) ->
        case Repo.get(Group, group_id) do
          nil ->
            :error

          group ->
            member_count = Person |> where([p], p.group_id == ^group_id) |> Repo.aggregate(:count)
            if member_count == length(persons), do: {:ok, group}, else: :error
        end

      _ ->
        :error
    end
  end

  defp log_person_field_changes(scope, %Person{} = before, %Person{} = updated, changeset) do
    changeset.changes
    |> Map.keys()
    |> Enum.filter(&(&1 in @person_loggable_fields))
    |> Enum.each(fn field ->
      old = display_value(field, Map.fetch!(before, field))
      new = display_value(field, Map.fetch!(updated, field))

      {:ok, _} =
        Log.entry(
          scope,
          {:person, updated.id},
          "#{actor(scope)} changed the #{field_label(field)} of '#{Person.display_name(before)}': #{old} → #{new}"
        )
    end)

    :ok
  end

  defp log_group_field_changes(scope, %Group{} = before, %Group{} = updated, changeset) do
    changeset.changes
    |> Map.keys()
    |> Enum.filter(&(&1 in @group_loggable_fields))
    |> Enum.each(fn field ->
      old = display_value(field, Map.fetch!(before, field))
      new = display_value(field, Map.fetch!(updated, field))

      {:ok, _} =
        Log.entry(
          scope,
          {:group, updated.id},
          "#{actor(scope)} changed the #{field_label(field)} of '#{before.name}': #{old} → #{new}"
        )
    end)

    :ok
  end

  defp field_label(:first_name), do: "first name"
  defp field_label(:last_name), do: "last name"
  defp field_label(:age_category), do: "age category"
  defp field_label(:want_tier), do: "want tier"
  defp field_label(:certainty), do: "certainty"
  defp field_label(:notes), do: "notes"
  defp field_label(:group_id), do: "group"
  defp field_label(:name), do: "name"
  defp field_label(:type_label), do: "type label"

  defp display_value(:group_id, id), do: group_display_name(id)
  defp display_value(:age_category, value), do: age_category_label(value)
  defp display_value(:want_tier, value), do: want_tier_label(value)
  defp display_value(:certainty, value), do: certainty_label(value)
  defp display_value(_field, nil), do: "none"
  defp display_value(_field, value), do: value

  defp age_category_label(:adult), do: "Adult"
  defp age_category_label(:child), do: "Child"

  defp want_tier_label(:yes), do: "Yes"
  defp want_tier_label(:maybe), do: "Maybe"
  defp want_tier_label(:no), do: "No"
  defp want_tier_label(:obligated), do: "Obligated"

  defp certainty_label(:certain), do: "Certain"
  defp certainty_label(:likely), do: "Likely"
  defp certainty_label(:uncertain), do: "Uncertain"

  defp group_display_name(nil), do: "none"

  defp group_display_name(id) do
    case Repo.get(Group, id) do
      nil -> "none"
      group -> group.name
    end
  end

  defp pluralize_person(1), do: "person"
  defp pluralize_person(_n), do: "people"

  defp actor(%Scope{user: %User{display_name: name}}), do: name
end
