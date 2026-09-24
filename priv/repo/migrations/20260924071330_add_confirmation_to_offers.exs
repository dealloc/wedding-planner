defmodule WeddingPlanner.Repo.Migrations.AddConfirmationToOffers do
  use Ecto.Migration

  # `docs/modules/offers-and-comparison.md` CST-06, CST-40, CST-43, CST-44;
  # `docs/06-decisions.md` D-20, D-22, D-27; `DR-61`, `DR-66` — slice C5's storage.
  #
  # `offer_frozen_services` — a confirmed offer's **frozen selection** (`CST-40`): one row
  # per service that was effectively wanted when the offer was confirmed, plus any service
  # later added to the confirmed scope (`CST-43`). Services, not line ids (`D-27`).
  # Optional ad hoc lines need no row: their own `enabled` flag is already per offer and
  # nothing elsewhere in the category can change it, so it *is* their frozen state
  # (`DR-61`). Rows exist only while the offer is confirmed (context-enforced, task 73);
  # `WeddingPlanner.Valuation.Selection` ignores stray rows on any other offer.
  #
  # * `offer_id` / `service_id` — both `null: false`, `on_delete: :restrict`: a frozen
  #   service is never deletable (`CST-06`'s last sentence) — the service-side FK backs the
  #   context's refusal, and makes a merge an explicit, logged move of the rows (`DR-67`);
  #   un-confirming and deleting an offer remove its rows explicitly (logged) before the
  #   offer row changes.
  # * Unique index on `[:offer_id, :service_id]` — a service is in a frozen selection once;
  #   plain index on `:service_id` for the service-side lookups (deletion, merge).
  # * `updated_at: false` — a row is inserted or deleted, never changed.
  #
  # `offers.planning_pick` (`CST-44`, `D-22`, `DR-66`) — at most one per category, never on
  # a confirmed or rejected offer. SQLite has no boolean type, so the CHECK also pins the
  # column to 0/1 (same convention as `offers.invoicing_complete`). The CHECK ties the pick
  # to `status`, so the context writes both in the **same** `UPDATE` (confirming or
  # rejecting the pick clears it). The partial unique index enforces "one per category".
  def change do
    create table(:offer_frozen_services) do
      add :offer_id, references(:offers, on_delete: :restrict), null: false
      add :service_id, references(:services, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:offer_frozen_services, [:offer_id, :service_id])
    create index(:offer_frozen_services, [:service_id])

    alter table(:offers) do
      add :planning_pick, :boolean,
        null: false,
        default: false,
        check: %{
          name: "offers_planning_pick_requires_open_status",
          expr:
            "planning_pick IN (0, 1) AND " <>
              "(planning_pick = 0 OR status NOT IN ('confirmed', 'rejected'))"
        }
    end

    create unique_index(:offers, [:category_id],
             where: "planning_pick = 1",
             name: :offers_one_planning_pick_per_category
           )
  end
end
