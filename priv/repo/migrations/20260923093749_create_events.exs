defmodule WeddingPlanner.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  # `docs/modules/guests-and-events.md` EVT-01 through EVT-05: the exemplar domain
  # entity every later slice's CRUD pattern is copied from.
  #
  # * `name` is required; `date`, `location` and `notes` are all nullable — EVT-02/EVT-03:
  #   events may be on different days (or none at all yet) and nothing may assume a
  #   shared date.
  # * `date` is a plain `:date` column (NFR-20) — never `:utc_datetime` — so it can never
  #   be shifted by a day through a time zone conversion.
  # * `sort_order` is the only supported display order (EVT-04); there is no unique
  #   constraint on it because reordering (`WeddingPlanner.Events.move_event/3`) resolves
  #   concurrently as last-write-wins with no locking (XC-02) — a transient duplicate
  #   value between two racing writers is acceptable and self-heals on the next move.
  def change do
    create table(:events) do
      add :name, :string, null: false
      add :date, :date
      add :location, :string
      add :sort_order, :integer, null: false
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:events, [:sort_order])
  end
end
