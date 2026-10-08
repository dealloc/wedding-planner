defmodule WeddingPlanner.Events.Event do
  @moduledoc """
  An event (`docs/modules/guests-and-events.md` EVT-01): a name, an optional date, an
  optional free-text location, a manual sort order and notes.

  `couple_attends` (`HC-11`, default `true`) says whether the two users count as 2 adults
  in this event's headcount.

  `date` is a plain `Date.t()`, never converted through a time zone (`NFR-20`) — it may
  also be `nil` (EVT-03: the date may be unknown and set later; `nil` is a valid,
  expected state, not an error).

  `sort_order` is set programmatically by `WeddingPlanner.Events` — appended after the
  current last event on create, swapped between two neighbours by
  `WeddingPlanner.Events.move_event/3` — and is deliberately absent from `changeset/2`
  so it can never be set through a form.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "events" do
    field :name, :string
    field :date, :date
    field :location, :string
    field :sort_order, :integer
    field :notes, :string
    field :couple_attends, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for the user-facing fields (EVT-01): `name` is required, `date`, `location`
  and `notes` are all optional (EVT-02, EVT-03). `sort_order` is intentionally not
  castable here — see `WeddingPlanner.Events.Event.sort_order_changeset/2`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:name, :date, :location, :notes, :couple_attends])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 200)
  end

  @doc """
  Programmatic-only changeset for EVT-04 reordering (`WeddingPlanner.Events.move_event/3`).
  Never driven directly by user input.
  """
  @spec sort_order_changeset(t(), integer()) :: Ecto.Changeset.t()
  def sort_order_changeset(event, sort_order) when is_integer(sort_order) do
    change(event, sort_order: sort_order)
  end
end
