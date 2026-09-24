defmodule WeddingPlanner.Presets.HeadcountPreset do
  @moduledoc """
  The stored row backing a **headcount preset** (`docs/modules/headcount.md` HC-02,
  HC-06; `DR-47`, `DR-53`). All five of HC-02's criteria are columns, each a JSON array
  — `invitation_statuses`, `certainties`, `want_tiers`, `age_categories` (atoms,
  enforced by `Ecto.Enum`) and `group_ids` (plain integers, existence checked by
  `WeddingPlanner.Presets` via `Repo.exists?/1` — SQLite forbids subqueries in a CHECK,
  so only "is this a JSON array" is enforced at the database, see the migration).
  `role` (`nil | :minimum | :likely | :maximum`) identifies which of `DR-54`'s roles
  this preset plays — nullable, at most one preset per role (a partial unique index),
  the three `HC-06` defaults seeded with their roles set by name.

  **`DR-54` revised (binding orchestrator ruling, 2026-09-24):** the three seeded
  defaults — the only rows a `role` column value ever identifies — are now **locked**:
  no rename, no criteria edit, no role change, no delete. `role` itself is no longer
  castable through `WeddingPlanner.Presets.create_preset/2`/`update_preset/3` (see that
  module for where and how); this schema's own `changeset/2` and `@castable` are
  unchanged (still declarative, still include `:role`) precisely because the lock is a
  context-level business rule, not a structural one — the same split this moduledoc
  already draws between the schema and `WeddingPlanner.Presets`.

  `changeset/2` and `WeddingPlanner.Presets` (this schema's context: create, update,
  delete, move, logging, PubSub) are `DR-53`'s G5 CRUD — the schema itself stays a thin,
  mostly-declarative wrapper; every rule that needs a query (name uniqueness, group
  existence) or that locks a row (the three defaults) lives in the context, same split
  as `WeddingPlanner.Categories`/`WeddingPlanner.Categories.Service`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Valuation.Preset

  @invitation_statuses [:planned, :invited, :accepted, :declined]
  @certainties [:certain, :likely, :uncertain]
  @want_tiers [:yes, :maybe, :no, :obligated]
  @age_categories [:adult, :child]
  @roles [:minimum, :likely, :maximum]

  @type t :: %__MODULE__{}

  schema "headcount_presets" do
    field :name, :string
    field :sort_order, :integer
    field :invitation_statuses, {:array, Ecto.Enum}, values: @invitation_statuses, default: []
    field :certainties, {:array, Ecto.Enum}, values: @certainties, default: []
    field :want_tiers, {:array, Ecto.Enum}, values: @want_tiers, default: []
    field :age_categories, {:array, Ecto.Enum}, values: @age_categories, default: []
    field :group_ids, {:array, :integer}, default: []
    field :role, Ecto.Enum, values: @roles

    timestamps(type: :utc_datetime)
  end

  @castable [
    :name,
    :invitation_statuses,
    :certainties,
    :want_tiers,
    :age_categories,
    :group_ids,
    :role
  ]

  @doc """
  Changeset for the user-facing fields (`HC-02`, `DR-53`): `name` (trimmed, required,
  at most 60 characters — case-insensitive/global uniqueness needs a query, so it is
  checked by `WeddingPlanner.Presets.change_preset/2`, not here), the five criteria
  (each de-duplicated and stored in a fixed order, so two presets naming the same
  values always compare equal and log the same way: `invitation_statuses`/
  `certainties`/`want_tiers`/`age_categories` in `WeddingPlanner.Valuation.Preset`'s own
  atom order, `group_ids` numerically ascending — existence of each id is, again, a
  context-level check) and `role`. `sort_order` is intentionally not castable here —
  see `WeddingPlanner.Presets.HeadcountPreset.sort_order_changeset/2`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(preset, attrs) do
    preset
    |> cast(attrs, @castable)
    |> update_change(:name, &trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 60)
    |> dedupe_ordered(:invitation_statuses, @invitation_statuses)
    |> dedupe_ordered(:certainties, @certainties)
    |> dedupe_ordered(:want_tiers, @want_tiers)
    |> dedupe_ordered(:age_categories, @age_categories)
    |> dedupe_group_ids()
  end

  @doc """
  Programmatic-only changeset for `HC-02`-order reordering
  (`WeddingPlanner.Presets.move_preset/3`). Never driven directly by user input.
  """
  @spec sort_order_changeset(t(), integer()) :: Ecto.Changeset.t()
  def sort_order_changeset(preset, sort_order) when is_integer(sort_order) do
    change(preset, sort_order: sort_order)
  end

  @doc """
  Converts a stored row into the plain value
  `WeddingPlanner.Valuation.Headcount.evaluate/3` consumes (`DR-47`, `DR-53`). Pure: no
  database, no context, called only from `WeddingPlanner.Valuation.Snapshot.Loader`.
  """
  @spec to_preset(t()) :: Preset.t()
  def to_preset(%__MODULE__{} = row) do
    %Preset{
      id: row.id,
      name: row.name,
      invitation_statuses: MapSet.new(row.invitation_statuses),
      certainties: MapSet.new(row.certainties),
      want_tiers: MapSet.new(row.want_tiers),
      age_categories: MapSet.new(row.age_categories),
      group_ids: MapSet.new(row.group_ids),
      role: row.role
    }
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  # `DR-53`: two presets naming the same values must always compare equal and log
  # identically, so each criterion is stored de-duplicated in a fixed order rather than
  # whatever order a form happened to submit it in.
  defp dedupe_ordered(changeset, field, fixed_order) do
    update_change(changeset, field, fn values ->
      present = MapSet.new(values)
      Enum.filter(fixed_order, &MapSet.member?(present, &1))
    end)
  end

  defp dedupe_group_ids(changeset) do
    update_change(changeset, :group_ids, fn ids -> ids |> Enum.uniq() |> Enum.sort() end)
  end
end
