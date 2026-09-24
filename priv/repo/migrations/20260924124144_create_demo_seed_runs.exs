defmodule WeddingPlanner.Repo.Migrations.CreateDemoSeedRuns do
  use Ecto.Migration

  # `DR-79` — dev demo data bookkeeping (`priv/repo/seeds/demo.exs`), not domain data.
  #
  # A row per demo block applied to this database, by the block's stable name. Any row at
  # all marks the database as a demo database, so `mix ecto.setup` applies only the blocks
  # not yet recorded (a later wave's new block); no rows means the database is either
  # fresh (every block runs) or in real use (nothing runs).
  #
  # * Unique index on `name` — a block is applied once.
  # * `updated_at: false` — a row is inserted, never changed.
  def change do
    create table(:demo_seed_runs) do
      add :name, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:demo_seed_runs, [:name])
  end
end
