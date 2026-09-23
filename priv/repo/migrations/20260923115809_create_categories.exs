defmodule WeddingPlanner.Repo.Migrations.CreateCategories do
  use Ecto.Migration

  # `docs/modules/offers-and-comparison.md` CST-01, CST-05; `docs/03-domain-model.md`'s
  # Category entity: user-defined, each with an optional target amount and a sort order.
  #
  # * `target` uses the same `:map` column type as `settings.overall_budget`
  #   (`Money.Ecto.Map.Type`, `NFR-10`) — nullable: "no target set" is a real state, not a
  #   fake €0,00 (`BUD-03` later counts an unset target as zero; this migration does not
  #   care).
  # * `sort_order` is the only supported display order (`CST-01`), same shape as
  #   `events.sort_order` — no unique constraint, since reordering
  #   (`WeddingPlanner.Categories.move_category/3`) resolves concurrently as
  #   last-write-wins with no locking (`XC-02`); a transient duplicate value between two
  #   racing writers is acceptable and self-heals on the next move.
  def change do
    create table(:categories) do
      add :name, :string, null: false
      add :target, :map
      add :sort_order, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:categories, [:sort_order])
  end
end
