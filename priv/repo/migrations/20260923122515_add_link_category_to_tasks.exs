defmodule WeddingPlanner.Repo.Migrations.AddLinkCategoryToTasks do
  use Ecto.Migration

  # Task 32 (`DR-26` Q17/Q18): a task may also link to a category, alongside the
  # existing event link (`link_event_id`, task 30). One nullable FK per link target
  # type, `on_delete: :restrict` for the same reason as `link_event_id` — the context
  # (`WeddingPlanner.Categories.delete_category/2`) clears the link explicitly, inside
  # its own `Log.action/3`, before the category row is deleted, so a caller that forgets
  # that ordering fails loudly instead of orphaning the link.
  #
  # "At most one of `link_event_id`/`link_category_id` may be set" is enforced by both
  # the changeset (`WeddingPlanner.Tasks.Task.validate_link/1`) and, here, a database
  # CHECK spanning both columns — verified empirically (not assumed) against this
  # project's actual SQLite/exqlite version before writing this migration: a
  # column-level CHECK added via `ALTER TABLE ADD COLUMN` that references *another*,
  # pre-existing column of the same table **is** accepted and **is** enforced on both
  # INSERT and UPDATE (confirmed with a throwaway table exercising exactly this
  # ADD COLUMN + CHECK + cross-column reference shape, via `Exqlite.Sqlite3` directly).
  # No table rebuild is needed.
  def change do
    alter table(:tasks) do
      add :link_category_id, references(:categories, on_delete: :restrict),
        check: %{
          name: "tasks_link_at_most_one",
          expr: "link_event_id IS NULL OR link_category_id IS NULL"
        }
    end

    create index(:tasks, [:link_category_id])
  end
end
