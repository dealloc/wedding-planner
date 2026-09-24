defmodule WeddingPlanner.Offers.FrozenService do
  @moduledoc """
  One service in a confirmed offer's **frozen selection**
  (`docs/modules/offers-and-comparison.md` `CST-40`, `CST-43`; `docs/06-decisions.md`
  `D-27`; `DR-61`).

  Confirming an offer freezes *which services* are on for it — never individual lines
  (`D-27`) — as one row per service: every service that was effectively wanted at that
  moment (`WeddingPlanner.Valuation.Selection.freeze/2`, the single definition of what a
  confirmation captures), plus any service later added to the confirmed scope
  (`CST-43` case 2). Optional ad hoc lines have no row: their own `enabled` flag is their
  frozen state (`DR-61`).

  For an offer whose status is `:confirmed`, `WeddingPlanner.Valuation.Selection` answers
  from these rows instead of the category priorities and overrides; rows on any other
  offer are ignored. Rows exist only while the offer is confirmed — `WeddingPlanner.Offers`
  writes and removes them (task 73).

  `offer_id` and `service_id` are set programmatically, never cast: whether the service
  belongs to the offer's own category needs a query, so that check lives in the context.
  Both foreign keys are `on_delete: :restrict` — a frozen service is never deletable
  (`CST-06`).
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Offers.Offer

  @type t :: %__MODULE__{}

  schema "offer_frozen_services" do
    belongs_to :offer, Offer
    belongs_to :service, Service

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Structural changeset: casts nothing (`offer_id`/`service_id` are set programmatically —
  see the moduledoc), requires both ids and maps the unique pair to a changeset error.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(frozen_service, attrs \\ %{}) do
    frozen_service
    |> cast(attrs, [])
    |> validate_required([:offer_id, :service_id])
    |> unique_constraint([:offer_id, :service_id])
  end
end
