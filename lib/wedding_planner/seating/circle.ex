defmodule WeddingPlanner.Seating.Circle do
  @moduledoc """
  A circle (`docs/modules/seating.md` SEAT-20, SEAT-21; `D-36`): a named, overlapping set
  of persons who know each other, with a cohesion. Seating-only — no invitation,
  headcount or cost semantics, and unrelated to `WeddingPlanner.Guests.Group`.

  Membership lives in `WeddingPlanner.Seating.CircleMembership`; `members` is the
  many-to-many through it, preloaded by `WeddingPlanner.Seating.list_circles/0`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Seating.CircleMembership

  @type cohesion :: :keep_together | :like_together | :know_each_other
  @type t :: %__MODULE__{}

  @cohesions [:keep_together, :like_together, :know_each_other]

  schema "circles" do
    field :name, :string
    field :cohesion, Ecto.Enum, values: @cohesions, default: :like_together

    has_many :memberships, CircleMembership
    many_to_many :members, Person, join_through: CircleMembership

    timestamps(type: :utc_datetime)
  end

  @doc "The SEAT-21 cohesions, strongest first."
  @spec cohesions() :: [cohesion()]
  def cohesions, do: @cohesions

  @doc "The UI label of a cohesion (SEAT-21)."
  @spec cohesion_label(cohesion()) :: String.t()
  def cohesion_label(:keep_together), do: "Keep together"
  def cohesion_label(:like_together), do: "Like together"
  def cohesion_label(:know_each_other), do: "Know each other"

  @doc "Name (trimmed, required, unique) and cohesion."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(circle, attrs) do
    circle
    |> cast(attrs, [:name, :cohesion])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :cohesion])
    |> validate_length(:name, max: 80)
    |> unique_constraint(:name, message: "another circle already has this name")
  end
end
