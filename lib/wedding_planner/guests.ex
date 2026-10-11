defmodule WeddingPlanner.Guests do
  @moduledoc """
  The guest list's core entities (`docs/modules/guests-and-events.md` `PER-01` through
  `PER-07`), resources `:person` and `:group`, entity types `"person"` and `"group"`.

  This is slice G1's data layer, following `WeddingPlanner.Events`'s exemplar
  pattern: context CRUD, per-field activity logging (`XC-10`), bulk actions
  (`XC-12`) and PubSub (`XC-01`) — the `/people` screen itself is task 27.

  ## +1s (`PER-10` through `PER-16`, slice G2, `DR-32`/`DR-34`)

  `add_plus_one/3`, `confirm_plus_one/2` and `name_plus_one/3` are the three +1-specific
  actions; `update_person/3` and `delete_person/2` handle a +1 (or a host with +1s) as
  one more case, not a separate code path per action. A +1's own `want_tier`/`certainty`
  columns are written once at creation and never read again — every reader goes through
  `WeddingPlanner.Guests.PlusOne` instead (`DR-32`). `list_persons/1` returns **host
  units**: a host immediately followed by its own +1s, built explicitly rather than
  relying on encounter order, filtered per unit (host or any +1 matching includes the
  whole unit) and sorted by the host (`DR-34`). Deleting a host deletes its +1s, named,
  in one `Log.action/3`, +1s first (the self-FK is `on_delete: :restrict`) — both singly
  (`delete_person/2`) and expanded into a bulk selection (`bulk_delete_persons/2`);
  `bulk_update_persons/4` skips +1s entirely (`PER-15`: not editable). +1 activity
  entries are written against the +1 itself, never the host (`DR-34`).

  No invitation/opt-out *storage* lives here — that is `WeddingPlanner.Invitations`
  (`DR-37`) — but slice G3 does extend every deletion path in this module to remove a
  deleted person's invitations/opt-outs first (`Invitations.delete_for_persons/1`,
  `:restrict` FKs), name what that additionally removes in `person_deletion_effects/1`/
  `bulk_deletion_effects/1`, and append it to the person's own delete-entry wording
  (`DR-38`): `delete_single_person/2` (a +1 alone, or a host without +1s) becomes
  transactional — `Repo.transaction/1`, not `Log.action/3`, because the single delete
  entry this writes must stay an ordinary per-entity entry (`{:person, id}`), not an
  untyped `Log.action/3` summary with no entity of its own; it is written, and the
  change broadcast, only **after** that transaction commits (`Log`'s own "Known
  limitation" section: `Log.entry/3` inside a bare `Repo.transaction` broadcasts before
  commit, which this sidesteps by calling it afterwards instead of inside).
  `delete_host_with_plus_ones/3` and `bulk_delete_persons/2` already ran through
  `Log.action/3`, so they call `delete_for_persons/1` once, for every id about to be
  deleted, as the first step inside that same transaction.

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
  alias WeddingPlanner.Guests.PlusOne
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Log
  alias WeddingPlanner.Presets
  alias WeddingPlanner.Presets.HeadcountPreset
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Seating

  @person_resource :person
  @group_resource :group
  @headcount_preset_resource :headcount_preset

  @person_loggable_fields [
    :first_name,
    :last_name,
    :age_category,
    :want_tier,
    :certainty,
    :notes,
    :group_id,
    :plus_one_status,
    :fine_anywhere
  ]
  @max_witnesses 2
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
  Every person, as **host units** (`DR-34`): each non-+1 person immediately followed by
  its own +1s (ordered by id) — built explicitly, never relying on encounter order.

  `opts` is `%{sort: sort(), filters: filters()}`, both optional. `sort` defaults to
  `:name` (`DR-26` Q8): last name, falling back to first name when there is none,
  case-insensitive and Unicode-aware, particles not ignored ("Van Damme" sorts under V),
  then first name, then id. Any other single `PER-02` attribute is also accepted, with
  the same case-insensitive last-name/first-name/id tiebreak, ascending unless
  `{attr, :desc}` is given. Units are ordered by the **host's** sort key; a unit's +1s
  always directly follow their host regardless of sort attribute.

  `filters` narrows by free text (matched case-insensitively against first name, last
  name and notes), `group_id` (an id, or `:ungrouped` for no group), `age_category`,
  `want_tier` and `certainty`. A filter key that is absent (or `nil`) does not narrow. A
  unit is included if the host **or any of its +1s** matches — then the whole unit is
  included; a +1's `want_tier`/`certainty`/`group_id` filter values are its *inherited*
  ones (`WeddingPlanner.Guests.PlusOne`), never its own stored columns (`DR-32`).
  """
  @spec list_persons(%{optional(:sort) => sort(), optional(:filters) => filters()}) ::
          [Person.t()]
  def list_persons(opts \\ %{}) do
    {sort_attr, direction} = normalize_sort(Map.get(opts, :sort, :name))
    filters = Map.get(opts, :filters, %{})

    Person
    |> preload(:group)
    |> Repo.all()
    |> build_host_units()
    |> Enum.filter(&unit_matches_filters?(&1, filters))
    |> Enum.sort_by(fn {host, _plus_ones} -> person_sort_key(host, sort_attr) end, direction)
    |> Enum.flat_map(fn {host, plus_ones} -> [host | plus_ones] end)
  end

  @doc """
  Fetches one person by id, `:group`, `host: :group` and `:plus_ones` preloaded. Raises
  if it does not exist.
  """
  @spec get_person!(term()) :: Person.t()
  def get_person!(id) do
    Person
    |> preload([:group, :plus_ones, host: :group])
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
  Adds a +1 to `host` (`PER-10`, `PER-12`). Builds `%Person{host_id: host.id, want_tier:
  host.want_tier, certainty: host.certainty}` — want tier and certainty written from the
  host now and never read again (`DR-32`) — and applies `Person.plus_one_changeset/2`;
  `plus_one_status` defaults to `:possible` when absent from `attrs`, age defaults adult
  (the schema's own default).

  Refused, as a changeset error on `:host_id`, when `host` does not exist any more or is
  itself a +1 (`PER-10`: no chains) — checked here with a query, the same split
  `change_person/2` uses for `group_id` (see this module's moduledoc).

  Logs against the new +1 itself: "Wannes added a +1 for 'Anna Peeters' (possible,
  unnamed)" / "(confirmed, 'Tom Wils')". Broadcasts `{:created, plus_one}` (`XC-01`),
  same resource as every other person (`:person` — a +1 gets no PubSub resource of its
  own).
  """
  @spec add_plus_one(Scope.t(), Person.t(), map()) ::
          {:ok, Person.t()} | {:error, Ecto.Changeset.t()}
  def add_plus_one(%Scope{} = scope, %Person{} = host, attrs) do
    %Person{host_id: host.id, want_tier: host.want_tier, certainty: host.certainty}
    |> Person.plus_one_changeset(with_default_plus_one_status(attrs))
    |> validate_host_for_plus_one(host)
    |> Repo.insert()
    |> case do
      {:ok, plus_one} ->
        plus_one = preload_person(plus_one)

        {:ok, _} =
          Log.entry(
            scope,
            {:person, plus_one.id},
            "#{actor(scope)} added a +1 for '#{Person.display_name(host)}' (#{plus_one_add_suffix(plus_one)})"
          )

        Realtime.broadcast_change(@person_resource, {:created, plus_one})
        {:ok, plus_one}

      error ->
        error
    end
  end

  @doc """
  Upgrades a +1 from *possible* to *confirmed* — a single action (`PER-12`). Logs
  "Wannes confirmed '+1 of Anna Peeters' (possible → confirmed)". Already-confirmed is a
  no-op: `{:ok, plus_one}`, no log entry, no broadcast.
  """
  @spec confirm_plus_one(Scope.t(), Person.t()) ::
          {:ok, Person.t()} | {:error, Ecto.Changeset.t()}
  def confirm_plus_one(%Scope{}, %Person{plus_one_status: :confirmed} = plus_one) do
    {:ok, preload_person(plus_one)}
  end

  def confirm_plus_one(%Scope{} = scope, %Person{plus_one_status: :possible} = plus_one) do
    changeset = Person.plus_one_changeset(plus_one, %{plus_one_status: :confirmed})

    with {:ok, updated} <- Repo.update(changeset) do
      updated = preload_person(updated)

      {:ok, _} =
        Log.entry(
          scope,
          {:person, updated.id},
          "#{actor(scope)} confirmed '#{Person.display_name(updated)}' (possible → confirmed)"
        )

      Realtime.broadcast_change(@person_resource, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc """
  Names a +1 — a single action (`PER-11`, `PER-12`), independent of its +1 status.
  Requires at least one of `first_name`/`last_name` in the result (use `update_person/3`
  to clear a +1's names back to unnamed). Logs "Wannes named '+1 of Anna Peeters': Tom
  Wils" (old display name computed before the update, so an unnamed +1 resolves
  correctly).
  """
  @spec name_plus_one(Scope.t(), Person.t(), %{
          optional(:first_name) => String.t() | nil,
          optional(:last_name) => String.t() | nil
        }) :: {:ok, Person.t()} | {:error, Ecto.Changeset.t()}
  def name_plus_one(%Scope{} = scope, %Person{} = plus_one, name_attrs) do
    old_display_name = plus_one |> preload_person() |> Person.display_name()

    changeset =
      plus_one
      |> Person.plus_one_changeset(name_attrs)
      |> require_a_name_part()

    with {:ok, updated} <- Repo.update(changeset) do
      updated = preload_person(updated)

      {:ok, _} =
        Log.entry(
          scope,
          {:person, updated.id},
          "#{actor(scope)} named '#{old_display_name}': #{Person.display_name(updated)}"
        )

      Realtime.broadcast_change(@person_resource, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc """
  Updates a person. Logs one activity entry per user-facing field that actually changed
  (`XC-10`), e.g. "Wannes changed the want tier of 'Anna Peeters': Yes → Maybe" or
  "Wannes changed the group of 'Anna Peeters': none → Family Peeters" — old/new values
  rendered the way the UI shows them. Broadcasts `{:updated, person}` (`XC-01`) once,
  after every log entry is written.

  For a +1, accepts names, age, notes and `plus_one_status` (label "+1 status", values
  "Possible"/"Confirmed"); `want_tier`, `certainty` and `group_id` are refused by
  `Person.plus_one_changeset/2` with "is inherited from the host" (`PER-15`, `DR-32`).
  Old/new display names in the log line resolve correctly even for an unnamed +1 (its
  `:host` is preloaded first).
  """
  @spec update_person(Scope.t(), Person.t(), map()) ::
          {:ok, Person.t()} | {:error, Ecto.Changeset.t()}
  def update_person(%Scope{} = scope, %Person{} = person, attrs) do
    changeset = change_person(person, attrs)

    with {:ok, updated} <- Repo.update(changeset) do
      before = preload_person(person)
      updated = preload_person(updated)
      :ok = log_person_field_changes(scope, before, updated, changeset)
      Realtime.broadcast_change(@person_resource, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc """
  `PER-20`..`PER-23`: designates `person` as a witness of `user_id` (one of the two
  users), or removes the designation when `user_id` is `nil`.

  Designating forces want tier *obligated* and certainty *certain* and makes the person
  *accepted* for every event (`Invitations.accept_all_events/2`), as one
  `Log.action/3`: "Wannes made 'Anna Peeters' a witness of Wannes", the invitation
  changes as children. Removing only clears the designation (`PER-22`).

  Refused: `{:error, :plus_one}` for a +1; `{:error, :unknown_user}` when `user_id` is not
  one of the couple (`Users.assignable?/1`); `{:error, :limit}` when `user_id` already
  has 2 other witnesses.
  """
  @spec set_witness(Scope.t(), Person.t(), term() | nil) ::
          {:ok, Person.t()} | {:error, :plus_one | :unknown_user | :limit}
  def set_witness(%Scope{} = scope, %Person{} = person, nil) do
    person = Repo.get!(Person, person.id)

    if Person.witness?(person) do
      before = preload_person(person)

      {:ok, updated} =
        Log.action(
          scope,
          "#{actor(scope)} removed '#{Person.display_name(before)}' as witness",
          fn ->
            {:ok, updated} = person |> Ecto.Changeset.change(witness_of_id: nil) |> Repo.update()
            updated
          end
        )

      updated = preload_person(updated)
      Realtime.broadcast_change(@person_resource, {:updated, updated})
      {:ok, updated}
    else
      {:ok, preload_person(person)}
    end
  end

  def set_witness(%Scope{} = scope, %Person{} = person, user_id) do
    person = Repo.get!(Person, person.id)

    cond do
      Person.plus_one?(person) ->
        {:error, :plus_one}

      not WeddingPlanner.Accounts.Users.assignable?(user_id) ->
        {:error, :unknown_user}

      person.witness_of_id == user_id ->
        {:ok, preload_person(person)}

      witness_count(user_id, person.id) >= @max_witnesses ->
        {:error, :limit}

      true ->
        designate_witness(scope, person, user_id)
    end
  end

  defp designate_witness(scope, person, user_id) do
    user = Repo.get!(User, user_id)
    name = Person.display_name(preload_person(person))

    {:ok, {updated, tuples}} =
      Log.action(scope, "#{actor(scope)} made '#{name}' a witness of #{user.display_name}", fn ->
        {:ok, updated} =
          person
          |> Ecto.Changeset.change(
            witness_of_id: user_id,
            want_tier: :obligated,
            certainty: :certain
          )
          |> Repo.update()

        {updated, WeddingPlanner.Invitations.accept_all_events(scope, updated)}
      end)

    updated = preload_person(updated)
    WeddingPlanner.Invitations.broadcast_accepted(tuples)
    Realtime.broadcast_change(@person_resource, {:updated, updated})
    {:ok, updated}
  end

  defp witness_count(user_id, except_person_id) do
    Repo.aggregate(
      from(p in Person, where: p.witness_of_id == ^user_id and p.id != ^except_person_id),
      :count
    )
  end

  @doc """
  Deletes a person, logs it (`XC-10`) and broadcasts `{:deleted, id}` (`XC-01`).

  A +1 is deleted alone, exactly as any other person. A **host with +1s** deletes them
  too (`PER-16`): one `WeddingPlanner.Log.action/3` writes a summary naming the host and
  every +1 ("Wannes deleted 'Anna Peeters' and 1 +1: Tom Wils"), then one child entry per
  +1 (deleted first — the self-FK is `on_delete: :restrict`), then the host's own entry;
  `{:deleted, id}` is broadcast for all of them after commit. A host with no +1s keeps
  the single-entry behaviour unchanged.
  """
  @spec delete_person(Scope.t(), Person.t()) :: {:ok, Person.t()} | {:error, Ecto.Changeset.t()}
  def delete_person(%Scope{} = scope, %Person{} = person) do
    if Person.plus_one?(person) do
      delete_single_person(scope, person)
    else
      case plus_ones_of(person) do
        [] -> delete_single_person(scope, person)
        plus_ones -> delete_host_with_plus_ones(scope, person, plus_ones)
      end
    end
  end

  @doc """
  What deleting `person` would affect, in the shape
  `WeddingPlannerWeb.CoreComponents.destructive_confirm/1` takes (`PER-16`, `XC-40`,
  `DR-38`).

  For a host with +1s, one entry naming them: `%{label: "Also deletes their +1: Tom
  Wils", count: 1}`, plural "their 2 +1s: …" for more than one — `[]` for a +1 or for a
  host with no +1s. Then, whatever the invitations/opt-outs that deleting `person` (and,
  for a host, its +1s) would remove: `%{label: "Also removes 3 invitations", count: 3}`
  and/or `%{label: "Also removes 1 +1 opt-out", count: 1}` (singular/plural correct),
  each present only when its count is non-zero.
  """
  @spec person_deletion_effects(Person.t()) :: [%{label: String.t(), count: non_neg_integer()}]
  def person_deletion_effects(%Person{} = person) do
    plus_one_effect =
      if Person.plus_one?(person) do
        []
      else
        case plus_ones_of(person) do
          [] ->
            []

          plus_ones ->
            plus_ones =
              plus_ones |> Enum.sort_by(& &1.id) |> Enum.map(&Map.put(&1, :host, person))

            names = plus_ones |> Enum.map(&Person.display_name/1) |> Enum.join(", ")
            count = length(plus_ones)

            [%{label: "Also deletes #{their_plus_ones_phrase(count)}: #{names}", count: count}]
        end
      end

    plus_one_effect ++ invitation_effects(deletion_ids(person))
  end

  @doc """
  What bulk-deleting `persons` would additionally affect beyond the persons themselves
  (`PER-16`, `XC-40`, `DR-38`): every +1 that `bulk_delete_persons/2` would pull in from
  a selected host but that is not already in `persons` itself, named the same way
  `person_deletion_effects/1` does — omitted when the expanded set adds nothing. Then,
  the same invitation/opt-out effects `person_deletion_effects/1` reports, but summed
  over **every** person the bulk delete would actually remove (the expanded set, not
  just `persons`).
  """
  @spec bulk_deletion_effects([Person.t()]) :: [%{label: String.t(), count: non_neg_integer()}]
  def bulk_deletion_effects(persons) when is_list(persons) do
    selected_ids = MapSet.new(persons, & &1.id)
    expanded = expand_with_plus_ones(persons)
    extra = Enum.reject(expanded, &MapSet.member?(selected_ids, &1.id))

    plus_one_effect =
      case extra do
        [] ->
          []

        extra ->
          names = extra |> Enum.map(&Person.display_name/1) |> Enum.join(", ")
          count = length(extra)
          [%{label: "Also deletes #{their_plus_ones_phrase(count)}: #{names}", count: count}]
      end

    plus_one_effect ++ invitation_effects(Enum.map(expanded, & &1.id))
  end

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
  (`PER-04`). **+1s are skipped entirely** (`PER-15`, `DR-34`: not editable — a group
  "select all" may well include a group's +1s, so this has to be silent, not an error).
  One `WeddingPlanner.Log.action/3`: children only for the (non-+1) persons whose value
  actually changes, the summary counting those ("Wannes set 3 people to want tier
  Maybe"); when the editable persons are exactly every member of one group, the summary
  names it ("Wannes set 4 people in 'Family Peeters' to want tier Maybe", `XC-12`'s own
  example) — `sole_group/1`'s member-count check already ignores +1s for free, since a
  +1 never has a `group_id` of its own (`DR-32`) and `persons` here has already been
  filtered down to non-+1s before that check runs. Writes no group-level state
  (`PER-04`'s last sentence) — only the persons themselves.
  """
  @spec bulk_update_persons(
          Scope.t(),
          [Person.t()],
          :want_tier | :certainty,
          Person.want_tier() | Person.certainty()
        ) :: {:ok, [Person.t()]}
  def bulk_update_persons(%Scope{} = scope, persons, field, value)
      when is_list(persons) and field in [:want_tier, :certainty] do
    # PER-21/22: +1s and witnesses (fixed tier and certainty) are skipped silently.
    persons = Enum.reject(persons, &(Person.plus_one?(&1) or Person.witness?(&1)))
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
  action that names them"). Selecting a host **expands the selection with that host's
  +1s** (`PER-16`, `DR-34`) — directly selecting a +1 whose host is *not* selected just
  deletes that +1; selecting both a host and one of its own +1s does not double-delete
  it. One `WeddingPlanner.Log.action/3`: a summary naming the (expanded) count and every
  name ("Wannes deleted 3 people: Griet Van Acker, Ines Van Acker, Bo"), plus one child
  entry per person, **+1s deleted before hosts** (the self-FK is `on_delete: :restrict`).
  Every deleted person's own invitations/opt-outs are removed first, inside the same
  transaction (`DR-38`, `Invitations.delete_for_persons/1`), and each child entry's
  wording is extended with the count removed, e.g. "... (3 invitations removed)".
  """
  @spec bulk_delete_persons(Scope.t(), [Person.t()]) :: {:ok, [Person.t()]}
  def bulk_delete_persons(%Scope{} = scope, persons) when is_list(persons) do
    expanded = expand_with_plus_ones(persons)
    names = expanded |> Enum.map(&Person.display_name/1) |> Enum.join(", ")
    count = length(expanded)
    summary = "#{actor(scope)} deleted #{count} #{pluralize_person(count)}: #{names}"

    {plus_ones, hosts} = Enum.split_with(expanded, &Person.plus_one?/1)
    counts_by_id = Map.new(expanded, &{&1.id, deletion_counts([&1.id])})

    {:ok, deleted} =
      Log.action(scope, summary, fn ->
        _ = delete_dependents(Enum.map(expanded, & &1.id))

        Enum.map(plus_ones ++ hosts, fn person ->
          {:ok, deleted} = Repo.delete(person)

          {:ok, _} =
            Log.entry(
              scope,
              {:person, deleted.id},
              "#{actor(scope)} deleted '#{Person.display_name(deleted)}'" <>
                deletion_suffix(Map.fetch!(counts_by_id, deleted.id))
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
  deleted)"), then `WeddingPlanner.Presets.detach_group/2` (`DR-53`) rewrites every
  headcount preset naming this group (one child entry per affected preset), then the
  group's own delete entry. Broadcasts `{:updated, person}` for every ungrouped member,
  `{:updated, preset}` for every affected preset, and `{:deleted, id}` for the group
  (`XC-01`) — all only after the transaction commits.
  """
  @spec delete_group(Scope.t(), Group.t()) :: {:ok, Group.t()}
  def delete_group(%Scope{} = scope, %Group{} = group) do
    members = members_of(group)
    count = length(members)

    summary =
      "#{actor(scope)} deleted group '#{group.name}' (#{count} #{pluralize_person(count)} ungrouped)"

    {:ok, {deleted, ungrouped, detached_presets}} =
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

        detached_presets = Presets.detach_group(scope, group)

        {:ok, deleted} = Repo.delete(group)

        {:ok, _} =
          Log.entry(
            scope,
            {:group, deleted.id},
            "#{actor(scope)} deleted group '#{deleted.name}'"
          )

        {deleted, ungrouped, detached_presets}
      end)

    ungrouped = Enum.map(ungrouped, &preload_person/1)
    Enum.each(ungrouped, &Realtime.broadcast_change(@person_resource, {:updated, &1}))

    Enum.each(
      detached_presets,
      &Realtime.broadcast_change(@headcount_preset_resource, {:updated, &1})
    )

    Realtime.broadcast_change(@group_resource, {:deleted, deleted.id})
    {:ok, deleted}
  end

  @doc """
  What deleting `group` would affect (`PER-07`, `XC-40`): `[]` when it has no members and
  no preset names it. Members give one `%{label:, count:}` entry, e.g. `%{label: "4
  people become ungrouped, not deleted", count: 4}`. Every headcount preset naming this
  group (`WeddingPlanner.Presets.presets_naming_group/1`, `DR-53`) adds its own entry:
  `"Preset 'X' will no longer be restricted by group"` when this is the *only* group in
  that preset's criterion (the criterion becomes empty, i.e. unrestricted — `HC-02`), or
  `"Preset 'X' stops filtering on this group"` otherwise; each counted as `1`.
  """
  @spec group_deletion_effects(Group.t()) :: [%{label: String.t(), count: non_neg_integer()}]
  def group_deletion_effects(%Group{} = group) do
    member_effects =
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

    preset_effects =
      group
      |> Presets.presets_naming_group()
      |> Enum.map(&preset_group_deletion_effect(&1, group))

    member_effects ++ preset_effects
  end

  # -- activity-log links ---------------------------------------------------------------

  @doc """
  `WeddingPlanner.Log.EntityRef` resolver for the `"person"` entity type (`DR-26` Q9):
  an existing person resolves to their display name and `/people/<id>`; a deleted one
  is `:error` (degrades to plain text). `:host` is preloaded so an unnamed +1 resolves to
  "+1 of Anna Peeters" instead of crashing or showing an empty name (`PER-11`).
  """
  @spec resolve_person_log_entity(term()) :: {:ok, String.t(), String.t() | nil} | :error
  def resolve_person_log_entity(id) do
    case Repo.get(Person, id) do
      nil -> :error
      person -> {:ok, person |> Repo.preload(:host) |> Person.display_name(), "/people/#{id}"}
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

  defp preload_person(%Person{} = person),
    do: Repo.preload(person, [:group, :plus_ones, host: :group])

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

  # `DR-34`: a host unit is `{host, plus_ones}`, `plus_ones` ordered by id — built
  # explicitly here rather than relying on the encounter order `Repo.all/1` happens to
  # return (the invites-v4 bug this rule cites: a +1 rendered at the bottom of its group
  # instead of under its host). Every +1's `:host` is set to the host struct we already
  # have in hand, so `Person.display_name/1` works on an unnamed +1 in the result without
  # a second query.
  defp build_host_units(persons) do
    {hosts, plus_ones} = Enum.split_with(persons, &(not Person.plus_one?(&1)))

    plus_ones_by_host_id =
      plus_ones
      |> Enum.sort_by(& &1.id)
      |> Enum.group_by(& &1.host_id)

    Enum.map(hosts, fn host ->
      unit_plus_ones =
        plus_ones_by_host_id
        |> Map.get(host.id, [])
        |> Enum.map(&Map.put(&1, :host, host))

      {host, unit_plus_ones}
    end)
  end

  # A unit is included if the host or **any** of its +1s matches (`DR-34`); the host is
  # passed alongside every member so a +1's filter values are its inherited ones.
  defp unit_matches_filters?({host, plus_ones}, filters) do
    Enum.any?([host | plus_ones], &matches_filters?(&1, filters, host))
  end

  defp matches_filters?(person, filters, host) do
    Enum.all?(filters, fn {key, value} -> matches_filter?(person, key, value, host) end)
  end

  defp matches_filter?(_person, _key, nil, _host), do: true
  defp matches_filter?(person, :text, text, _host), do: matches_text?(person, text)

  defp matches_filter?(person, :group_id, :ungrouped, host),
    do: is_nil(PlusOne.group_id(person, host))

  defp matches_filter?(person, :group_id, group_id, host),
    do: PlusOne.group_id(person, host) == group_id

  defp matches_filter?(person, :age_category, value, _host), do: person.age_category == value

  defp matches_filter?(person, :want_tier, value, host),
    do: PlusOne.want_tier(person, host) == value

  defp matches_filter?(person, :certainty, value, host),
    do: PlusOne.certainty(person, host) == value

  defp matches_text?(_person, ""), do: true

  defp matches_text?(person, text) do
    needle = String.downcase(text)

    [person.first_name, person.last_name, person.notes]
    |> Enum.any?(fn
      nil -> false
      value -> value |> String.downcase() |> String.contains?(needle)
    end)
  end

  defp plus_ones_of(%Person{id: id}) do
    Person
    |> where([p], p.host_id == ^id)
    |> Repo.all()
  end

  # `DR-34`: selecting a host pulls in every one of its +1s; a +1 directly selected whose
  # host is *not* in the selection is kept on its own (an "orphan"); a +1 directly
  # selected whose host *is* in the selection is not duplicated — `plus_ones_of/1`
  # already returns it, host-tagged, as part of that host's unit.
  defp expand_with_plus_ones(persons) do
    hosts = Enum.reject(persons, &Person.plus_one?/1)
    host_ids = MapSet.new(hosts, & &1.id)

    orphan_plus_ones =
      persons
      |> Enum.filter(&Person.plus_one?/1)
      |> Enum.reject(&MapSet.member?(host_ids, &1.host_id))
      |> Enum.map(&preload_person/1)

    host_units =
      Enum.flat_map(hosts, fn host ->
        plus_ones =
          host
          |> plus_ones_of()
          |> Enum.sort_by(& &1.id)
          |> Enum.map(&Map.put(&1, :host, host))

        [host | plus_ones]
      end)

    host_units ++ orphan_plus_ones
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
  defp field_label(:plus_one_status), do: "+1 status"
  defp field_label(:fine_anywhere), do: "fine anywhere"
  defp field_label(:name), do: "name"
  defp field_label(:type_label), do: "type label"

  defp display_value(:group_id, id), do: group_display_name(id)
  defp display_value(:age_category, value), do: age_category_label(value)
  defp display_value(:want_tier, value), do: want_tier_label(value)
  defp display_value(:certainty, value), do: certainty_label(value)
  defp display_value(:plus_one_status, value), do: plus_one_status_label(value)
  defp display_value(:fine_anywhere, true), do: "on"
  defp display_value(:fine_anywhere, false), do: "off"
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

  defp plus_one_status_label(:possible), do: "Possible"
  defp plus_one_status_label(:confirmed), do: "Confirmed"

  defp group_display_name(nil), do: "none"

  defp group_display_name(id) do
    case Repo.get(Group, id) do
      nil -> "none"
      group -> group.name
    end
  end

  defp pluralize_person(1), do: "person"
  defp pluralize_person(_n), do: "people"

  # `DR-53`: `group_ids == [group.id]` means this group is the *only* one in that
  # preset's criterion, so deleting it leaves the criterion empty — i.e. unrestricted
  # (`HC-02`) — which gets its own, stronger wording than "stops filtering".
  defp preset_group_deletion_effect(%HeadcountPreset{group_ids: [group_id], name: name}, %Group{
         id: group_id
       }) do
    %{label: "Preset '#{name}' will no longer be restricted by group", count: 1}
  end

  defp preset_group_deletion_effect(%HeadcountPreset{name: name}, %Group{}) do
    %{label: "Preset '#{name}' stops filtering on this group", count: 1}
  end

  # -- +1 helpers ------------------------------------------------------------------------

  defp with_default_plus_one_status(attrs) do
    if Map.has_key?(attrs, :plus_one_status) or Map.has_key?(attrs, "plus_one_status") do
      attrs
    else
      # `attrs` must stay uniformly atom- or string-keyed for `Ecto.Changeset.cast/3` (it
      # rejects a mixed-key map), so the default is added using whichever style `attrs`
      # already uses — string if any string key is present, atom otherwise (including an
      # empty map).
      key =
        if Enum.any?(Map.keys(attrs), &is_binary/1), do: "plus_one_status", else: :plus_one_status

      Map.put(attrs, key, :possible)
    end
  end

  # `PER-10`: a +1's host must exist and must not itself be a +1 (no chains). Re-checked
  # with a fresh query, the same split `validate_group_exists/1` uses for `group_id` —
  # this project's SQLite adapter cannot turn a raw constraint violation into a changeset
  # error (see this module's moduledoc), and "not itself a +1" cannot be a database CHECK
  # at all (it needs to look at another row).
  defp validate_host_for_plus_one(changeset, %Person{id: host_id}) do
    case Repo.get(Person, host_id) do
      nil ->
        Ecto.Changeset.add_error(changeset, :host_id, "does not exist")

      %Person{} = fresh_host ->
        if Person.plus_one?(fresh_host) do
          Ecto.Changeset.add_error(changeset, :host_id, "must not itself be a +1")
        else
          changeset
        end
    end
  end

  defp plus_one_add_suffix(%Person{} = plus_one) do
    status = plus_one_status_label(plus_one.plus_one_status) |> String.downcase()

    if Person.name_known?(plus_one) do
      "#{status}, '#{Person.display_name(plus_one)}'"
    else
      "#{status}, unnamed"
    end
  end

  defp require_a_name_part(changeset) do
    first = Ecto.Changeset.get_field(changeset, :first_name)
    last = Ecto.Changeset.get_field(changeset, :last_name)

    if is_nil(first) and is_nil(last) do
      changeset
      |> Ecto.Changeset.add_error(:first_name, "must provide a first or last name")
      |> Ecto.Changeset.add_error(:last_name, "must provide a first or last name")
    else
      changeset
    end
  end

  # `DR-38`: a person's own invitations/opt-outs must be gone before the person row
  # can be (the FKs are `:restrict`), and their removal must be logged as part of the
  # same delete — so this has to become transactional exactly when there is something
  # to remove. `Repo.transaction/1`, not `Log.action/3`: the single entry this writes
  # must stay an ordinary per-entity entry (`{:person, id}`), not an untyped
  # `Log.action/3` summary with no entity of its own, so it is written (and the change
  # broadcast) only after the transaction commits — see `WeddingPlanner.Log`'s "Known
  # limitation" section for why that ordering matters.
  defp delete_single_person(scope, %Person{} = person) do
    person = preload_person(person)
    counts = deletion_counts([person.id])

    {:ok, deleted} =
      Repo.transaction(fn ->
        _ = delete_dependents([person.id])
        {:ok, deleted} = Repo.delete(person)
        deleted
      end)

    {:ok, _} =
      Log.entry(
        scope,
        {:person, deleted.id},
        "#{actor(scope)} deleted '#{Person.display_name(person)}'" <> deletion_suffix(counts)
      )

    Realtime.broadcast_change(@person_resource, {:deleted, deleted.id})
    {:ok, deleted}
  end

  defp delete_host_with_plus_ones(scope, %Person{} = host, plus_ones) do
    plus_ones = plus_ones |> Enum.sort_by(& &1.id) |> Enum.map(&Map.put(&1, :host, host))
    names = plus_ones |> Enum.map(&Person.display_name/1) |> Enum.join(", ")
    count = length(plus_ones)

    summary =
      "#{actor(scope)} deleted '#{Person.display_name(host)}' and #{count} #{pluralize_plus_one(count)}: #{names}"

    host_counts = deletion_counts([host.id])
    plus_one_counts = Map.new(plus_ones, &{&1.id, deletion_counts([&1.id])})
    all_ids = [host.id | Enum.map(plus_ones, & &1.id)]

    {:ok, {deleted_plus_ones, deleted_host}} =
      Log.action(scope, summary, fn ->
        _ = delete_dependents(all_ids)

        deleted_plus_ones =
          Enum.map(plus_ones, fn plus_one ->
            {:ok, deleted} = Repo.delete(plus_one)

            {:ok, _} =
              Log.entry(
                scope,
                {:person, deleted.id},
                "#{actor(scope)} deleted '#{Person.display_name(plus_one)}'" <>
                  deletion_suffix(Map.fetch!(plus_one_counts, plus_one.id))
              )

            deleted
          end)

        {:ok, deleted_host} = Repo.delete(host)

        {:ok, _} =
          Log.entry(
            scope,
            {:person, deleted_host.id},
            "#{actor(scope)} deleted '#{Person.display_name(host)}'" <>
              deletion_suffix(host_counts)
          )

        {deleted_plus_ones, deleted_host}
      end)

    Enum.each(deleted_plus_ones, &Realtime.broadcast_change(@person_resource, {:deleted, &1.id}))
    Realtime.broadcast_change(@person_resource, {:deleted, deleted_host.id})
    {:ok, deleted_host}
  end

  defp pluralize_plus_one(1), do: "+1"
  defp pluralize_plus_one(_n), do: "+1s"

  defp their_plus_ones_phrase(1), do: "their +1"
  defp their_plus_ones_phrase(n), do: "their #{n} +1s"

  # `DR-38`: ids this deletion path will additionally remove invitations/opt-outs for —
  # just `person` for a +1 or a host with no +1s, `person` plus every +1 for a host
  # with them (a host is never itself a +1, so it never has opt-outs of its own).
  defp deletion_ids(%Person{} = person) do
    if Person.plus_one?(person) do
      [person.id]
    else
      [person.id | Enum.map(plus_ones_of(person), & &1.id)]
    end
  end

  defp invitation_effects(ids) do
    counts = deletion_counts(ids)

    []
    |> add_effect_if_any(counts.invitations, &"Also removes #{&1} #{pluralize_invitation(&1)}")
    |> add_effect_if_any(counts.opt_outs, &"Also removes #{&1} #{pluralize_opt_out(&1)}")
    |> add_effect_if_any(counts.memberships, &"Also removes from #{&1} #{pluralize_circle(&1)}")
    |> add_effect_if_any(counts.rules, &"Also deletes #{&1} #{pluralize_rule(&1)}")
  end

  # SEAT-81: a person's circle memberships and seating rules go with them, next to their
  # invitations and opt-outs (`DR-38`) — one count map for the confirmation and the log.
  defp deletion_counts(ids),
    do: Map.merge(Invitations.deletion_counts(ids), Seating.deletion_counts(ids))

  defp delete_dependents(ids) do
    _ = Invitations.delete_for_persons(ids)
    Seating.delete_for_persons(ids)
  end

  defp add_effect_if_any(acc, 0, _label_fun), do: acc
  defp add_effect_if_any(acc, n, label_fun), do: acc ++ [%{label: label_fun.(n), count: n}]

  # `DR-38`'s exact wording for a person's own delete entry, appended when it removed
  # any invitations/opt-outs — "" (no suffix) when there was nothing to remove. A
  # single person is either a host (invitations only, never opt-outs of its own) or a
  # +1 (opt-outs only, never invitations), so the two never both apply to one call.
  # SEAT-81 extends it with circle memberships and seating rules, in the same list.
  defp deletion_suffix(counts) do
    parts =
      for {key, word} <- [
            invitations: &pluralize_invitation/1,
            opt_outs: &pluralize_opt_out/1,
            memberships: &pluralize_membership/1,
            rules: &pluralize_rule/1
          ],
          Map.get(counts, key, 0) > 0,
          do: "#{Map.fetch!(counts, key)} #{word.(Map.fetch!(counts, key))}"

    case parts do
      [] -> ""
      parts -> " (#{Enum.join(parts, ", ")} removed)"
    end
  end

  defp pluralize_invitation(1), do: "invitation"
  defp pluralize_invitation(_n), do: "invitations"

  defp pluralize_opt_out(1), do: "+1 opt-out"
  defp pluralize_opt_out(_n), do: "+1 opt-outs"

  defp pluralize_circle(1), do: "circle"
  defp pluralize_circle(_n), do: "circles"

  defp pluralize_membership(1), do: "circle membership"
  defp pluralize_membership(_n), do: "circle memberships"

  defp pluralize_rule(1), do: "seating rule"
  defp pluralize_rule(_n), do: "seating rules"

  defp actor(%Scope{user: %User{display_name: name}}), do: name
end
