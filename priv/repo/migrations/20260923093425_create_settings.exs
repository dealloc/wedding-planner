defmodule WeddingPlanner.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  # `settings` is a singleton (docs/03-domain-model.md's Settings entity): exactly one
  # row, enforced in the database rather than only by convention. SQLite does not support
  # `ALTER TABLE ADD CONSTRAINT` (so `create constraint/3` is unavailable on this
  # adapter), so the guard is an inline column-level CHECK on the primary key itself,
  # fixed to the literal value 1. Combined with `id` being the PRIMARY KEY (which SQLite
  # also enforces as UNIQUE), this makes a second row impossible at the storage layer: an
  # insert with `id = 1` when a row already exists violates the PRIMARY KEY uniqueness,
  # and an insert with any other `id` violates the CHECK.
  def change do
    create table(:settings, primary_key: false) do
      add :id, :integer,
        primary_key: true,
        null: false,
        check: %{name: "settings_singleton_id", expr: "id = 1"}

      # BUD-01: the overall budget, nilable — unset until the user first sets it
      # (rendered "Not set", never a fake €0,00; see WeddingPlanner.Settings' moduledoc).
      add :overall_budget, :map, null: true

      # NFR-22: the STORED default time zone. Application configuration
      # (`config :wedding_planner, :default_time_zone`) only seeds this column's value
      # when the row is first created (WeddingPlanner.Settings.get/0) — once stored, this
      # column is the app-level setting and configuration is no longer consulted.
      add :default_time_zone, :string, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
