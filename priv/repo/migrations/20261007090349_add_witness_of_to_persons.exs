defmodule WeddingPlanner.Repo.Migrations.AddWitnessOfToPersons do
  use Ecto.Migration

  # `docs/modules/guests-and-events.md` PER-20 — a person may be a witness of one of the
  # two users (at most 2 per user, enforced in `WeddingPlanner.Guests.set_witness/3`).
  def change do
    alter table(:persons) do
      add :witness_of_id, references(:users, on_delete: :restrict)
    end

    create index(:persons, [:witness_of_id])
  end
end
