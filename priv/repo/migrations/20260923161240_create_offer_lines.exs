defmodule WeddingPlanner.Repo.Migrations.CreateOfferLines do
  use Ecto.Migration

  # `docs/modules/offers-and-comparison.md` CST-11, CST-20 through CST-23, CST-30 through
  # CST-33, CST-36; `docs/03-domain-model.md` (Offer line); `docs/04-cross-cutting.md`
  # XC-41, XC-42; `DR-41`, `DR-42`.
  #
  # Every structural rule of `WeddingPlanner.Offers.OfferLine.changeset/2` is backed here by
  # a named CHECK, so a raw `insert_all` that skips the changeset is still refused. SQLite
  # cannot `ALTER TABLE ADD CONSTRAINT`, so each multi-column rule sits on one of its
  # columns as an inline `check:` (SQLite lets a column CHECK read any column of the row) —
  # never `create constraint/3`.
  #
  # * `offer_id` — `null: false`, `on_delete: :restrict`: `WeddingPlanner.Offers.delete_offer/2`
  #   deletes an offer's lines explicitly (one log entry each) before the offer row.
  # * `service_id` / `event_id` — nullable, `on_delete: :restrict`. A service with lines
  #   cannot be deleted (CST-06; `Categories.delete_service/2` refuses, merge moves them,
  #   CST-04). An event with lines is detached first (`Offers.detach_event/2`, DR-42).
  # * `amount` / `minimum_charge` — `Money.Ecto.Map.Type` (`NFR-10`), in the offer's own
  #   VAT basis (CST-36). No money is checked or aggregated in SQL (`NFR-13`); the CHECKs
  #   below only ask whether a value is present. **"Absent" means SQL NULL *or* the JSON
  #   text `null`**: ecto_sqlite3's `:map` dumper JSON-encodes a `nil` written by an
  #   UPDATE (clearing a field) as the text `'null'` — a row inserted with `nil` gets a
  #   real NULL, the same row cleared later gets `'null'`. Both load back as `nil`. A plain
  #   `IS NULL` would refuse every clear, so these two columns are tested with
  #   `IFNULL(col, 'null') = 'null'` (absent) / `<> 'null'` (present).
  # * `vat_rate_bp` — the line's VAT override in hundredths of a percent, same encoding as
  #   `offers.vat_rate_bp` (`WeddingPlanner.Offers.VatRate`, DR-40). It is retained (and
  #   ignored by C3, CST-36 step 5) if the offer later turns VAT inclusive, so there is
  #   deliberately no CHECK tying it to the offer's basis — that "only settable while
  #   exclusive" rule is a context check.
  #
  # Deliberately absent:
  #
  # * **No CHECK requiring an event for a per-person line** (CST-31). Deleting an event
  #   nulls `event_id` on every line referencing it (XC-41, DR-42): the line then becomes
  #   *invalid* — it must survive, struck through, until a user repairs it (XC-42). Such a
  #   CHECK would make that detach impossible. The changeset enforces CST-31 on every write
  #   that touches `basis` or `event_id` instead.
  # * **No stored `invalid` column** (DR-41). Invalid is derived — per-person basis with no
  #   event (`OfferLine.invalid?/1`) — so it can never disagree with the row it describes.
  def change do
    create table(:offer_lines) do
      add :offer_id, references(:offers, on_delete: :restrict), null: false

      # CST-20: a line refers to a service OR is ad hoc with its own label — exactly one.
      add :service_id, references(:services, on_delete: :restrict),
        check: %{
          name: "offer_lines_service_xor_label",
          expr: "(service_id IS NULL) <> (label IS NULL)"
        }

      add :label, :string

      # CST-21: the five states; CST-22: an ad hoc line is only mandatory or optional.
      add :state, :string,
        null: false,
        check: %{
          name: "offer_lines_state_allowed",
          expr: """
          state IN ('included', 'optional', 'mandatory', 'not_offered', 'unknown')
          AND (service_id IS NOT NULL OR state IN ('mandatory', 'optional'))
          """
        }

      # CST-30: the four bases, no per-hour. CST-31/CST-32: a flat line has no event and no
      # included quantity.
      add :basis, :string,
        check: %{
          name: "offer_lines_basis_allowed",
          expr: """
          basis IS NULL
          OR (basis IN ('flat', 'per_adult', 'per_child', 'per_attendee')
            AND (basis <> 'flat' OR (event_id IS NULL AND included_quantity IS NULL)))
          """
        }

      # DR-41: a priced state (mandatory, optional) carries a basis and an amount.
      add :amount, :map,
        check: %{
          name: "offer_lines_priced_state_has_basis_and_amount",
          expr: """
          state NOT IN ('mandatory', 'optional')
          OR (basis IS NOT NULL AND IFNULL(amount, 'null') <> 'null')
          """
        }

      # DR-41: an unpriced state (included, not offered, unknown) carries no pricing field.
      add :minimum_charge, :map,
        check: %{
          name: "offer_lines_unpriced_state_has_no_pricing",
          expr: """
          state IN ('mandatory', 'optional')
          OR (basis IS NULL AND IFNULL(amount, 'null') = 'null' AND event_id IS NULL
            AND included_quantity IS NULL AND IFNULL(minimum_charge, 'null') = 'null'
            AND vat_rate_bp IS NULL)
          """
        }

      add :event_id, references(:events, on_delete: :restrict)

      # CST-32: included quantity is a non-negative person count.
      add :included_quantity, :integer,
        check: %{
          name: "offer_lines_included_quantity_non_negative",
          expr: "included_quantity IS NULL OR included_quantity >= 0"
        }

      # CST-33: a rate between 0 and 100 %, in hundredths of a percent (DR-40).
      add :vat_rate_bp, :integer,
        check: %{
          name: "offer_lines_vat_rate_bp_range",
          expr: "vat_rate_bp IS NULL OR (vat_rate_bp >= 0 AND vat_rate_bp <= 10000)"
        }

      # CST-22: only an optional ad hoc line has an on/off toggle (default off). SQLite has
      # no boolean type, so the CHECK also pins the column to 0/1.
      add :enabled, :boolean,
        null: false,
        default: false,
        check: %{
          name: "offer_lines_enabled_only_optional_ad_hoc",
          expr: "enabled IN (0, 1) AND (enabled = 0 OR (service_id IS NULL AND state = 'optional'))"
        }

      timestamps(type: :utc_datetime)
    end

    create index(:offer_lines, [:offer_id])
    create index(:offer_lines, [:service_id])
    create index(:offer_lines, [:event_id])
  end
end
