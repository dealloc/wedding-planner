defmodule WeddingPlanner.Repo.Migrations.CreateServices do
  use Ecto.Migration

  # `docs/modules/offers-and-comparison.md` CST-02, CST-03, CST-04; `DR-26` Q14.
  #
  # * `category_id` is `on_delete: :restrict` — `WeddingPlanner.Categories.delete_category/2`
  #   deletes every one of the category's services explicitly (each logged) *before*
  #   deleting the category row itself; the same "restrict, then explicit delete first"
  #   pattern `tasks.deadline_event_id` uses against `events`.
  # * `wanted_priority` mirrors `tasks.status`: an `Ecto.Enum` on the schema side, stored
  #   here as a plain string.
  # * `sort_order` is scoped to the category (`[:category_id, :sort_order]` index) — no
  #   uniqueness constraint on it, for the same last-write-wins reason as
  #   `categories.sort_order` (`XC-02`).
  # * The unique index on `(category_id, lower(name))` is a **backstop** to the
  #   changeset's own case-insensitive, Unicode-aware uniqueness check
  #   (`WeddingPlanner.Categories.validate_name_unique_in_category/3`, `DR-26` Q14) —
  #   SQLite's built-in `lower()` only folds ASCII, so this index only catches the ASCII
  #   subset of collisions the changeset already catches in full. It exists purely so a
  #   race between two writers cannot slip an ASCII-case duplicate past the application
  #   check; it is not, on its own, Unicode-aware uniqueness.
  def change do
    create table(:services) do
      add :category_id, references(:categories, on_delete: :restrict), null: false
      add :name, :string, null: false
      add :wanted_priority, :string, null: false
      add :sort_order, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:services, [:category_id, :sort_order])

    create unique_index(:services, [:category_id, "lower(name)"],
             name: :services_category_id_lower_name_index
           )
  end
end
