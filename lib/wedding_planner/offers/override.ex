defmodule WeddingPlanner.Offers.Override do
  @moduledoc """
  One offer × service deviation from the category's wanted priority (`CST-24`,
  `docs/03-domain-model.md`'s Override, `DR-49`, `DR-56`).

  Row shape is fixed by `DR-49` — `offer_id`, `service_id`, `wanted` — since
  `WeddingPlanner.Valuation.Selection.effectively_wanted?/3` was written against exactly
  these three fields before this schema existed. At most one row per offer × service
  (the `offer_overrides` unique index); `wanted: true` turns the service **on** for this
  one offer, `wanted: false` turns it **off**, whichever the category priority alone
  would say.

  `offer_id` and `service_id` are set programmatically by `WeddingPlanner.Offers`, never
  cast here — whether they refer to compatible rows (the service must belong to the
  offer's own category) needs a query, so that check lives in
  `WeddingPlanner.Offers.toggle_override/3`.

  `WeddingPlanner.Offers.toggle_override/3` never writes a row that agrees with the
  priority-only default (see that function's moduledoc), so a row's mere presence
  already means "this cell deviates" — until the priority itself moves and catches up
  with the stored value, at which point the row is **kept**, not deleted (the deviation
  resumes if the priority moves back).
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Offers.Offer

  @type t :: %__MODULE__{}

  schema "offer_overrides" do
    belongs_to :offer, Offer
    belongs_to :service, Service

    field :wanted, :boolean

    timestamps(type: :utc_datetime)
  end

  @doc """
  Structural changeset: casts only `wanted` (`offer_id`/`service_id` are set
  programmatically — see the moduledoc). Does not check that the service belongs to the
  offer's category; that lives in `WeddingPlanner.Offers.toggle_override/3`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(override, attrs \\ %{}) do
    override
    |> cast(attrs, [:wanted])
    |> validate_required([:wanted, :offer_id, :service_id])
    |> foreign_key_constraint(:offer_id)
    |> foreign_key_constraint(:service_id)
    |> unique_constraint([:offer_id, :service_id])
  end
end
