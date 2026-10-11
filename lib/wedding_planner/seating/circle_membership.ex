defmodule WeddingPlanner.Seating.CircleMembership do
  @moduledoc """
  One person in one circle (SEAT-20). Both ids are set programmatically by
  `WeddingPlanner.Seating`, never cast.
  """
  use Ecto.Schema

  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Seating.Circle

  @type t :: %__MODULE__{}

  schema "circle_memberships" do
    belongs_to :circle, Circle
    belongs_to :person, Person

    timestamps(type: :utc_datetime)
  end
end
