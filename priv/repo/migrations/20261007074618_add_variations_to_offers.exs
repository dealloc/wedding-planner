defmodule WeddingPlanner.Repo.Migrations.AddVariationsToOffers do
  use Ecto.Migration

  # `docs/modules/offers-and-comparison.md` CST-27 — an optional variation name on service
  # lines, and `chosen` marking the lines of the offer's active variation of a service.
  def change do
    alter table(:offer_lines) do
      add :variation, :string
      add :chosen, :boolean, null: false, default: false
    end
  end
end
