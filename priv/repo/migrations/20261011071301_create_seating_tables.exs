defmodule WeddingPlanner.Repo.Migrations.CreateSeatingTables do
  use Ecto.Migration

  # Seating slice 2, `docs/modules/seating.md` SEAT-40, SEAT-41, SEAT-45 (`D-42`): an
  # event's tables as **table types** ("Round, 8–10 seats", optionally limited to a number
  # of tables) and **fixed tables** ("Head table"). How many tables of each type a plan
  # uses is computed, never stored. Names are unique within an event; seats are
  # 1 ≤ min ≤ max; only a table type has a limit, and it is at least 1 (CHECKs).
  #
  # `event_id` is `on_delete: :restrict` like every other event reference: deleting an
  # event removes its tables explicitly (`WeddingPlanner.Seating.detach_event/2`), each
  # logged, and EVT-05's warning names them.
  def change do
    create table(:seating_tables) do
      add :event_id, references(:events, on_delete: :restrict), null: false

      add :kind, :string,
        null: false,
        check: %{
          name: "seating_tables_kind",
          expr:
            "(kind = 'type' AND (\"limit\" IS NULL OR \"limit\" >= 1)) OR (kind = 'fixed' AND \"limit\" IS NULL)"
        }

      add :name, :string, null: false

      add :min_seats, :integer,
        null: false,
        check: %{name: "seating_tables_seats", expr: "min_seats >= 1 AND max_seats >= min_seats"}

      add :max_seats, :integer, null: false
      add :limit, :integer
      add :sort_order, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:seating_tables, [:event_id, :name])
  end
end
