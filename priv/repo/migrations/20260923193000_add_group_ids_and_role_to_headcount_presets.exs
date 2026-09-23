defmodule WeddingPlanner.Repo.Migrations.AddGroupIdsAndRoleToHeadcountPresets do
  use Ecto.Migration

  # `docs/modules/headcount.md` HC-02 (the missing `groups` criterion), HC-06 (the three
  # shipped defaults); `docs/modules/guests-and-events.md` PER-07 (deleting a group);
  # `DR-53`.
  #
  # `group_ids` follows the exact `DR-47` pattern the four other criteria already use:
  # a JSON array column (`{:array, :integer}`, SQLite has no array type so `ecto_sqlite3`
  # serialises it as JSON text), `NOT NULL DEFAULT '[]'`, and a CHECK that it is valid
  # JSON holding an array (`json_valid`/`json_type` — SQLite cannot check the *elements*
  # of a JSON array in a CHECK, so a dangling group id is only caught in the context via
  # `Repo.exists?/1`, not here).
  #
  # `role` identifies which of a preset's roles it plays for `DR-54` (single-figure
  # default = the *likely* role; the range's low/high ends = *minimum*/*maximum*) —
  # nullable (most presets have none), pinned to the three allowed values by a column
  # CHECK (mirrors `offers.status`'s pattern), and a **partial** unique index so at most
  # one preset can hold a given role at a time while leaving every role-less preset out
  # of the uniqueness check entirely (a plain unique index would refuse a second `NULL`
  # on some databases; SQLite does not, but the `WHERE role IS NOT NULL` is still the
  # correct and explicit way to say "unique only when set").
  #
  # `up`/`down` rather than `change`: the three seeded rows get their roles by literal
  # `UPDATE ... WHERE name = ...` (never by calling application code from a migration —
  # same reasoning as the original seed insert in
  # `20260923182554_create_headcount_presets.exs`), which is not automatically
  # reversible, and `down` must drop the partial index before the columns (SQLite >= 3.35
  # refuses `DROP COLUMN` on an indexed column).
  def up do
    alter table(:headcount_presets) do
      add :group_ids, {:array, :integer},
        null: false,
        default: [],
        check: %{
          name: "headcount_presets_group_ids_is_json_array",
          expr: "json_valid(group_ids) AND json_type(group_ids) = 'array'"
        }

      add :role, :string,
        check: %{
          name: "headcount_presets_role_is_valid",
          expr: "role IS NULL OR role IN ('minimum', 'likely', 'maximum')"
        }
    end

    create unique_index(:headcount_presets, [:role],
             where: "role IS NOT NULL",
             name: :headcount_presets_role_index
           )

    # `DR-53`: the three `HC-06` defaults get their role by name — safe only because
    # nothing could have renamed them before this migration runs (G5 is the first slice
    # that lets a preset be renamed at all).
    execute "UPDATE headcount_presets SET role = 'minimum' WHERE name = 'Minimum'"
    execute "UPDATE headcount_presets SET role = 'likely' WHERE name = 'Likely'"
    execute "UPDATE headcount_presets SET role = 'maximum' WHERE name = 'Maximum'"
  end

  def down do
    drop index(:headcount_presets, [:role], name: :headcount_presets_role_index)

    alter table(:headcount_presets) do
      remove :group_ids
      remove :role
    end
  end
end
