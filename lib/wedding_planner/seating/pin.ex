defmodule WeddingPlanner.Seating.Pin do
  @moduledoc """
  A pin (`docs/modules/seating.md` SEAT-42, SEAT-43; `D-44`): a person, the couple or a
  circle put at a **fixed** table. Pinning a circle pins each of its seated members, and
  pinning anyone pins their whole seating unit; the solver places nobody else at a fixed
  table.

  The pinned side is stored like a rule's side (`kind` plus at most one id) with its
  `WeddingPlanner.Seating.Rule.side_key/1` as `target_key`, unique per table. Everything
  is set programmatically by `WeddingPlanner.Seating`, never cast.
  """
  use Ecto.Schema

  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Seating.Circle
  alias WeddingPlanner.Seating.Rule
  alias WeddingPlanner.Seating.Table

  @type t :: %__MODULE__{}

  schema "seating_pins" do
    belongs_to :seating_table, Table
    field :kind, Ecto.Enum, values: [:person, :circle, :couple]
    belongs_to :person, Person
    belongs_to :circle, Circle
    field :target_key, :string

    timestamps(type: :utc_datetime)
  end

  @doc "A new, unsaved pin of `side` at `table`."
  @spec new(Table.t(), Rule.side()) :: t()
  def new(%Table{id: table_id}, side) do
    {kind, person_id, circle_id} =
      case side do
        :couple -> {:couple, nil, nil}
        {:person, id} -> {:person, id, nil}
        {:circle, id} -> {:circle, nil, id}
      end

    %__MODULE__{
      seating_table_id: table_id,
      kind: kind,
      person_id: person_id,
      circle_id: circle_id,
      target_key: Rule.side_key(side)
    }
  end

  @doc "The pinned side: `{:person, id}`, `{:circle, id}` or `:couple`."
  @spec side(t()) :: Rule.side()
  def side(%__MODULE__{kind: :couple}), do: :couple
  def side(%__MODULE__{kind: :person, person_id: id}), do: {:person, id}
  def side(%__MODULE__{kind: :circle, circle_id: id}), do: {:circle, id}
end
