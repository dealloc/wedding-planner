defmodule WeddingPlanner.Repo.Migrations.CreateOffersAndReferenceOfferId do
  use Ecto.Migration

  # `docs/modules/offers-and-comparison.md` CST-10, CST-33, CST-36; `docs/04-cross-cutting.md`
  # XC-20 through XC-24; `DR-40`, `DR-28`.
  #
  # * `category_id` is `on_delete: :restrict` — an offer always belongs to an existing
  #   category, and `WeddingPlanner.Categories.category_deletion_blockers/1` now refuses to
  #   delete a category that still has offers (`DR-26` Q11), so this FK should never actually
  #   fire in normal use; it is a backstop, same role as `services.category_id`.
  # * `status` is a plain string with a column CHECK pinning it to the four values the
  #   schema's `Ecto.Enum` knows (`considering`, `shortlisted`, `rejected`, `confirmed`) —
  #   same pattern as `services.wanted_priority`. C2 refuses to ever *write* `confirmed`
  #   (that is slice C5's frozen-selection work, `CST-40`/`CST-42`); the CHECK already
  #   accepts it so C5 needs no migration of its own.
  # * `vat_basis` (`inclusive`/`exclusive`, `CST-33`) and `vat_rate_bp` (the offer's default
  #   VAT rate, in **hundredths of a percent** — `2100` = 21 % — so SQLite never stores a
  #   float) are linked by two column CHECKs: `vat_rate_bp`'s own range (`NULL`, or `0..10000`
  #   inclusive — a rate cannot exceed 100 %), and `vat_basis`'s CHECK ties the two together
  #   (`exclusive` ⇔ `vat_rate_bp NOT NULL`) alongside pinning `vat_basis` itself to its two
  #   allowed values, so a raw `insert_all` of an exclusive offer with no rate (or an
  #   inclusive offer carrying a stray rate) is refused at the database, not just by the
  #   changeset.
  # * `minimum_spend` uses the same `:map` column as `categories.target`
  #   (`Money.Ecto.Map.Type`, `NFR-10`) — nullable, and **always VAT inclusive** (`CST-36`);
  #   nothing here enforces that (it is just what the value means), C3 relies on it.
  # * `url` and `notes` carry no column CHECK: the http/https scheme rule (`DR-29`, same as
  #   `references.url`) is a changeset-level validation only, exactly like `Reference`'s own
  #   URL field.
  # * No planning-pick, invoicing-complete or frozen-selection columns yet — C5/B2 add them
  #   with their own `ALTER TABLE ADD COLUMN` once they exist (`DR-40`).
  #
  # `references.offer_id` (`DR-28`): nullable — B2 later adds `invoice_id` and the "exactly
  # one of" CHECK once invoices exist; until then every reference in real use has an
  # `offer_id`, but the column itself cannot be `NOT NULL` (a reference table with no owner
  # at all is still how B1 leaves it before this migration runs, and B2 needs the same
  # nullable shape for its own column). `on_delete: :restrict` — `WeddingPlanner.Offers`
  # deletes an offer's references explicitly, one `Log.entry/3` each, *before* deleting the
  # offer row (`References.delete_owner_references/2`, called inside the offer's own
  # `Log.action/3`), so this FK should also never actually fire; it is the same backstop role
  # as every other `on_delete: :restrict` FK in this schema.
  def change do
    create table(:offers) do
      add :category_id, references(:categories, on_delete: :restrict), null: false
      add :vendor_name, :string, null: false
      add :url, :string
      add :notes, :text

      add :status, :string,
        null: false,
        default: "considering",
        check: %{
          name: "offers_status_allowed",
          expr: "status IN ('considering', 'shortlisted', 'rejected', 'confirmed')"
        }

      add :vat_basis, :string,
        null: false,
        default: "inclusive",
        check: %{
          name: "offers_vat_basis_matches_rate",
          expr: """
          vat_basis IN ('inclusive', 'exclusive')
          AND ((vat_basis = 'exclusive' AND vat_rate_bp IS NOT NULL)
            OR (vat_basis = 'inclusive' AND vat_rate_bp IS NULL))
          """
        }

      add :vat_rate_bp, :integer,
        check: %{
          name: "offers_vat_rate_bp_range",
          expr: "vat_rate_bp IS NULL OR (vat_rate_bp >= 0 AND vat_rate_bp <= 10000)"
        }

      add :minimum_spend, :map

      timestamps(type: :utc_datetime)
    end

    create index(:offers, [:category_id])

    alter table(:references) do
      add :offer_id, references(:offers, on_delete: :restrict)
    end

    create index(:references, [:offer_id])
  end
end
