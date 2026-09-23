defmodule WeddingPlanner.Repo.Migrations.CreateTaskDependencies do
  use Ecto.Migration

  # `docs/modules/tasks-and-timeline.md` TSK-10 through TSK-15, `06-decisions.md` DR-35/
  # DR-36 (task 42).
  #
  # * Direction: an edge `{task_id, depends_on_id}` means **`task_id` waits on
  #   `depends_on_id`** — the latter is the prerequisite. `task_id` is the "waiting"
  #   task, `depends_on_id` the one it needs done first.
  # * Both columns are `references(:tasks, on_delete: :restrict)`, deliberately not
  #   `:delete_all`/`:nilify_all`: `WeddingPlanner.Tasks.delete_task/2` removes every
  #   edge that touches the deleted task explicitly, inside its own `Log.action/3`
  #   transaction, so each removal gets logged (`XC-10`) as either a silent cleanup (the
  #   deleted task's own outgoing edges) or a per-waiter entry (edges where the deleted
  #   task was the prerequisite). `:restrict` exists purely as a backstop: a path that
  #   forgets that ordering fails loudly with a DB error instead of silently orphaning an
  #   edge.
  # * Unique index on `[:task_id, :depends_on_id]`: the same dependency can't be added
  #   twice. Plain (non-unique) index on `:depends_on_id` alone, for the reverse lookup
  #   ("who waits on this task") that `task_deletion_effects/1` and `delete_task/2` need
  #   — the leading column of the unique index already covers forward lookups by
  #   `task_id`.
  # * The `task_id <> depends_on_id` CHECK (no self-dependency) is placed on the
  #   **second** column (`depends_on_id`), added within the same `create table` block as
  #   `task_id` — mirroring `create_tasks.exs`'s `owner_shared` CHECK, which already
  #   established that a column-level `check:` can reference an *earlier* column of the
  #   same `create table` block on this SQLite adapter. `Ecto.Migration`'s standalone
  #   `create constraint/3` is **not** supported on SQLite (see that same migration's
  #   comment), so every CHECK in this schema is expressed as a column-level `check:`
  #   option instead.
  def change do
    create table(:task_dependencies) do
      add :task_id, references(:tasks, on_delete: :restrict), null: false

      add :depends_on_id, references(:tasks, on_delete: :restrict),
        null: false,
        check: %{
          name: "task_dependencies_not_self",
          expr: "task_id <> depends_on_id"
        }

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:task_dependencies, [:task_id, :depends_on_id])
    create index(:task_dependencies, [:depends_on_id])
  end
end
