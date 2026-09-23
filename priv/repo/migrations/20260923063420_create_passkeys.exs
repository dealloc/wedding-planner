defmodule WeddingPlanner.Repo.Migrations.CreatePasskeys do
  use Ecto.Migration

  # AUTH-02, AUTH-08. Field choices carried over from the DR-4 spike
  # (.claude/dr4-webauthn/findings.md), verified end to end against a real WebAuthn
  # ceremony:
  #
  # * `credential_id` and `public_key` are `:binary` (SQLite BLOB). WebAuthn credential
  #   ids and COSE keys are raw bytes; Wax hands us and expects raw binaries, and storing
  #   them base64url-encoded would mean encoding on every comparison.
  # * `public_key` holds the CBOR encoding of the COSE key map Wax returns. That map has
  #   negative integer keys (e.g. `%{-1 => 1, -2 => <<...>>, 1 => 2, 3 => -7}`), which
  #   neither JSON nor Ecto's `:map` can round-trip — JSON object keys are strings. CBOR
  #   is the wire format the key arrives in anyway.
  # * `transports` is `{:array, :string}`; ecto_sqlite3 stores this as JSON text.
  # * `sign_count` backs clone detection (findings.md section 4); Wax does not track it.
  # * `registered_at` / `last_used_at` are `:utc_datetime` (NFR-21).
  def change do
    create table(:passkeys) do
      add :credential_id, :binary, null: false
      add :public_key, :binary, null: false
      add :aaguid, :binary
      add :transports, {:array, :string}, null: false, default: []
      add :sign_count, :integer, null: false, default: 0
      add :name, :string, null: false
      add :registered_at, :utc_datetime, null: false
      add :last_used_at, :utc_datetime
      add :user_id, references(:users, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    # A credential id must be globally unique: WebAuthn requires the RP to reject a
    # credential id already registered to another user. It is also what an assertion is
    # looked up by on login, so the unique index doubles as the lookup index.
    create unique_index(:passkeys, [:credential_id])
    create index(:passkeys, [:user_id])
  end
end
