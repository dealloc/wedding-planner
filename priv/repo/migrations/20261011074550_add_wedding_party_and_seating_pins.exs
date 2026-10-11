defmodule WeddingPlanner.Repo.Migrations.AddWeddingPartyAndSeatingPins do
  use Ecto.Migration

  # Seating, `docs/modules/seating.md` SEAT-24, SEAT-42, SEAT-43 (`D-43`, `D-44`).
  #
  # * `circles.role` — `NULL` for an ordinary circle, `'wedding_party'` for the one
  #   built-in circle (unique). Its members beyond those stored — the couple and every
  #   witness — are derived, never stored. The row is seeded here like the headcount
  #   presets (HC-06): an existing circle already named "Wedding party" takes the role
  #   instead of colliding with the unique name.
  # * `seating_pins` — a person, the couple or a circle pinned to a **fixed** table
  #   (SEAT-42). The kind decides which id is set (CHECK); `target_key` is the canonical
  #   key of the pinned side ("person:3", "circle:2", "couple"), unique per table. Foreign
  #   keys are `:restrict`: `WeddingPlanner.Seating` deletes pins explicitly and logs it
  #   (SEAT-81).
  def up do
    alter table(:circles) do
      add :role, :string, check: %{name: "circles_role_values", expr: "role IN ('wedding_party')"}
    end

    create unique_index(:circles, [:role])

    execute """
    UPDATE circles SET role = 'wedding_party' WHERE name = 'Wedding party'
    """

    execute """
    INSERT INTO circles (name, cohesion, role, inserted_at, updated_at)
    SELECT 'Wedding party', 'keep_together', 'wedding_party',
           strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM circles WHERE role = 'wedding_party')
    """

    create table(:seating_pins) do
      add :seating_table_id, references(:seating_tables, on_delete: :restrict), null: false

      add :kind, :string,
        null: false,
        check: %{
          name: "seating_pins_kind",
          expr:
            "(kind = 'person' AND person_id IS NOT NULL AND circle_id IS NULL) " <>
              "OR (kind = 'circle' AND circle_id IS NOT NULL AND person_id IS NULL) " <>
              "OR (kind = 'couple' AND person_id IS NULL AND circle_id IS NULL)"
        }

      add :person_id, references(:persons, on_delete: :restrict)
      add :circle_id, references(:circles, on_delete: :restrict)
      add :target_key, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:seating_pins, [:seating_table_id, :target_key])
    create index(:seating_pins, [:person_id])
    create index(:seating_pins, [:circle_id])
  end

  def down do
    drop table(:seating_pins)
    drop index(:circles, [:role])

    alter table(:circles) do
      remove :role
    end
  end
end
