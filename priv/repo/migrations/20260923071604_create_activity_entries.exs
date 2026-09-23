defmodule WeddingPlanner.Repo.Migrations.CreateActivityEntries do
  use Ecto.Migration

  # `docs/03-domain-model.md`'s Activity entry, XC-10 through XC-13.
  #
  # * `entity_type` / `entity_id` are a **polymorphic reference, not a foreign key**: an
  #   entry MUST survive the referenced row being deleted (XC-10 says a deleted entity's
  #   entries still render, degraded to plain text). Both are nullable because a bulk
  #   action's summarising entry (XC-12) describes the action as a whole and has no
  #   single entity of its own.
  # * `parent_id` is a **real** foreign key to this same table: the summarising entry a
  #   per-entity child belongs to (XC-12), so the global log can collapse them.
  #   `on_delete: :nilify_all` because the log is read-only (XC-13) and rows are never
  #   deleted through the app — this only protects against an operator deleting a
  #   summary by hand leaving orphaned children instead of raising a FK error.
  # * `user_id` is `on_delete: :restrict`, matching passkeys: users are never deleted in
  #   v1 (`docs/03-domain-model.md`), so this never fires in practice, but a log entry
  #   must never silently lose its user.
  # * No `updated_at` — the schema disables it (`timestamps(updated_at: false)`) because
  #   the log is append-only (XC-13); `inserted_at` doubles as XC-10's UTC timestamp
  #   (NFR-21).
  def change do
    create table(:activity_entries) do
      add :user_id, references(:users, on_delete: :restrict), null: false
      add :entity_type, :string
      add :entity_id, :integer
      add :description, :text, null: false
      add :parent_id, references(:activity_entries, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:activity_entries, [:user_id])
    create index(:activity_entries, [:entity_type, :entity_id])
    create index(:activity_entries, [:parent_id])
    create index(:activity_entries, [:inserted_at])
  end
end
