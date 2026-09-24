defmodule WeddingPlanner.InvoicesTest do
  @moduledoc """
  `docs/modules/invoices-and-budget.md` `BIL-01` through `BIL-07`; `docs/04-cross-cutting.md`
  `XC-01`, `XC-10`–`XC-12`, `XC-20`–`XC-24`, `XC-40`; `docs/06-decisions.md` `D-08`, `D-09`;
  `DR-28`, `DR-58`, `DR-59` — slice B2's invoices data layer.

  `async: false`: the reference-deletion tests diff `:uploads_dir`, same reason
  `WeddingPlanner.OffersTest` is `async: false`.
  """
  use WeddingPlanner.DataCase, async: false

  import WeddingPlanner.InvoiceFixtures
  import WeddingPlanner.OfferFixtures

  import WeddingPlanner.ReferenceFixtures,
    only: [write_fixture!: 3, tmp_upload_dir!: 0, track_uploads_dir: 0]

  alias WeddingPlanner.Categories
  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Invoices.InvoiceLine
  alias WeddingPlanner.Log.EntityRef
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.References
  alias WeddingPlanner.References.Reference
  alias WeddingPlanner.References.Storage
  alias WeddingPlanner.Tasks

  setup do
    scope = scope_fixture()
    category = category_fixture(scope)
    %{scope: scope, category: category}
  end

  defp entries, do: Repo.all(from e in Entry, order_by: e.id)
  defp entries_after(count), do: entries() |> Enum.drop(count)

  # -- create_invoice/4 (BIL-01, BIL-02) --------------------------------------------------

  describe "create_invoice/4 (BIL-01, BIL-02)" do
    test "creates an invoice with its first line: one summary, one child", %{
      scope: scope,
      category: category
    } do
      before_count = length(entries())

      assert {:ok, invoice} =
               Invoices.create_invoice(
                 scope,
                 category,
                 %{"label" => "Venue deposit", "invoice_date" => ~D[2027-01-01]},
                 %{"label" => "Deposit", "amount_input" => "3.000"}
               )

      assert invoice.label == "Venue deposit"
      assert invoice.category_id == category.id
      assert is_nil(invoice.offer_id)
      refute Invoice.paid?(invoice)

      assert [line] = Repo.all(from l in InvoiceLine, where: l.invoice_id == ^invoice.id)
      assert line.label == "Deposit"
      assert Money.equal?(line.amount, WeddingPlanner.Money.new(3000))

      new_entries = entries_after(before_count)
      {[summary], children} = Enum.split_with(new_entries, &is_nil(&1.entity_type))

      assert summary.description == "Wannes added invoice 'Venue deposit' to Venue"
      assert [child] = children
      assert child.parent_id == summary.id
      assert child.entity_type == "invoice"
      assert child.entity_id == invoice.id

      assert child.description ==
               "Wannes added line 'Deposit' (€ 3.000,00) to invoice 'Venue deposit'"
    end

    test "broadcasts {:created, invoice} on :invoice and {:created, line} on :invoice_line", %{
      scope: scope,
      category: category
    } do
      Realtime.subscribe(:invoice)
      Realtime.subscribe(:invoice_line)

      assert {:ok, invoice} =
               Invoices.create_invoice(
                 scope,
                 category,
                 %{"label" => "Venue deposit", "invoice_date" => ~D[2027-01-01]},
                 %{"label" => "Deposit", "amount_input" => "3.000"}
               )

      assert_received {Realtime, :invoice, {:created, ^invoice}}
      assert_received {Realtime, :invoice_line, {:created, %InvoiceLine{}}}
    end

    test "an invalid first line creates nothing", %{scope: scope, category: category} do
      before_count = length(entries())

      assert {:error, changeset} =
               Invoices.create_invoice(
                 scope,
                 category,
                 %{"label" => "Venue deposit", "invoice_date" => ~D[2027-01-01]},
                 %{"label" => "Deposit", "amount_input" => "3000.50"}
               )

      assert "Use a comma for the decimal part (cents) — for example 45000,50, not 45000.50." in errors_on(
               changeset
             ).amount_input

      assert Repo.aggregate(Invoice, :count) == 0
      assert Repo.aggregate(InvoiceLine, :count) == 0
      assert entries_after(before_count) == []
    end

    test "an invalid invoice also creates nothing", %{scope: scope, category: category} do
      assert {:error, _changeset} =
               Invoices.create_invoice(
                 scope,
                 category,
                 %{"label" => "", "invoice_date" => ~D[2027-01-01]},
                 %{"label" => "Deposit", "amount_input" => "3.000"}
               )

      assert Repo.aggregate(Invoice, :count) == 0
      assert Repo.aggregate(InvoiceLine, :count) == 0
    end
  end

  # -- InvoiceLine amount_input (DR-23, DR-18, DR-46) -------------------------------------

  describe "InvoiceLine amount_input (DR-23, DR-18, DR-46)" do
    test "\"3.000\" stores € 3.000,00", %{scope: scope, category: category} do
      invoice = invoice_fixture(scope, category, %{}, %{"amount_input" => "3.000"})
      [line] = invoice.lines
      assert Money.equal?(line.amount, WeddingPlanner.Money.new(3000))
    end

    test "\"3000,50\" stores € 3.000,50", %{scope: scope, category: category} do
      invoice = invoice_fixture(scope, category, %{}, %{"amount_input" => "3000,50"})
      [line] = invoice.lines
      assert Money.equal?(line.amount, WeddingPlanner.Money.new(Decimal.new("3000.50")))
    end

    test "\"3000.50\" is refused with the DR-23 comma message", %{
      scope: scope,
      category: category
    } do
      assert {:error, changeset} =
               Invoices.create_invoice(
                 scope,
                 category,
                 %{"label" => "X", "invoice_date" => ~D[2027-01-01]},
                 %{"label" => "Deposit", "amount_input" => "3000.50"}
               )

      assert "Use a comma for the decimal part (cents) — for example 45000,50, not 45000.50." in errors_on(
               changeset
             ).amount_input
    end

    test "\"-5\" is refused (negative)", %{scope: scope, category: category} do
      assert {:error, changeset} =
               Invoices.create_invoice(
                 scope,
                 category,
                 %{"label" => "X", "invoice_date" => ~D[2027-01-01]},
                 %{"label" => "Deposit", "amount_input" => "-5"}
               )

      assert "Amounts cannot be negative." in errors_on(changeset).amount_input
    end

    test "a typed %Money{} under :amount is accepted", %{scope: scope, category: category} do
      assert {:ok, invoice} =
               Invoices.create_invoice(
                 scope,
                 category,
                 %{"label" => "X", "invoice_date" => ~D[2027-01-01]},
                 %{"label" => "Deposit", "amount" => WeddingPlanner.Money.new(500)}
               )

      [line] = invoice.lines
      assert Money.equal?(line.amount, WeddingPlanner.Money.new(500))
    end

    test "a string under :amount is refused, never converted (DR-18)", %{
      scope: scope,
      category: category
    } do
      assert {:error, changeset} =
               Invoices.create_invoice(
                 scope,
                 category,
                 %{"label" => "X", "invoice_date" => ~D[2027-01-01]},
                 %{"label" => "Deposit", "amount" => "500"}
               )

      assert errors_on(changeset).amount_input != []
    end
  end

  # -- delete_line/2 (last-line refusal, DR-59) -------------------------------------------

  describe "delete_line/2 — refuses the last line" do
    test "deleting the invoice's only line is refused", %{scope: scope, category: category} do
      invoice = invoice_fixture(scope, category)
      [line] = invoice.lines

      assert Invoices.delete_line(scope, line) == {:error, :last_line}
      assert Repo.get(InvoiceLine, line.id)
    end

    test "with two lines, deleting one works and logs", %{scope: scope, category: category} do
      invoice = invoice_fixture(scope, category)
      [first_line] = invoice.lines

      {:ok, second_line} =
        Invoices.create_line(scope, invoice, %{"label" => "Balance", "amount_input" => "500"})

      before_count = length(entries())
      assert {:ok, deleted} = Invoices.delete_line(scope, second_line)
      assert deleted.id == second_line.id
      refute Repo.get(InvoiceLine, second_line.id)
      assert Repo.get(InvoiceLine, first_line.id)

      assert Enum.map(entries_after(before_count), & &1.description) == [
               "Wannes deleted line 'Balance' from invoice 'Venue deposit'"
             ]
    end

    test "broadcasts {:deleted, id} on :invoice_line", %{scope: scope, category: category} do
      invoice = invoice_fixture(scope, category)

      {:ok, second_line} =
        Invoices.create_line(scope, invoice, %{"label" => "Balance", "amount_input" => "500"})

      Realtime.subscribe(:invoice_line)
      {:ok, _} = Invoices.delete_line(scope, second_line)
      id = second_line.id
      assert_received {Realtime, :invoice_line, {:deleted, ^id}}
    end
  end

  # -- create_line/3, update_line/3 (XC-10) -----------------------------------------------

  describe "create_line/3, update_line/3 (XC-10)" do
    test "create_line/3 logs against the invoice", %{scope: scope, category: category} do
      invoice = invoice_fixture(scope, category)
      before_count = length(entries())

      {:ok, line} =
        Invoices.create_line(scope, invoice, %{"label" => "Balance", "amount_input" => "500"})

      assert [entry] = entries_after(before_count)
      assert entry.entity_type == "invoice"
      assert entry.entity_id == invoice.id

      assert entry.description ==
               "Wannes added line 'Balance' (€ 500,00) to invoice 'Venue deposit'"

      assert line.label == "Balance"
    end

    test "update_line/3 logs the amount change", %{scope: scope, category: category} do
      invoice = invoice_fixture(scope, category, %{}, %{"amount_input" => "3.000"})
      [line] = invoice.lines
      before_count = length(entries())

      {:ok, updated} = Invoices.update_line(scope, line, %{"amount_input" => "3.200"})
      assert Money.equal?(updated.amount, WeddingPlanner.Money.new(3200))

      assert Enum.map(entries_after(before_count), & &1.description) == [
               "Wannes changed the amount of line 'Deposit' in invoice 'Venue deposit': € 3.000,00 → € 3.200,00"
             ]
    end

    test "update_line/3 logs a label change", %{scope: scope, category: category} do
      invoice = invoice_fixture(scope, category)
      [line] = invoice.lines
      before_count = length(entries())

      {:ok, _} = Invoices.update_line(scope, line, %{"label" => "Final deposit"})

      assert Enum.map(entries_after(before_count), & &1.description) == [
               "Wannes changed the label of line 'Deposit' in invoice 'Venue deposit': Deposit → Final deposit"
             ]
    end
  end

  # -- mark_paid/3, mark_unpaid/2 (BIL-02, XC-10) -----------------------------------------

  describe "mark_paid/3, mark_unpaid/2 (BIL-02, XC-10)" do
    test "marks paid with the exact XC-10 wording", %{scope: scope, category: category} do
      invoice = invoice_fixture(scope, category, %{"label" => "Venue deposit"})
      before_count = length(entries())

      assert {:ok, paid} = Invoices.mark_paid(scope, invoice, ~D[2027-03-01])
      assert Invoice.paid?(paid)
      assert paid.paid_on == ~D[2027-03-01]

      assert Enum.map(entries_after(before_count), & &1.description) == [
               "Wannes marked invoice 'Venue deposit' as paid"
             ]
    end

    test "mark_unpaid/2 clears paid_on and logs", %{scope: scope, category: category} do
      invoice = invoice_fixture(scope, category)
      {:ok, paid} = Invoices.mark_paid(scope, invoice, ~D[2027-03-01])
      before_count = length(entries())

      assert {:ok, unpaid} = Invoices.mark_unpaid(scope, paid)
      refute Invoice.paid?(unpaid)
      assert is_nil(unpaid.paid_on)

      assert Enum.map(entries_after(before_count), & &1.description) == [
               "Wannes marked invoice 'Venue deposit' as unpaid"
             ]
    end

    test "changing the paid date on a paid invoice is an ordinary field update", %{
      scope: scope,
      category: category
    } do
      invoice = invoice_fixture(scope, category)
      {:ok, paid} = Invoices.mark_paid(scope, invoice, ~D[2027-03-01])
      before_count = length(entries())

      assert {:ok, updated} = Invoices.update_invoice(scope, paid, %{"paid_on" => ~D[2027-03-02]})
      assert updated.paid_on == ~D[2027-03-02]

      assert Enum.map(entries_after(before_count), & &1.description) == [
               "Wannes changed the paid date of invoice 'Venue deposit': 01/03/2027 → 02/03/2027"
             ]
    end
  end

  # -- linking to an offer (DR-58) --------------------------------------------------------

  describe "linking to an offer (DR-58)" do
    test "linking to a considering offer is refused", %{scope: scope, category: category} do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})
      invoice = invoice_fixture(scope, category)

      assert {:error, changeset} =
               Invoices.update_invoice(scope, invoice, %{"offer_id" => offer.id})

      assert errors_on(changeset).offer_id != []
      assert is_nil(Invoices.get_invoice!(invoice.id).offer_id)
    end

    test "linking to a confirmed offer of another category is refused", %{
      scope: scope,
      category: category
    } do
      {:ok, other_category} = Categories.create_category(scope, %{"name" => "Catering"})
      {:ok, offer} = Offers.create_offer(scope, other_category, %{"vendor_name" => "Traiteur"})
      offer = confirm_directly!(offer)
      invoice = invoice_fixture(scope, category)

      assert {:error, changeset} =
               Invoices.update_invoice(scope, invoice, %{"offer_id" => offer.id})

      assert errors_on(changeset).offer_id != []
      assert is_nil(Invoices.get_invoice!(invoice.id).offer_id)
    end

    test "linking to a confirmed offer of the same category is accepted and logged", %{
      scope: scope,
      category: category
    } do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})
      offer = confirm_directly!(offer)
      invoice = invoice_fixture(scope, category)
      before_count = length(entries())

      assert {:ok, updated} = Invoices.update_invoice(scope, invoice, %{"offer_id" => offer.id})
      assert updated.offer_id == offer.id

      assert Enum.map(entries_after(before_count), & &1.description) == [
               "Wannes changed the offer link of invoice 'Venue deposit': none → Kasteel Heers"
             ]
    end

    test "changing the category while linked is refused", %{scope: scope, category: category} do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})
      offer = confirm_directly!(offer)
      invoice = invoice_fixture(scope, category)
      {:ok, linked} = Invoices.update_invoice(scope, invoice, %{"offer_id" => offer.id})

      {:ok, other_category} = Categories.create_category(scope, %{"name" => "Catering"})

      assert {:error, changeset} =
               Invoices.update_invoice(scope, linked, %{"category_id" => other_category.id})

      assert errors_on(changeset).category_id != []
      assert Invoices.get_invoice!(linked.id).category_id == category.id
    end

    test "unlinking and re-categorising in the same write is fine", %{
      scope: scope,
      category: category
    } do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})
      offer = confirm_directly!(offer)
      invoice = invoice_fixture(scope, category)
      {:ok, linked} = Invoices.update_invoice(scope, invoice, %{"offer_id" => offer.id})

      {:ok, other_category} = Categories.create_category(scope, %{"name" => "Catering"})

      assert {:ok, updated} =
               Invoices.update_invoice(scope, linked, %{
                 "offer_id" => "",
                 "category_id" => other_category.id
               })

      assert is_nil(updated.offer_id)
      assert updated.category_id == other_category.id
    end
  end

  # -- set_invoicing_complete/3 (BIL-05, DR-58) -------------------------------------------

  describe "set_invoicing_complete/3 (BIL-05, DR-58)" do
    test "refused on a non-confirmed offer", %{scope: scope, category: category} do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})
      assert Invoices.set_invoicing_complete(scope, offer, true) == {:error, :not_confirmed}
      refute Offers.get_offer!(offer.id).invoicing_complete
    end

    test "accepted on a confirmed offer, logged against the offer, broadcasts :offer", %{
      scope: scope,
      category: category
    } do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})
      offer = confirm_directly!(offer)
      before_count = length(entries())
      Realtime.subscribe(:offer)

      assert {:ok, updated} = Invoices.set_invoicing_complete(scope, offer, true)
      assert updated.invoicing_complete

      assert Enum.map(entries_after(before_count), & &1.description) == [
               "Wannes marked invoicing complete for offer 'Kasteel Heers'"
             ]

      assert_received {Realtime, :offer, {:updated, ^updated}}

      before_count2 = length(entries())
      assert {:ok, reverted} = Invoices.set_invoicing_complete(scope, updated, false)
      refute reverted.invoicing_complete

      assert Enum.map(entries_after(before_count2), & &1.description) == [
               "Wannes marked invoicing not complete for offer 'Kasteel Heers'"
             ]
    end

    test "a raw SQL UPDATE on a non-confirmed offer is refused by the CHECK", %{
      scope: scope,
      category: category
    } do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})

      assert_raise Exqlite.Error, ~r/CHECK constraint failed/, fn ->
        Repo.update_all(from(o in Offer, where: o.id == ^offer.id),
          set: [invoicing_complete: true]
        )
      end
    end
  end

  # -- references (DR-28, XC-20-XC-24) ----------------------------------------------------

  describe "references on an invoice (DR-28, XC-20-XC-24)" do
    setup %{scope: scope, category: category} do
      invoice = invoice_fixture(scope, category)
      %{invoice: invoice, before: track_uploads_dir(), src: tmp_upload_dir!()}
    end

    test "attaches a URL reference: row has invoice_id, entry against the invoice", %{
      scope: scope,
      invoice: invoice
    } do
      owner = Invoices.reference_owner(invoice)
      before_count = length(entries())

      assert {:ok, reference} =
               References.create_url_reference(scope, owner, %{
                 "label" => "Contract",
                 "url" => "https://example.com/contract"
               })

      assert reference.invoice_id == invoice.id
      assert is_nil(reference.offer_id)

      assert [entry] = entries_after(before_count)
      assert entry.entity_type == "invoice"
      assert entry.entity_id == invoice.id
      assert entry.description == "Wannes added link 'Contract' to invoice 'Venue deposit'"
    end

    test "a raw insert with both owners is refused by the CHECK", %{
      scope: scope,
      category: category,
      invoice: invoice
    } do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Reference{
          kind: :url,
          label: "L",
          url: "https://example.com",
          offer_id: offer.id,
          invoice_id: invoice.id
        })
      end
    end

    test "a raw insert with neither owner is refused by the CHECK" do
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Reference{kind: :url, label: "L", url: "https://example.com"})
      end
    end

    test "deleting the invoice removes its references (entries) and purges files after commit",
         %{scope: scope, invoice: invoice, src: src} do
      owner = Invoices.reference_owner(invoice)

      {:ok, file_ref} =
        References.create_file_reference(
          scope,
          owner,
          %{"label" => "Quote"},
          write_fixture!(src, :pdf, "a.pdf")
        )

      before_count = length(entries())
      Realtime.subscribe(:reference)

      assert {:ok, _deleted} = Invoices.delete_invoice(scope, invoice)

      assert Repo.aggregate(Reference, :count) == 0
      refute Storage.exists?(file_ref)

      new_entries = entries_after(before_count)
      {[summary], children} = Enum.split_with(new_entries, &is_nil(&1.entity_type))

      assert summary.description == "Wannes deleted invoice 'Venue deposit'"

      assert Enum.any?(
               children,
               &(&1.description ==
                   "Wannes deleted line 'Deposit' from invoice 'Venue deposit' (invoice deleted)")
             )

      assert Enum.any?(
               children,
               &(&1.description ==
                   "Wannes removed reference 'Quote' (invoice 'Venue deposit' deleted)")
             )

      id = file_ref.id
      assert_received {Realtime, :reference, {:deleted, ^id}}
    end
  end

  describe "delete_invoice/2 — task link (DR-8/DR-69, task 78)" do
    setup %{scope: scope, category: category} do
      invoice = invoice_fixture(scope, category)
      %{invoice: invoice}
    end

    test "invoice_deletion_effects/1 has no task-link entry when nothing links to it", %{
      invoice: invoice
    } do
      assert Invoices.invoice_deletion_effects(invoice) == [%{label: "1 line", count: 1}]
    end

    test "invoice_deletion_effects/1 appends the task-link entry when tasks link to it", %{
      scope: scope,
      invoice: invoice
    } do
      for title <- ["Book florist", "Confirm menu"] do
        {:ok, _task} =
          Tasks.create_task(scope, %{"title" => title, "link_invoice_id" => invoice.id})
      end

      assert Invoices.invoice_deletion_effects(invoice) == [
               %{label: "1 line", count: 1},
               %{label: "2 tasks linked to this invoice (link removed)", count: 2}
             ]
    end

    test "a task linked to the invoice is never a deletion blocker (DR-26 Q11's precedent)", %{
      scope: scope,
      invoice: invoice
    } do
      {:ok, _task} =
        Tasks.create_task(scope, %{"title" => "Book florist", "link_invoice_id" => invoice.id})

      # `WeddingPlanner.Invoices` has no deletion-blocker concept at all — this just
      # confirms a task link doesn't invent one; the FK is `:restrict`, not refused.
      assert {:ok, _} = Invoices.delete_invoice(scope, invoice)
    end

    test "deleting the invoice clears every linked task's link, one child entry per task, and broadcasts :task {:updated, _}",
         %{scope: scope, invoice: invoice} do
      {:ok, task1} =
        Tasks.create_task(scope, %{"title" => "Book florist", "link_invoice_id" => invoice.id})

      {:ok, task2} =
        Tasks.create_task(scope, %{"title" => "Confirm menu", "link_invoice_id" => invoice.id})

      before_count = length(entries())
      Realtime.subscribe(:task)

      assert {:ok, _deleted} = Invoices.delete_invoice(scope, invoice)

      new_entries = entries_after(before_count)
      {[summary], children} = Enum.split_with(new_entries, &is_nil(&1.entity_type))
      assert summary.description == "Wannes deleted invoice 'Venue deposit'"

      task_children = Enum.filter(children, &(&1.entity_type == "task"))
      assert length(task_children) == 2
      assert Enum.all?(task_children, &(&1.parent_id == summary.id))

      assert Enum.sort(Enum.map(task_children, & &1.description)) ==
               Enum.sort([
                 "Wannes removed the link from 'Book florist' to invoice 'Venue deposit' (invoice deleted)",
                 "Wannes removed the link from 'Confirm menu' to invoice 'Venue deposit' (invoice deleted)"
               ])

      assert is_nil(Tasks.get_task!(task1.id).link_invoice_id)
      assert is_nil(Tasks.get_task!(task2.id).link_invoice_id)

      task1_id = task1.id
      task2_id = task2.id
      assert_received {Realtime, :task, {:updated, %{id: ^task1_id, link_invoice_id: nil}}}
      assert_received {Realtime, :task, {:updated, %{id: ^task2_id, link_invoice_id: nil}}}
    end

    test "a raw Repo.delete of the invoice before detaching its tasks raises (restrict FK) — fail-proof",
         %{scope: scope, invoice: invoice} do
      {:ok, _task} =
        Tasks.create_task(scope, %{"title" => "Book florist", "link_invoice_id" => invoice.id})

      assert_raise Ecto.ConstraintError, fn -> Repo.delete(invoice) end
    end
  end

  # -- blockers (DR-26 Q11, DR-58) ---------------------------------------------------------

  describe "blockers (DR-26 Q11, DR-58)" do
    test "a category with an invoice cannot be deleted", %{scope: scope, category: category} do
      invoice_fixture(scope, category)

      assert Categories.category_deletion_blockers(category) == [
               %{label: "1 invoice", count: 1}
             ]

      assert Categories.delete_category(scope, category) == {:error, :has_blockers}
    end

    test "an offer with a linked invoice cannot be deleted", %{scope: scope, category: category} do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})
      offer = confirm_directly!(offer)
      invoice = invoice_fixture(scope, category)
      {:ok, _} = Invoices.update_invoice(scope, invoice, %{"offer_id" => offer.id})

      assert Offers.offer_deletion_blockers(offer) == [%{label: "1 invoice", count: 1}]
      assert Offers.delete_offer(scope, offer) == {:error, :has_invoices}
      assert Offers.get_offer!(offer.id)
    end
  end

  # -- deletion effects, EntityRef, count_invoices ----------------------------------------

  describe "invoice_deletion_effects/1, EntityRef, counts" do
    test "counts lines and references", %{scope: scope, category: category} do
      invoice = invoice_fixture(scope, category)
      assert Invoices.invoice_deletion_effects(invoice) == [%{label: "1 line", count: 1}]
    end

    test "EntityRef 'invoice' resolver", %{scope: scope, category: category} do
      invoice = invoice_fixture(scope, category)

      assert {:link, "Venue deposit", "/invoices/" <> id} =
               EntityRef.resolve("invoice", invoice.id)

      assert id == to_string(invoice.id)

      {:ok, _} = Invoices.delete_invoice(scope, invoice)
      assert {:text, _} = EntityRef.resolve("invoice", invoice.id)
    end

    test "count_invoices/1", %{scope: scope, category: category} do
      assert Invoices.count_invoices(category) == 0
      invoice_fixture(scope, category)
      assert Invoices.count_invoices(category) == 1
    end
  end

  # -- Snapshot integration (B2) -----------------------------------------------------------

  describe "WeddingPlanner.Valuation.Snapshot integration (B2)" do
    test "invoices and lines load, id order", %{scope: scope, category: category} do
      invoice = invoice_fixture(scope, category)

      snapshot = WeddingPlanner.Valuation.Snapshot.load(Repo)
      assert Enum.map(snapshot.invoices, & &1.id) == [invoice.id]
      assert Enum.map(snapshot.invoice_lines, & &1.invoice_id) == [invoice.id]
    end
  end

  # -- list_invoices/0/1, list_invoices_by_offer/1, get_invoice! ---------------------------

  describe "list_invoices/0/1, list_invoices_by_offer/1, get_invoice!/1" do
    test "list_invoices/0 returns every invoice", %{scope: scope, category: category} do
      a = invoice_fixture(scope, category, %{"label" => "A"})
      b = invoice_fixture(scope, category, %{"label" => "B"})

      assert Enum.map(Invoices.list_invoices(), & &1.id) == [a.id, b.id]
    end

    test "list_invoices/1 scopes to a category", %{scope: scope, category: category} do
      {:ok, other} = Categories.create_category(scope, %{"name" => "Catering"})
      a = invoice_fixture(scope, category, %{"label" => "A"})
      invoice_fixture(scope, other, %{"label" => "B"})

      assert Enum.map(Invoices.list_invoices(category), & &1.id) == [a.id]
      assert Enum.map(Invoices.list_invoices(category.id), & &1.id) == [a.id]
    end

    test "list_invoices_by_offer/1 scopes to a linked offer", %{
      scope: scope,
      category: category
    } do
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})
      offer = confirm_directly!(offer)
      linked = invoice_fixture(scope, category, %{"label" => "Linked"})
      {:ok, linked} = Invoices.update_invoice(scope, linked, %{"offer_id" => offer.id})
      invoice_fixture(scope, category, %{"label" => "Unlinked"})

      assert Enum.map(Invoices.list_invoices_by_offer(offer), & &1.id) == [linked.id]
    end

    test "get_invoice!/1 preloads lines in id order", %{scope: scope, category: category} do
      invoice = invoice_fixture(scope, category)

      {:ok, _} =
        Invoices.create_line(scope, invoice, %{"label" => "Balance", "amount_input" => "500"})

      fetched = Invoices.get_invoice!(invoice.id)
      assert Enum.map(fetched.lines, & &1.label) == ["Deposit", "Balance"]
    end
  end
end
