defmodule WeddingPlanner.Repo.Migrations.CreateMoneyProbes do
  use Ecto.Migration

  # `money_probes` exists solely to prove the money storage contract (NFR-10) end to
  # end: two independent, nilable `Money.Ecto.Map.Type` columns on one row, round-tripped
  # through a real migration and schema rather than asserted in the abstract. It is not a
  # domain table — later slices introduce the real invoice/offer schemas.
  def change do
    create table(:money_probes) do
      add :price, :map
      add :deposit, :map

      timestamps(type: :utc_datetime)
    end
  end
end
