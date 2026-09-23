defmodule WeddingPlanner.Invitations.PlusOneOptOut do
  @moduledoc """
  A +1's opt-out from one event (`docs/modules/guests-and-events.md` `PER-13`,
  `docs/03-domain-model.md` Plus-one opt-out, `DR-37`).

  Presence of a row is the whole signal — there is no status column. `PER-14` lets an
  opt-out exist whatever the host's own invitation status (the +1's data is retained
  even when the host is not invited or has declined); this schema and
  `WeddingPlanner.Invitations` never check the host's status before writing one.

  `person_id` and `event_id` are set programmatically by `WeddingPlanner.Invitations`,
  never cast here — whether `person_id` refers to a +1 at all (required — an opt-out on
  a non-+1 MUST NOT be creatable, `PER-13`) needs a query, so that check lives in the
  context.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person

  @type t :: %__MODULE__{}

  schema "plus_one_opt_outs" do
    belongs_to :person, Person
    belongs_to :event, Event

    timestamps(type: :utc_datetime)
  end

  @doc """
  Structural changeset: no fields of its own to cast (`person_id`/`event_id` are set
  programmatically — see the moduledoc). Does not check that `person_id`/`event_id`
  refer to existing, compatible rows; that lives in `WeddingPlanner.Invitations`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(opt_out, attrs \\ %{}) do
    opt_out
    |> cast(attrs, [])
    |> validate_required([:person_id, :event_id])
    |> foreign_key_constraint(:person_id)
    |> foreign_key_constraint(:event_id)
    |> unique_constraint([:person_id, :event_id])
  end
end
