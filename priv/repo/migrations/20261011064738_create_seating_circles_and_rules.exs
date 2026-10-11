defmodule WeddingPlanner.Repo.Migrations.CreateSeatingCirclesAndRules do
  use Ecto.Migration

  # Seating slice 1, `docs/modules/seating.md` SEAT-20..SEAT-35.
  #
  # * `circles` (`WeddingPlanner.Seating.Circle`) — a name (unique) and a cohesion,
  #   pinned by a CHECK to the three SEAT-21 values.
  # * `circle_memberships` — one row per circle × person (unique). A person MAY be in
  #   any number of circles (SEAT-20).
  # * `seating_rules` (`WeddingPlanner.Seating.Rule`) — two sides `a` and `b`, each a
  #   person, a circle or the couple (SEAT-30), and a relation (SEAT-31). A side's kind
  #   decides which of its two id columns is set; the CHECKs keep that consistent.
  #   `pair_key` is the canonical, order-independent key of the two sides (written by
  #   the changeset), so its unique index is SEAT-30's "at most one rule per unordered
  #   pair" — a unique index over the nullable id columns could not be, because SQLite
  #   treats NULLs as distinct.
  # * Every foreign key is `on_delete: :restrict`: `WeddingPlanner.Seating` removes
  #   memberships and rules explicitly, so each removal is logged (`XC-10`, SEAT-81),
  #   the same stance as `invitations`.
  # * `persons.fine_anywhere` (SEAT-35), default off.
  # SQLite cannot add a table constraint after the fact, so each side's consistency CHECK
  # rides on its `_kind` column (a column CHECK may read the other columns).
  defp side_check(side) do
    "(#{side}_kind = 'person' AND #{side}_person_id IS NOT NULL AND #{side}_circle_id IS NULL) " <>
      "OR (#{side}_kind = 'circle' AND #{side}_circle_id IS NOT NULL AND #{side}_person_id IS NULL) " <>
      "OR (#{side}_kind = 'couple' AND #{side}_person_id IS NULL AND #{side}_circle_id IS NULL)"
  end

  def change do
    create table(:circles) do
      add :name, :string, null: false

      add :cohesion, :string,
        null: false,
        check: %{
          name: "circles_cohesion_values",
          expr: "cohesion IN ('keep_together','like_together','know_each_other')"
        }

      timestamps(type: :utc_datetime)
    end

    create unique_index(:circles, [:name])

    create table(:circle_memberships) do
      add :circle_id, references(:circles, on_delete: :restrict), null: false
      add :person_id, references(:persons, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:circle_memberships, [:circle_id, :person_id])
    create index(:circle_memberships, [:person_id])

    create table(:seating_rules) do
      add :a_kind, :string,
        null: false,
        check: %{name: "seating_rules_a_side", expr: side_check("a")}

      add :a_person_id, references(:persons, on_delete: :restrict)
      add :a_circle_id, references(:circles, on_delete: :restrict)

      add :b_kind, :string,
        null: false,
        check: %{name: "seating_rules_b_side", expr: side_check("b")}

      add :b_person_id, references(:persons, on_delete: :restrict)
      add :b_circle_id, references(:circles, on_delete: :restrict)

      add :relation, :string,
        null: false,
        check: %{
          name: "seating_rules_relation_values",
          expr: "relation IN ('always_with','seat_with','keep_apart','never_with')"
        }

      add :reason, :string
      add :pair_key, :string, null: false

      timestamps(type: :utc_datetime)
    end

    for side <- [:a_person_id, :a_circle_id, :b_person_id, :b_circle_id] do
      create index(:seating_rules, [side])
    end

    create unique_index(:seating_rules, [:pair_key])

    alter table(:persons) do
      add :fine_anywhere, :boolean, null: false, default: false
    end
  end
end
