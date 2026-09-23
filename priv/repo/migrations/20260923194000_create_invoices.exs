defmodule WeddingPlanner.Repo.Migrations.CreateInvoices do
  use Ecto.Migration

  # `docs/modules/invoices-and-budget.md` BIL-01 through BIL-06; `docs/04-cross-cutting.md`
  # XC-10, XC-12, XC-20 through XC-24, XC-40; `docs/06-decisions.md` D-08, D-09; `DR-28`,
  # `DR-58`, `DR-59` — slice B2's invoices data layer.
  #
  # * `invoices.category_id` — `null: false`, `on_delete: :restrict`: an invoice always
  #   belongs to an existing category, same backstop role as `offers.category_id`;
  #   `WeddingPlanner.Categories.category_deletion_blockers/1` refuses to delete a category
  #   with invoices (`DR-26` Q11).
  # * `invoices.offer_id` — nullable (`BIL-01`: invoices without an offer are allowed),
  #   `on_delete: :restrict`. Linking to a confirmed offer of the same category is a
  #   context-level check (`DR-58`) — it needs a join the DB CHECK mechanism cannot express
  #   on a single column, so it lives in `WeddingPlanner.Invoices`, re-run on every write
  #   that sets `offer_id`. `WeddingPlanner.Offers.offer_deletion_blockers/1` refuses to
  #   delete an offer with linked invoices.
  # * `invoices.paid_on` — presence is the derived "paid" flag (`Invoice.paid?/1`, `BIL-02`);
  #   there is deliberately no separate stored boolean to keep the two from disagreeing.
  # * `invoice_lines.amount` — `Money.Ecto.Map.Type` (`NFR-10`), `null: false`: BIL-03's
  #   static, VAT-inclusive line amount. No CHECK needed beyond `null: false` — unlike
  #   `offer_lines.amount`, this column is never cleared by an update (a line's amount is
  #   always required, `BIL-02`), so the `DR-45` "JSON `null` vs SQL `NULL`" trap that
  #   forces `offer_lines`' `IFNULL(...) = 'null'` CHECKs never arises here.
  def change do
    create table(:invoices) do
      add :category_id, references(:categories, on_delete: :restrict), null: false
      add :offer_id, references(:offers, on_delete: :restrict)
      add :label, :string, null: false
      add :invoice_date, :date, null: false
      add :due_date, :date
      add :paid_on, :date

      timestamps(type: :utc_datetime)
    end

    create index(:invoices, [:category_id])
    create index(:invoices, [:offer_id])

    create table(:invoice_lines) do
      add :invoice_id, references(:invoices, on_delete: :restrict), null: false
      add :label, :string, null: false
      add :amount, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:invoice_lines, [:invoice_id])

    # `DR-58`: `invoicing_complete` can only be true on a confirmed offer. The changeset
    # (`WeddingPlanner.Invoices.set_invoicing_complete/3`) refuses the same thing before it
    # ever reaches SQL; this CHECK is the backstop against a raw `UPDATE`.
    alter table(:offers) do
      add :invoicing_complete, :boolean,
        null: false,
        default: false,
        check: %{
          name: "offers_invoicing_complete_requires_confirmed",
          expr: "invoicing_complete IN (0, 1) AND (invoicing_complete = 0 OR status = 'confirmed')"
        }
    end

    # `DR-28`: B2's half of the "exactly one owner" CHECK — `offer_id` was added nullable by
    # C2's migration; every reference in real use already carries it (no ownerless rows in
    # real use), so the existing rows satisfy this CHECK unchanged.
    alter table(:references) do
      add :invoice_id, references(:invoices, on_delete: :restrict),
        check: %{
          name: "references_exactly_one_owner",
          expr: "(offer_id IS NULL) <> (invoice_id IS NULL)"
        }
    end

    create index(:references, [:invoice_id])
  end

  def down do
    drop index(:references, [:invoice_id])

    alter table(:references) do
      remove :invoice_id
    end

    alter table(:offers) do
      remove :invoicing_complete
    end

    drop index(:invoice_lines, [:invoice_id])
    drop table(:invoice_lines)

    drop index(:invoices, [:offer_id])
    drop index(:invoices, [:category_id])
    drop table(:invoices)
  end
end
