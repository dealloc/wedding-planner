defmodule WeddingPlanner.Repo.Migrations.CreateInvitationsAndPlusOneOptOuts do
  use Ecto.Migration

  # Task 44 (`DR-37`), `docs/modules/guests-and-events.md` INVT-01–04, PER-13, PER-14.
  #
  # * `invitations` (`WeddingPlanner.Invitations.Invitation`) — one row per (non-+1)
  #   person × event with a status. `status` is a `not null` string backing `Ecto.Enum`
  #   `:planned | :invited | :accepted | :declined`, pinned by a column CHECK to exactly
  #   those four strings (mirroring `WeddingPlanner.Valuation.Preset.invitation_status/0`
  #   — the same atoms the headcount engine reads). *Not invited* is deliberately not a
  #   fifth value: it is the absence of a row, so `WeddingPlanner.Invitations` deletes
  #   the row instead of ever writing that string.
  # * `plus_one_opt_outs` (`WeddingPlanner.Invitations.PlusOneOptOut`) — one row per
  #   (+1) person × event that the +1 has opted out of (`PER-13`); presence alone is the
  #   signal, no status column. PER-14 lets an opt-out exist regardless of the host's own
  #   status, so this table never checks the host's invitation.
  # * Both `person_id` and `event_id` are `references(..., on_delete: :restrict)`,
  #   deliberately not a cascade: `WeddingPlanner.Invitations.delete_for_persons/1` and
  #   `detach_event/2` remove the rows explicitly, inside the caller's own
  #   `Log.action/3`/transaction, so each removal is logged (`XC-10`) against the right
  #   entity — a bare FK cascade would silently drop rows with no activity entry. Same
  #   defensive stance as `persons.host_id`/`tasks.deadline_event_id`.
  # * Unique index on `[:person_id, :event_id]` on both tables — one row per cell — plus
  #   a plain index on `:event_id` alone for the event-side lookups
  #   (`detach_event/2`, the two EVT-05 providers). The unique index's leading column
  #   already covers person-side lookups (`statuses_for_person/1`,
  #   `opted_out_event_ids/1`).
  # * Whether a given person is allowed a row in a given table (a +1 can never get an
  #   invitation, a non-+1 can never get an opt-out) is enforced in
  #   `WeddingPlanner.Invitations`, not here: `persons.host_id` is immutable (`DR-32`),
  #   so that check cannot race, and expressing "is/is not a +1" as a column-level CHECK
  #   would need a subquery, which SQLite's CHECK constraints do not support.
  def change do
    create table(:invitations) do
      add :person_id, references(:persons, on_delete: :restrict), null: false
      add :event_id, references(:events, on_delete: :restrict), null: false

      add :status, :string,
        null: false,
        check: %{
          name: "invitations_status_values",
          expr: "status IN ('planned','invited','accepted','declined')"
        }

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invitations, [:person_id, :event_id])
    create index(:invitations, [:event_id])

    create table(:plus_one_opt_outs) do
      add :person_id, references(:persons, on_delete: :restrict), null: false
      add :event_id, references(:events, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:plus_one_opt_outs, [:person_id, :event_id])
    create index(:plus_one_opt_outs, [:event_id])
  end
end
