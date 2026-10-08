defmodule WeddingPlanner.Repo.Migrations.AddCoupleAttendsToEvents do
  use Ecto.Migration

  # `docs/modules/headcount.md` HC-11 — the two users are counted as 2 adults at every event
  # unless the event says otherwise (e.g. a ceremony nobody caters).
  def change do
    alter table(:events) do
      add :couple_attends, :boolean, null: false, default: true
    end
  end
end
