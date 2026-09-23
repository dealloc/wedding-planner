defmodule WeddingPlanner.Presets.HeadcountPreset do
  @moduledoc """
  The stored row backing a **headcount preset** (`docs/modules/headcount.md` HC-02,
  HC-06; `DR-47`). Four of HC-02's five criteria are columns, each a JSON array of
  atoms — `invitation_statuses`, `certainties`, `want_tiers`, `age_categories` — where an
  empty array means "no restriction" (HC-02), never "match nothing". The allowed values
  inside each array are exactly `WeddingPlanner.Valuation.Preset`'s atoms and are
  enforced by `Ecto.Enum`; SQLite forbids subqueries in a CHECK, so the database only
  checks that each column is valid JSON holding an array (see the migration).

  **No `groups` column yet.** HC-02's fifth criterion, groups, has no column here: G5's
  preset CRUD adds it, and must also decide what deleting a group does to a preset that
  filters on it (drop it from the set — silently widening the preset — or block the
  delete). That question cannot arise while no preset can name a group, so `to_preset/1`
  below always yields an empty `group_ids`.

  This module has no changeset and no context functions on purpose: the migration that
  creates this table also seeds the three `HC-06` defaults with literal SQL (never by
  calling application code — the schema may change later, the migration must not), and no
  other W9 code path writes a row. G5 adds the changeset and CRUD; nothing may call one
  before then.
  """

  use Ecto.Schema

  alias WeddingPlanner.Valuation.Preset

  @invitation_statuses [:planned, :invited, :accepted, :declined]
  @certainties [:certain, :likely, :uncertain]
  @want_tiers [:yes, :maybe, :no, :obligated]
  @age_categories [:adult, :child]

  @type t :: %__MODULE__{}

  schema "headcount_presets" do
    field :name, :string
    field :sort_order, :integer
    field :invitation_statuses, {:array, Ecto.Enum}, values: @invitation_statuses, default: []
    field :certainties, {:array, Ecto.Enum}, values: @certainties, default: []
    field :want_tiers, {:array, Ecto.Enum}, values: @want_tiers, default: []
    field :age_categories, {:array, Ecto.Enum}, values: @age_categories, default: []

    timestamps(type: :utc_datetime)
  end

  @doc """
  Converts a stored row into the plain value
  `WeddingPlanner.Valuation.Headcount.evaluate/3` consumes (`DR-47`). Pure: no database,
  no context, called only from `WeddingPlanner.Valuation.Snapshot.Loader`.

  `group_ids` is always the empty set — see the moduledoc's "No `groups` column yet".
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
      group_ids: MapSet.new()
    }
  end
end
