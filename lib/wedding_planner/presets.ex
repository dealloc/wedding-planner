defmodule WeddingPlanner.Presets do
  @moduledoc """
  Headcount presets CRUD (`docs/modules/headcount.md` `HC-02`, `HC-06`, `HC-07`;
  `DR-53`, `DR-54`), resource `:headcount_preset`, entity type `"headcount_preset"`.

  This is slice G5's data layer, following `WeddingPlanner.Events`'s exemplar pattern:
  context CRUD, per-field activity logging (`XC-10`), reordering
  (`WeddingPlanner.Events.move_event/3`'s pattern) and PubSub (`XC-01`) — the
  `/headcount` screen itself is tasks 61/62.

  ## Criteria and identity (`HC-02`, `DR-53`)

  A preset has five criteria — `invitation_statuses`, `certainties`, `want_tiers`,
  `age_categories`, `group_ids` — each a set of allowed values where an empty set means
  "no restriction". `WeddingPlanner.Presets.HeadcountPreset.changeset/2` stores each one
  de-duplicated in a fixed order (see that module), so two presets naming the same
  values are always structurally equal and log identically. `group_ids` cannot be
  checked by a database CHECK (SQLite forbids subqueries there), so `change_preset/2`
  validates each id with `Repo.exists?/1` here, mirroring
  `WeddingPlanner.Guests.change_person/2`'s `group_id` check.

  Names are trimmed, required, at most 60 characters, and unique **case-insensitively**
  (`change_preset/2`'s own query, the same `String.downcase/1` + `Repo.all/1` pattern as
  `WeddingPlanner.Categories.validate_name_unique_in_category/3` — SQLite's `lower()`
  only folds ASCII) — the plain `unique_index(:headcount_presets, [:name])` from `DR-47`
  is only a case-sensitive backstop.

  ## Role, and the three defaults are locked (`DR-53`, `DR-54` **revised**)

  **`DR-54` revised (binding orchestrator ruling, 2026-09-24 — supersedes the original
  DR-54 and HC-06's "editable and deletable like any other" for the three seeded
  defaults):** the user ruled that the three seeded presets can be assumed stable, so
  they are now **locked**. `role` (`nil | :minimum | :likely | :maximum`) identifies
  which of them a row is — the *likely*-role preset is the default single-figure
  choice, the *minimum*/*maximum*-role presets are the range's two ends — and a preset
  holding a role (`role != nil`) is, by construction, one of the three defaults. Calling
  `update_preset/3` or `delete_preset/2` on one now returns `{:error,
  :default_preset_locked}` and changes nothing (no rename, no criteria edit, no
  delete). `role` itself is no longer castable through either `update_preset/3` or
  `create_preset/2` — `change_preset/2` strips any `"role"`/`:role` key from `attrs`
  before it ever reaches the schema changeset, so a custom preset's `role` always stays
  `nil` and a default's `role` can never move to another row. The old role-move
  transaction (`update_with_role_move/5`, `find_role_holder/2`) is gone — nothing can
  reach it any more. **Unaffected:** `move_preset/3` — reordering is presentation, not a
  preset's identity, and stays allowed for every preset, defaults included.

  ## Group deletion (`PER-07`, `DR-53`)

  `detach_group/2` is called by `WeddingPlanner.Guests.delete_group/2`, **inside** that
  function's own `Log.action/3` (never wrapping its own — the calling entries must nest
  under the group's summary, `XC-12`). It rewrites every preset naming the deleted group,
  logs one child entry per affected preset, and returns the updated rows so the caller
  broadcasts them only after its own transaction commits (`WeddingPlanner.Log`'s "Known
  limitation" — broadcasting inside a bare `Repo.transaction` would fire before commit).
  `presets_naming_group/1` and `WeddingPlanner.Guests.group_deletion_effects/1`'s two
  wordings ("stops filtering on this group" / "will no longer be restricted by group")
  are what the deletion confirmation shows beforehand (`XC-40`).

  ## Activity log (`XC-10`) and PubSub (`XC-01`, `XC-02`)

  Every mutation writes through `WeddingPlanner.Log` and broadcasts the whole resulting
  record via `WeddingPlanner.Realtime` (resource `:headcount_preset`) only after its
  write succeeds. `move_preset/3` and a role move each touch two rows, so each goes
  through `Log.action/3` (one summarising entry plus one child entry per affected
  preset, `XC-12`) rather than independent `Log.entry/3` calls.
  """

  import Ecto.Query

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Guests.Group
  alias WeddingPlanner.Log
  alias WeddingPlanner.Presets.HeadcountPreset
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo

  @resource :headcount_preset

  @loggable_fields [
    :name,
    :invitation_statuses,
    :certainties,
    :want_tiers,
    :age_categories,
    :group_ids
  ]

  @doc "Every preset, in manual sort order — `sort_order`, then `id` (mirrors `HC-06`'s display order)."
  @spec list_presets() :: [HeadcountPreset.t()]
  def list_presets do
    HeadcountPreset
    |> order_by([p], asc: p.sort_order, asc: p.id)
    |> Repo.all()
  end

  @doc "Fetches one preset by id. Raises `Ecto.NoResultsError` if it does not exist."
  @spec get_preset!(term()) :: HeadcountPreset.t()
  def get_preset!(id), do: Repo.get!(HeadcountPreset, id)

  @doc """
  A changeset for building/validating a preset form (create or edit) — never persists on
  its own. Adds the two checks that need a query on top of
  `HeadcountPreset.changeset/2`'s structural rules: each `group_ids` entry must name an
  existing group (`Repo.exists?/1` — SQLite cannot check this in a CHECK), and `name`
  must be unique case-insensitively among the other presets.

  `DR-54` revised: `role` is dropped from `attrs` here, before it ever reaches
  `HeadcountPreset.changeset/2` — the single point that makes `role` uncastable through
  `create_preset/2`/`update_preset/3`, whatever key type (`"role"` or `:role`) a caller
  used.
  """
  @spec change_preset(HeadcountPreset.t(), map()) :: Ecto.Changeset.t()
  def change_preset(%HeadcountPreset{} = preset, attrs \\ %{}) do
    preset
    |> HeadcountPreset.changeset(Map.drop(attrs, ["role", :role]))
    |> validate_group_ids_exist()
    |> validate_name_unique()
  end

  @doc """
  Creates a preset, appended after the current last one (same never-reorders-existing
  pattern as `WeddingPlanner.Events.create_event/2`), logs the create (`XC-10`) and
  broadcasts `{:created, preset}` (`XC-01`).
  """
  @spec create_preset(Scope.t(), map()) ::
          {:ok, HeadcountPreset.t()} | {:error, Ecto.Changeset.t()}
  def create_preset(%Scope{} = scope, attrs) do
    %HeadcountPreset{sort_order: next_sort_order()}
    |> change_preset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, preset} ->
        {:ok, _} =
          Log.entry(
            scope,
            {:headcount_preset, preset.id},
            "#{actor(scope)} created preset '#{preset.name}'"
          )

        Realtime.broadcast_change(@resource, {:created, preset})
        {:ok, preset}

      error ->
        error
    end
  end

  @doc """
  Updates a preset's name and/or criteria. Logs one activity entry per user-facing field
  that actually changed (`XC-10`) — criteria as comma-joined human labels ("any" for an
  empty set), `group_ids` by group name.

  **`DR-54` revised: refused on a locked default.** A preset holding a role (`role !=
  nil`, i.e. one of the three seeded defaults) returns `{:error,
  :default_preset_locked}` immediately — no changeset is even built, nothing is
  touched, nothing is logged. `role` cannot be part of `attrs` in the first place
  (`change_preset/2` strips it), so there is no "role move" path any more; a custom
  preset (`role` always `nil`) updates exactly as before.
  """
  @spec update_preset(Scope.t(), HeadcountPreset.t(), map()) ::
          {:ok, HeadcountPreset.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :default_preset_locked}
  def update_preset(%Scope{} = _scope, %HeadcountPreset{role: role}, _attrs)
      when not is_nil(role) do
    {:error, :default_preset_locked}
  end

  def update_preset(%Scope{} = scope, %HeadcountPreset{} = preset, attrs) do
    changeset = change_preset(preset, attrs)

    if changeset.valid? do
      update_plain(scope, preset, changeset)
    else
      {:error, changeset}
    end
  end

  @doc """
  `HC-06` (`DR-54` revised): a locked default can never reach `delete_preset/2` (it
  refuses first), so deletion only ever happens to a custom preset — nothing is ever
  affected beyond the row itself. Kept as its own function, always `[]`, so a
  `destructive_confirm/1` call site needs no special case.
  """
  @spec preset_deletion_effects(HeadcountPreset.t()) :: [String.t()]
  def preset_deletion_effects(%HeadcountPreset{}), do: []

  @doc """
  Deletes `preset`. **`DR-54` revised: refused on a locked default** — a preset holding
  a role (one of the three seeded defaults) returns `{:error, :default_preset_locked}`
  and nothing is touched. Otherwise (always a custom preset — the last one included,
  `HC-06`) logs the delete (`XC-10`) and broadcasts `{:deleted, id}` (`XC-01`).
  """
  @spec delete_preset(Scope.t(), HeadcountPreset.t()) ::
          {:ok, HeadcountPreset.t()} | {:error, :default_preset_locked}
  def delete_preset(%Scope{} = _scope, %HeadcountPreset{role: role})
      when not is_nil(role) do
    {:error, :default_preset_locked}
  end

  def delete_preset(%Scope{} = scope, %HeadcountPreset{} = preset) do
    {:ok, deleted} = Repo.delete(preset)

    {:ok, _} =
      Log.entry(
        scope,
        {:headcount_preset, deleted.id},
        "#{actor(scope)} deleted preset '#{deleted.name}'"
      )

    Realtime.broadcast_change(@resource, {:deleted, deleted.id})
    {:ok, deleted}
  end

  @doc """
  Moves `preset` one position `:up` or `:down` in the manual sort order, swapping
  `sort_order` with its neighbour — same pattern as `WeddingPlanner.Events.move_event/3`.
  A no-op at either end of the list. Logged as one `Log.action/3` summary plus one child
  entry per affected preset (`XC-12`). Race-safe per `XC-02`.
  """
  @spec move_preset(Scope.t(), HeadcountPreset.t(), :up | :down) :: :ok
  def move_preset(%Scope{} = scope, %HeadcountPreset{} = preset, direction)
      when direction in [:up, :down] do
    presets = list_presets()

    case neighbor(presets, preset, direction) do
      :boundary ->
        :ok

      {:ok, neighbor} ->
        {:ok, {moved, moved_neighbor}} =
          Log.action(
            scope,
            "#{actor(scope)} moved '#{preset.name}' #{direction_word(direction)} in the preset order",
            fn -> swap_and_log(scope, preset, neighbor, direction) end
          )

        Realtime.broadcast_change(@resource, {:updated, moved})
        Realtime.broadcast_change(@resource, {:updated, moved_neighbor})
        :ok
    end
  end

  @doc """
  `PER-07`/`DR-53`: removes `group`'s id from every preset naming it. Must be called
  **inside** the caller's own `Log.action/3` (see `WeddingPlanner.Guests.delete_group/2`)
  — every entry this writes nests under that action's summary automatically
  (`WeddingPlanner.Log.entry/3`). Returns the updated presets so the caller broadcasts
  them after its transaction commits; this function never broadcasts on its own.
  """
  @spec detach_group(Scope.t(), Group.t()) :: [HeadcountPreset.t()]
  def detach_group(%Scope{} = scope, %Group{} = group) do
    group
    |> presets_naming_group()
    |> Enum.map(fn preset ->
      remaining_ids = Enum.reject(preset.group_ids, &(&1 == group.id))

      {:ok, updated} =
        preset
        |> Ecto.Changeset.change(group_ids: remaining_ids)
        |> Repo.update()

      {:ok, _} =
        Log.entry(
          scope,
          {:headcount_preset, updated.id},
          "#{actor(scope)} removed group '#{group.name}' from preset '#{preset.name}' (group deleted)"
        )

      updated
    end)
  end

  @doc "Every preset whose `group_ids` names `group` (`PER-07`, `DR-53`)."
  @spec presets_naming_group(Group.t()) :: [HeadcountPreset.t()]
  def presets_naming_group(%Group{id: group_id}) do
    list_presets() |> Enum.filter(&(group_id in &1.group_ids))
  end

  @doc """
  `WeddingPlanner.Log.EntityRef` resolver for the `"headcount_preset"` entity type: an
  existing preset resolves to its name and `/headcount` (the page lands in task 61; the
  path may 404 until then, same as `"offer"` before its own screen landed). A deleted
  preset is `:error` (degrades to plain text).
  """
  @spec resolve_log_entity(term()) :: {:ok, String.t(), String.t() | nil} | :error
  def resolve_log_entity(id) do
    case Repo.get(HeadcountPreset, id) do
      nil -> :error
      preset -> {:ok, preset.name, "/headcount"}
    end
  end

  # -- private ---------------------------------------------------------------

  defp update_plain(scope, preset, changeset) do
    with {:ok, updated} <- Repo.update(changeset) do
      :ok = log_field_changes(scope, preset, updated, changeset)
      Realtime.broadcast_change(@resource, {:updated, updated})
      {:ok, updated}
    end
  end

  # `update_with_role_move/5`/`find_role_holder/2` (the pre-revision role-move
  # transaction) are gone: `DR-54` revised makes `role` uncastable through this module
  # (`change_preset/2` strips it) and locks every role holder out of `update_preset/3`
  # before a changeset is even built — nothing can reach a role move any more.

  defp validate_group_ids_exist(changeset) do
    case Ecto.Changeset.get_change(changeset, :group_ids) do
      nil ->
        changeset

      [] ->
        changeset

      ids ->
        existing =
          Group |> where([g], g.id in ^ids) |> select([g], g.id) |> Repo.all() |> MapSet.new()

        if Enum.all?(ids, &MapSet.member?(existing, &1)) do
          changeset
        else
          Ecto.Changeset.add_error(changeset, :group_ids, "refers to a group that does not exist")
        end
    end
  end

  # `HC-02`/`DR-53`: case-insensitive, Unicode-aware (`String.downcase/1` — never
  # SQLite's ASCII-only `lower()`) uniqueness among presets. Mirrors
  # `WeddingPlanner.Categories.validate_name_unique_in_category/3`.
  defp validate_name_unique(changeset) do
    case Ecto.Changeset.get_change(changeset, :name) do
      nil ->
        changeset

      name ->
        normalized = String.downcase(name)
        exclude_id = changeset.data.id

        clashing =
          HeadcountPreset
          |> exclude_id(exclude_id)
          |> Repo.all()
          |> Enum.find(&(String.downcase(&1.name) == normalized))

        case clashing do
          nil ->
            changeset

          %HeadcountPreset{name: clashing_name} ->
            Ecto.Changeset.add_error(changeset, :name, "is already used by '#{clashing_name}'")
        end
    end
  end

  defp exclude_id(query, nil), do: query
  defp exclude_id(query, id), do: where(query, [p], p.id != ^id)

  defp next_sort_order do
    case Repo.aggregate(HeadcountPreset, :max, :sort_order) do
      nil -> 0
      max -> max + 1
    end
  end

  defp neighbor(presets, %HeadcountPreset{id: id}, :up) do
    case Enum.find_index(presets, &(&1.id == id)) do
      nil -> :boundary
      0 -> :boundary
      idx -> {:ok, Enum.at(presets, idx - 1)}
    end
  end

  defp neighbor(presets, %HeadcountPreset{id: id}, :down) do
    last_index = length(presets) - 1

    case Enum.find_index(presets, &(&1.id == id)) do
      nil -> :boundary
      ^last_index -> :boundary
      idx -> {:ok, Enum.at(presets, idx + 1)}
    end
  end

  defp swap_and_log(scope, preset, neighbor, direction) do
    {:ok, moved} =
      preset |> HeadcountPreset.sort_order_changeset(neighbor.sort_order) |> Repo.update()

    {:ok, moved_neighbor} =
      neighbor |> HeadcountPreset.sort_order_changeset(preset.sort_order) |> Repo.update()

    {:ok, _} =
      Log.entry(
        scope,
        {:headcount_preset, moved.id},
        "#{actor(scope)} moved '#{moved.name}' #{direction_word(direction)}"
      )

    {:ok, _} =
      Log.entry(
        scope,
        {:headcount_preset, moved_neighbor.id},
        "#{actor(scope)} moved '#{moved_neighbor.name}' #{direction_word(opposite(direction))} (swapped with '#{moved.name}')"
      )

    {moved, moved_neighbor}
  end

  defp direction_word(:up), do: "up"
  defp direction_word(:down), do: "down"

  defp opposite(:up), do: :down
  defp opposite(:down), do: :up

  defp log_field_changes(
         scope,
         %HeadcountPreset{} = before,
         %HeadcountPreset{} = updated,
         changeset
       ) do
    changeset.changes
    |> Map.keys()
    |> Enum.filter(&(&1 in @loggable_fields))
    |> Enum.each(fn field ->
      old = display_value(field, Map.fetch!(before, field))
      new = display_value(field, Map.fetch!(updated, field))

      {:ok, _} =
        Log.entry(
          scope,
          {:headcount_preset, updated.id},
          "#{actor(scope)} changed the #{field_label(field)} of '#{before.name}': #{old} → #{new}"
        )
    end)

    :ok
  end

  defp field_label(:invitation_statuses), do: "invitation statuses"
  defp field_label(:want_tiers), do: "want tiers"
  defp field_label(:age_categories), do: "age categories"
  defp field_label(:group_ids), do: "groups"
  defp field_label(field), do: to_string(field)

  defp display_value(:name, value), do: value
  defp display_value(:group_ids, []), do: "any"
  defp display_value(:group_ids, ids), do: ids |> Enum.map(&group_name/1) |> Enum.join(", ")
  defp display_value(_field, []), do: "any"

  defp display_value(_field, values) when is_list(values),
    do: values |> Enum.map(&Phoenix.Naming.humanize/1) |> Enum.join(", ")

  defp group_name(id) do
    case Repo.get(Group, id) do
      nil -> "deleted group"
      group -> group.name
    end
  end

  defp actor(%Scope{user: %User{display_name: name}}), do: name
end
