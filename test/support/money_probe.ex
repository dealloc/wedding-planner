defmodule WeddingPlanner.MoneyProbe do
  @moduledoc """
  Test-only Ecto schema backed by the `money_probes` table.

  It exists solely to prove the money storage contract (`NFR-10`) end to end — two
  independent, nilable `Money.Ecto.Map.Type` columns on one row, round-tripped through a
  real migration and schema — without tying that proof to any domain concept. Real
  domain schemas (invoices, offers, …) are introduced by later slices and use the same
  `Money.Ecto.Map.Type` field type.
  """

  use Ecto.Schema

  schema "money_probes" do
    field :price, Money.Ecto.Map.Type
    field :deposit, Money.Ecto.Map.Type

    timestamps(type: :utc_datetime)
  end
end
