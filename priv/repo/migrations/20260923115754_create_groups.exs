defmodule WeddingPlanner.Repo.Migrations.CreateGroups do
  use Ecto.Migration

  # `docs/modules/guests-and-events.md` PER-03, PER-07, `docs/03-domain-model.md` Group,
  # `DR-26` Q10.
  #
  # Groups are purely organisational: a name and an optional free-text type label
  # ("household", "circle"...). No unique constraint on `name` — two groups sharing a
  # name is not an error.
  def change do
    create table(:groups) do
      add :name, :string, null: false
      add :type_label, :string

      timestamps(type: :utc_datetime)
    end
  end
end
