defmodule WeddingPlanner.Seating.Table do
  @moduledoc """
  An event's tables as the venue offers them (`docs/modules/seating.md` SEAT-40, SEAT-41,
  SEAT-45; `D-42`): either a **table type** — "Round, 8–10 seats", standing for as many
  identical tables as the plan needs, within an optional `limit` — or a **fixed table**,
  one specific table such as the head table, which pins can name (SEAT-42).

  Every table has a name (unique within its event), a minimum and a maximum number of
  seats (1 ≤ min ≤ max) and a manual sort order. How many tables of a type a plan uses is
  computed (`WeddingPlanner.Valuation.SeatingPlan`), never stored.

  `event_id` and `sort_order` are set programmatically by `WeddingPlanner.Seating`, never
  cast.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Events.Event

  @type kind :: :type | :fixed
  @type t :: %__MODULE__{}

  schema "seating_tables" do
    belongs_to :event, Event
    field :kind, Ecto.Enum, values: [:type, :fixed], default: :type
    field :name, :string
    field :min_seats, :integer
    field :max_seats, :integer
    field :limit, :integer
    field :sort_order, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc "Whether `table` is a fixed table (SEAT-40)."
  @spec fixed?(t()) :: boolean()
  def fixed?(%__MODULE__{kind: kind}), do: kind == :fixed

  @doc """
  Kind, name (trimmed, required, unique per event), min and max seats (1 ≤ min ≤ max),
  and — for a table type only — an optional limit of at least 1. A fixed table never has
  a limit: switching a type to fixed clears it.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(table, attrs) do
    table
    |> cast(attrs, [:kind, :name, :min_seats, :max_seats, :limit])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:kind, :name, :min_seats, :max_seats])
    |> validate_length(:name, max: 60)
    |> validate_number(:min_seats, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> validate_number(:max_seats, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> validate_number(:limit, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> validate_min_not_above_max()
    |> clear_limit_when_fixed()
    |> unique_constraint([:event_id, :name],
      error_key: :name,
      message: "another table of this event already has this name"
    )
  end

  defp validate_min_not_above_max(changeset) do
    min = get_field(changeset, :min_seats)
    max = get_field(changeset, :max_seats)

    if is_integer(min) and is_integer(max) and min > max,
      do: add_error(changeset, :max_seats, "must be at least the minimum"),
      else: changeset
  end

  defp clear_limit_when_fixed(changeset) do
    if get_field(changeset, :kind) == :fixed,
      do: put_change(changeset, :limit, nil),
      else: changeset
  end
end
