defmodule WeddingPlanner.Repo.Migrations.AddOfferAndInvoiceLinksToTasks do
  use Ecto.Migration

  # Task 78 (`DR-8`, `DR-69`): a task may also link to an offer or an invoice, alongside
  # the existing event (`link_event_id`, task 30) and category (`link_category_id`, task
  # 32) links — this closes DR-8 ("T1 ships a polymorphic target for what exists; T4
  # completes it"). One nullable FK per link target type, `on_delete: :restrict` for the
  # same reason as the other two: the context (`WeddingPlanner.Offers.delete_offer/2`,
  # `WeddingPlanner.Invoices.delete_invoice/2`) clears the link explicitly, inside its own
  # `Log.action/3`, before the offer/invoice row is deleted, so a caller that forgets that
  # ordering fails loudly instead of orphaning the link.
  #
  # "At most one of the four link columns may be set" is enforced by both the changeset
  # (`WeddingPlanner.Tasks.Task.validate_link/1`) and, here, two more database CHECKs —
  # `add_link_category_to_tasks.exs`'s original two-column CHECK
  # (`tasks_link_at_most_one`) stays in place (subsumed, never dropped: SQLite has no
  # `DROP CONSTRAINT`, and it costs nothing to leave it), each new column's own CHECK
  # covers one more column added, exactly the same empirically-verified shape that
  # migration already establishes: a column-level CHECK added via `ALTER TABLE ADD COLUMN`
  # that references *other*, pre-existing columns of the same table **is** accepted and
  # **is** enforced on both INSERT and UPDATE — no table rebuild needed.
  #
  # Rollback order matters: `tasks_link_at_most_one_of_four` (added with
  # `link_invoice_id`) names `link_offer_id`, so SQLite refuses to drop `link_offer_id`
  # while that CHECK still exists — `link_invoice_id` (and its CHECK) must be dropped
  # first. `change/0` below adds `link_offer_id` then `link_invoice_id`; `mix ecto.rollback`
  # reverses an `alter table` block's commands in the order they were issued, so the
  # generated down migration drops `link_invoice_id` first, then `link_offer_id` — verified
  # empirically with `mix ecto.rollback` + `mix ecto.migrate` against the dev database
  # before this migration was considered done, not merely assumed from the Ecto docs.
  def change do
    alter table(:tasks) do
      add :link_offer_id, references(:offers, on_delete: :restrict),
        check: %{
          name: "tasks_link_at_most_one_of_three",
          expr:
            "(link_event_id IS NOT NULL) + (link_category_id IS NOT NULL) + (link_offer_id IS NOT NULL) <= 1"
        }

      add :link_invoice_id, references(:invoices, on_delete: :restrict),
        check: %{
          name: "tasks_link_at_most_one_of_four",
          expr:
            "(link_event_id IS NOT NULL) + (link_category_id IS NOT NULL) + (link_offer_id IS NOT NULL) + (link_invoice_id IS NOT NULL) <= 1"
        }
    end

    create index(:tasks, [:link_offer_id])
    create index(:tasks, [:link_invoice_id])
  end
end
