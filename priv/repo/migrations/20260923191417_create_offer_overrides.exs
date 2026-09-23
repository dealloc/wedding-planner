defmodule WeddingPlanner.Repo.Migrations.CreateOfferOverrides do
  use Ecto.Migration

  # `docs/modules/offers-and-comparison.md` CST-24, CST-52; `docs/03-domain-model.md`
  # (Override); `DR-49`, `DR-56`.
  #
  # One row per offer × service that **deviates** from the category's wanted priority for
  # that one offer (`CST-24`). `WeddingPlanner.Offers.toggle_override/3` never writes a
  # row that agrees with the priority-only default — see that function's moduledoc — so a
  # row's mere presence already means "this cell is marked" until the priority moves and
  # catches up with it (the row is kept, not deleted, when that happens).
  #
  # * `offer_id` / `service_id` — both `null: false`, `on_delete: :restrict`:
  #   `WeddingPlanner.Offers.delete_offer/2` removes an offer's overrides explicitly
  #   (logged) before the offer row; `WeddingPlanner.Categories.delete_service/2` and
  #   `merge_services/3` do the same for a service's overrides before it is deleted or
  #   merged away.
  # * `wanted` — SQLite has no boolean type, so the CHECK also pins the column to 0/1
  #   (same convention as `offer_lines.enabled`).
  # * Unique index on `[:offer_id, :service_id]` — at most one override per cell
  #   (`DR-49`); `toggle_override/3`'s upsert targets it. Plain index on `:service_id`
  #   alone for the service-side lookups (service deletion, merge).
  def change do
    create table(:offer_overrides) do
      add :offer_id, references(:offers, on_delete: :restrict), null: false
      add :service_id, references(:services, on_delete: :restrict), null: false

      add :wanted, :boolean,
        null: false,
        check: %{name: "offer_overrides_wanted_boolean", expr: "wanted IN (0, 1)"}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:offer_overrides, [:offer_id, :service_id])
    create index(:offer_overrides, [:service_id])
  end
end
