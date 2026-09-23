defmodule WeddingPlanner.Repo.Migrations.AddPlusOneFieldsToPersons do
  use Ecto.Migration

  # Task 35 (`DR-32`), `docs/modules/guests-and-events.md` PER-10 through PER-16.
  #
  # * `host_id` — a nullable self-FK on `persons`. Set means "this person is a +1 of the
  #   referenced person" (PER-10). `on_delete: :restrict`: `WeddingPlanner.Guests` always
  #   deletes a host's +1s explicitly, inside its own `Log.action/3`, *before* deleting
  #   the host row (PER-16, `XC-10`), so this FK should never actually fire — same
  #   defensive stance as `link_event_id`/`link_category_id` on `tasks`. A CHECK rejects
  #   `host_id = id` (no self-hosting; "no chains" is enforced in
  #   `WeddingPlanner.Guests.add_plus_one/3`, which refuses a host that is itself a +1 —
  #   the DB cannot express "not a +1" without a second query).
  # * `plus_one_status` — nullable string backing `Ecto.Enum` `:possible | :confirmed`.
  #   A CHECK ties it to `host_id`: set iff `host_id` is set, so a plain (non-+1) person
  #   can never carry a stray +1 status and a +1 can never be missing one. This CHECK
  #   references `host_id`, so it is added in a *second* `alter table` block, after the
  #   first has committed `host_id` to the table — column-level CHECKs added via
  #   `ALTER TABLE ADD COLUMN` that reference another, already-existing column of the same
  #   table are accepted and enforced on both INSERT and UPDATE, verified empirically
  #   against this project's SQLite/exqlite version (see
  #   `priv/repo/migrations/20260923122515_add_link_category_to_tasks.exs`'s comment for
  #   the throwaway-table verification this relies on). No table rebuild is needed.
  #
  # `name_known` (PER-11) is deliberately **not** a column: it is derived from whether a
  # +1 has a first or last name (`WeddingPlanner.Guests.Person.name_known?/1`) — storage
  # layout is not binding (`docs/03-domain-model.md`), and a stored flag could drift from
  # the name fields it is supposed to describe.
  #
  # A +1's own `want_tier`/`certainty` columns are untouched here: they stay `not null`
  # (SQLite cannot relax that without a table rebuild) and are written from the host at
  # creation, refused on update, and never read — see `WeddingPlanner.Guests.PlusOne`.
  def change do
    alter table(:persons) do
      add :host_id, references(:persons, on_delete: :restrict),
        check: %{
          name: "persons_host_not_self",
          expr: "host_id IS NULL OR host_id <> id"
        }
    end

    create index(:persons, [:host_id])

    alter table(:persons) do
      add :plus_one_status, :string,
        check: %{
          name: "persons_plus_one_status_iff_host",
          expr: "(host_id IS NULL) = (plus_one_status IS NULL)"
        }
    end
  end
end
