defmodule WeddingPlanner.Repo.Migrations.CreatePersons do
  use Ecto.Migration

  # `docs/modules/guests-and-events.md` PER-01 through PER-07, `docs/03-domain-model.md`
  # Person, `D-29`.
  #
  # * `first_name`/`last_name` are both nullable — PER-02 requires at least one, enforced
  #   in `WeddingPlanner.Guests.Person`'s changeset, not at the database level.
  # * `age_category`, `want_tier`, `certainty` are `not null` strings backing
  #   `Ecto.Enum`s. The fixed atoms they store are already set by
  #   `WeddingPlanner.Valuation.Preset` (task 23), which the headcount engine reads.
  # * `group_id` is `on_delete: :nilify_all` as a backstop only: every real deletion path
  #   goes through `WeddingPlanner.Guests.delete_group/2`, which ungroups each member
  #   explicitly (and logs it, `XC-10`) *before* deleting the group row, so this FK
  #   action should never actually fire in practice.
  def change do
    create table(:persons) do
      add :first_name, :string
      add :last_name, :string
      add :age_category, :string, null: false
      add :want_tier, :string, null: false
      add :certainty, :string, null: false
      add :notes, :text
      add :group_id, references(:groups, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:persons, [:group_id])
  end
end
