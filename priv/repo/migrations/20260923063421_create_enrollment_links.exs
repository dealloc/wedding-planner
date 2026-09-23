defmodule WeddingPlanner.Repo.Migrations.CreateEnrollmentLinks do
  use Ecto.Migration

  # AUTH-04 through AUTH-09, `docs/03-domain-model.md`. One table covers all three
  # flavours (device / user_invitation / recovery) rather than three tables, because they
  # share every column except which of issuing/target user is present:
  #
  # * `token` is the single-use secret embedded in the URL and QR code (AUTH-06); it must
  #   be unique and indexed, since that is how an opened link is looked up.
  # * `flavour` distinguishes the three kinds; validated at the changeset level.
  # * `issuing_user_id` is absent (nullable) for recovery links, which an operator command
  #   generates with no logged-in user behind it.
  # * `target_user_id` is absent (nullable) for user-invitation links until the link is
  #   used and the new user is created.
  # * `expires_at`, `used_at`, `revoked_at` are `:utc_datetime` (NFR-21). `expires_at` is
  #   always set by the application (AUTH-06 default: 15 minutes) — this is a separate
  #   concern from Wax's own WebAuthn challenge timeout.
  def change do
    create table(:enrollment_links) do
      add :token, :string, null: false
      add :flavour, :string, null: false
      add :issuing_user_id, references(:users, on_delete: :restrict)
      add :target_user_id, references(:users, on_delete: :restrict)
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:enrollment_links, [:token])
    create index(:enrollment_links, [:issuing_user_id])
    create index(:enrollment_links, [:target_user_id])
  end
end
