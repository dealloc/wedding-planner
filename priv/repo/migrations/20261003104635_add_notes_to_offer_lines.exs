defmodule WeddingPlanner.Repo.Migrations.AddNotesToOfferLines do
  use Ecto.Migration

  # `docs/modules/offers-and-comparison.md` CST-26 — optional free-text note on a line.
  def change do
    alter table(:offer_lines) do
      add :notes, :text
    end
  end
end
