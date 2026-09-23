defmodule WeddingPlanner.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  # `docs/03-domain-model.md`: a User is a display name that owns zero or more passkeys.
  # Exactly two exist in practice, but that count is never enforced here or in code
  # (03-domain-model.md). No deletion, renaming or deactivation in v1, so this table
  # carries no soft-delete or status column.
  def change do
    create table(:users) do
      add :display_name, :string, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
