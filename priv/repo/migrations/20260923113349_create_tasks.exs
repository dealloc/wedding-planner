defmodule WeddingPlanner.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  # `docs/modules/tasks-and-timeline.md` TSK-01 through TSK-04, `04-cross-cutting.md`
  # XC-41/EVT-05, `06-decisions.md` D-10/D-28.
  #
  # * `owner_id` + `owner_shared` (D-28): the owner is a nullable reference to a user
  #   plus a boolean flag, never a four-value enum — see the CHECK constraint below.
  #   `on_delete: :restrict` — a user is never silently unassigned; v1 has no user
  #   deletion flow at all.
  # * `deadline_kind`/`deadline_date`/`deadline_amount`/`deadline_unit`/
  #   `deadline_direction`/`deadline_event_id` together encode TSK-02's three-way
  #   deadline shape (none / fixed / relative). `deadline_event_id` is
  #   `on_delete: :restrict`, deliberately: `WeddingPlanner.Tasks.detach_event/2` clears
  #   every anchored deadline (and logs it, XC-41) *before* the event row is deleted, so
  #   this FK exists purely to make a path that forgets to call it fail loudly instead of
  #   silently orphaning a deadline.
  # * `link_event_id` (Q17, DR-26): one nullable FK per link target type, polymorphic in
  #   the API. Only events exist as a target in this slice; task 32 adds
  #   `link_category_id` alongside an "at most one set" rule spanning both columns.
  #   Same `:restrict` reasoning as `deadline_event_id` —
  #   `WeddingPlanner.Tasks.detach_event/2` clears the link first.
  # * `deadline_amount` has no unit normalisation (Q16): the unit is stored as entered.
  def change do
    create table(:tasks) do
      add :title, :string, null: false
      add :notes, :text
      add :status, :string, null: false

      add :owner_id, references(:users, on_delete: :restrict)

      add :owner_shared, :boolean,
        null: false,
        default: false,
        check: %{
          name: "owner_shared_implies_no_owner",
          expr: "NOT owner_shared OR owner_id IS NULL"
        }

      add :deadline_kind, :string, null: false, default: "none"
      add :deadline_date, :date
      add :deadline_amount, :integer
      add :deadline_unit, :string
      add :deadline_direction, :string
      add :deadline_event_id, references(:events, on_delete: :restrict)

      add :link_event_id, references(:events, on_delete: :restrict)

      timestamps(type: :utc_datetime)
    end

    create index(:tasks, [:owner_id])
    create index(:tasks, [:deadline_event_id])
    create index(:tasks, [:link_event_id])
  end
end
