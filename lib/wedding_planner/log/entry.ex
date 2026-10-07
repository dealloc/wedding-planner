defmodule WeddingPlanner.Log.Entry do
  @moduledoc """
  A single activity log entry (`docs/03-domain-model.md`'s Activity entry, `XC-10`
  through `XC-13`).

  Two shapes come out of the same table:

  * a **plain entry**, written by `WeddingPlanner.Log.entry/3`, always has an
    `entity_type` + `entity_id` — the polymorphic reference `XC-10` requires (a type
    plus an id, deliberately **not** a foreign key, so the entry survives the referenced
    row being deleted) — and no `parent_id`.
  * a **summarising entry**, written by `WeddingPlanner.Log.action/3`, describes a bulk
    action as a whole (`XC-12`, e.g. "Wannes set 4 people in 'Family Peeters' to invited
    for Reception"). It has no entity of its own, so `entity_type`/`entity_id` are nil.
    Every entry written by the wrapped callback gets its `parent_id` set to the
    summary's id, so the global log can collapse them.

  `user_id` and `parent_id` are set programmatically by `WeddingPlanner.Log` (who is
  acting, and which summary — if any — is currently open) and are deliberately absent
  from both `cast/3` calls below; they must never come from external input.

  `XC-13`: the log is **not** an undo mechanism. There is deliberately
  no update or delete changeset here — only the two insert-only changesets below.

  There is no dedicated "occurred at" field: `inserted_at` (`timestamps(updated_at:
  false)`) already is that UTC moment (`NFR-21`), and disabling `updated_at` makes the
  append-only nature of the log visible in the schema itself.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Accounts.User

  @type t :: %__MODULE__{}

  schema "activity_entries" do
    field :entity_type, :string
    field :entity_id, :integer
    field :description, :string

    belongs_to :user, User
    belongs_to :parent, __MODULE__

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Changeset for a single entry (`XC-10`): a description of what happened to one entity.
  `entity_type` and `entity_id` are required — a plain entry always references exactly
  one entity.
  """
  def entry_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:entity_type, :entity_id, :description])
    |> validate_required([:entity_type, :entity_id, :description])
    |> validate_length(:description, min: 1)
  end

  @doc """
  Changeset for a bulk action's summarising entry (`XC-12`): a description of the action
  as a whole. It has no entity of its own — the per-entity children written during the
  same action carry those.
  """
  def summary_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:description])
    |> validate_required([:description])
    |> validate_length(:description, min: 1)
  end
end
