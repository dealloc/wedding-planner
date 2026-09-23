defmodule WeddingPlanner.Repo.Migrations.CreateUserSessions do
  use Ecto.Migration

  # AUTH-01 / AUTH-10 — one row per signed-in browser. `WeddingPlanner.Accounts.Sessions`
  # is the only writer.
  #
  # * `token` is the session secret itself (32 random bytes, `:binary`/BLOB), stored raw
  #   rather than hashed — matching `credential_id`/`public_key` on `passkeys`, this app's
  #   existing convention for opaque secrets it already treats a DB compromise as
  #   catastrophic for. The cookie holds the same bytes (base64url-encoded only for the
  #   one HTML hidden-field hop needed to bridge a LiveView-verified ceremony into a real
  #   `Plug.Session` cookie — see `WeddingPlannerWeb.SessionController`).
  # * `last_used_at` backs AUTH-10's sliding 30-day expiry: extended on every authenticated
  #   request (`WeddingPlanner.Accounts.Sessions.fetch_by_token/2`), compared against a
  #   fixed TTL rather than storing a computed `expires_at` that would need updating in
  #   lockstep.
  # * `passkey_id` records which passkey opened this session (nullable — task 17's device
  #   management may want to end sessions opened by a revoked passkey, but that decision
  #   is not made here). `on_delete: :nilify_all`: a session survives its passkey being
  #   removed by hand (stays signed in) rather than being cascade-deleted or blocking the
  #   passkey delete — the same reasoning `activity_entries.parent_id` already uses.
  # * `user_id` is `on_delete: :restrict`, matching every other FK to `users` in this
  #   schema (`passkeys`, `enrollment_links`, `activity_entries`): users are never deleted
  #   in v1. The one place a user row *is* deleted (`SetupLive`'s abort-on-failure path,
  #   `DR-22`) deletes a provisional user before any real login — and therefore any
  #   session — can exist for it, so `:restrict` never fires in practice here either.
  # * No `updated_at`: `last_used_at` is the one mutable timestamp this table has, and it
  #   is meaningful on its own, so a second generic `updated_at` would be redundant.
  def change do
    create table(:user_sessions) do
      add :token, :binary, null: false
      add :last_used_at, :utc_datetime, null: false
      add :user_id, references(:users, on_delete: :restrict), null: false
      add :passkey_id, references(:passkeys, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:user_sessions, [:token])
    create index(:user_sessions, [:user_id])
    create index(:user_sessions, [:passkey_id])
  end
end
