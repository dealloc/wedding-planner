defmodule WeddingPlanner.Invitations.Invitation do
  @moduledoc """
  One (non-+1) person's status for one event (`docs/modules/guests-and-events.md`
  `INVT-01`, `docs/03-domain-model.md` Invitation, `DR-37`).

  `status` is exactly `WeddingPlanner.Valuation.Preset.invitation_status/0`'s four
  atoms — a column CHECK on the `invitations` table pins the same four strings at the
  database level. *Not invited* is never stored as a fifth value: it is the absence of
  a row for a given `person_id`/`event_id` pair, which is why this schema's type does
  not include it (`WeddingPlanner.Invitations.set_invitation_status/4` deletes the row
  instead).

  `person_id` and `event_id` are set programmatically by `WeddingPlanner.Invitations`,
  never cast here (AGENTS.md: fields set programmatically are put on the struct, not
  cast) — whether `person_id` refers to a +1 (refused, `PER-13`) needs a query, so that
  check lives in the context, the same split `WeddingPlanner.Guests.change_person/2`
  uses for `group_id`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person

  @type status :: :planned | :invited | :accepted | :declined
  @type t :: %__MODULE__{}

  @statuses [:planned, :invited, :accepted, :declined]

  schema "invitations" do
    field :status, Ecto.Enum, values: @statuses

    belongs_to :person, Person
    belongs_to :event, Event

    timestamps(type: :utc_datetime)
  end

  @doc "The fixed `status` atoms, in the order `docs/` names them."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc """
  Structural changeset: casts only `status` (`person_id`/`event_id` are set
  programmatically — see the moduledoc). Does not check that `person_id`/`event_id`
  refer to existing, compatible rows; that lives in `WeddingPlanner.Invitations`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(invitation, attrs \\ %{}) do
    invitation
    |> cast(attrs, [:status])
    |> validate_required([:status, :person_id, :event_id])
    |> foreign_key_constraint(:person_id)
    |> foreign_key_constraint(:event_id)
    |> unique_constraint([:person_id, :event_id])
  end
end
