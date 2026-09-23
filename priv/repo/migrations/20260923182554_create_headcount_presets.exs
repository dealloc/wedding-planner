defmodule WeddingPlanner.Repo.Migrations.CreateHeadcountPresets do
  use Ecto.Migration

  # `docs/modules/headcount.md` HC-02 (criteria), HC-06 (the three shipped defaults);
  # `docs/03-domain-model.md` "Headcount preset"; `docs/06-decisions.md` D-19; `DR-47`.
  #
  # Four criteria are stored as JSON arrays (`invitation_statuses`, `certainties`,
  # `want_tiers`, `age_categories`); the fifth criterion HC-02 lists, groups, has no
  # column yet — it arrives with G5's preset CRUD (see
  # `WeddingPlanner.Presets.HeadcountPreset`'s moduledoc). SQLite has no array type;
  # `ecto_sqlite3` serialises `{:array, _}` columns as JSON text, so each column carries a
  # CHECK that it is valid JSON and a JSON array — `json_valid(col) AND json_type(col) =
  # 'array'`. The *allowed values inside* the array (e.g. only `certain`/`likely`/
  # `uncertain`) are enforced by the schema's `Ecto.Enum`, not the database: SQLite
  # forbids subqueries in a CHECK, so there is no `json_each` membership test here.
  #
  # `up`/`down` rather than `change`: the three `HC-06` defaults are seeded here with
  # literal SQL values (never by calling application code from a migration — the schema
  # may change later, the migration must not), and a raw `execute` is not automatically
  # reversible. `down` drops the table, taking the seeded rows with it.
  def up do
    create table(:headcount_presets) do
      add :name, :string, null: false

      add :sort_order, :integer, null: false

      add :invitation_statuses, {:array, :string},
        null: false,
        default: [],
        check: %{
          name: "headcount_presets_invitation_statuses_is_json_array",
          expr: "json_valid(invitation_statuses) AND json_type(invitation_statuses) = 'array'"
        }

      add :certainties, {:array, :string},
        null: false,
        default: [],
        check: %{
          name: "headcount_presets_certainties_is_json_array",
          expr: "json_valid(certainties) AND json_type(certainties) = 'array'"
        }

      add :want_tiers, {:array, :string},
        null: false,
        default: [],
        check: %{
          name: "headcount_presets_want_tiers_is_json_array",
          expr: "json_valid(want_tiers) AND json_type(want_tiers) = 'array'"
        }

      add :age_categories, {:array, :string},
        null: false,
        default: [],
        check: %{
          name: "headcount_presets_age_categories_is_json_array",
          expr: "json_valid(age_categories) AND json_type(age_categories) = 'array'"
        }

      timestamps(type: :utc_datetime)
    end

    create unique_index(:headcount_presets, [:name])

    # HC-06's three shipped defaults, in display order. Every array is inserted as a
    # literal JSON string; `Maximum`'s "any certainty" is the empty set (HC-02: empty
    # means no restriction), not a list of every certainty. This must convert back to
    # exactly `WeddingPlanner.Valuation.Preset.defaults/0` through
    # `WeddingPlanner.Presets.HeadcountPreset.to_preset/1` (DR-47) — the
    # `HeadcountPresetTest` cross-check fails if it does not.
    execute """
    INSERT INTO headcount_presets
      (name, sort_order, invitation_statuses, certainties, want_tiers, age_categories,
       inserted_at, updated_at)
    VALUES
      ('Minimum', 0, '["planned","invited","accepted"]', '["certain"]', '[]', '[]',
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
      ('Likely', 1, '["planned","invited","accepted"]', '["certain","likely"]', '[]', '[]',
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
      ('Maximum', 2, '["planned","invited","accepted"]', '[]', '[]', '[]',
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    """
  end

  def down do
    drop table(:headcount_presets)
  end
end
