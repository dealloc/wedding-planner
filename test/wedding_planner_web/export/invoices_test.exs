defmodule WeddingPlannerWeb.Export.InvoicesTest do
  @moduledoc """
  `WeddingPlannerWeb.Export.Invoices` (`BIL-02`, `BIL-06`, `DR-59`, `DR-88`) — pure,
  in-memory.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Invoices.InvoiceLine
  alias WeddingPlanner.Money
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Export.Invoices

  @today ~D[2026-09-25]

  test "headers, one row per line, ordered by invoice date then id" do
    venue = %Category{id: 1, name: "Venue"}

    later = %Invoice{
      id: 2,
      category_id: 1,
      offer_id: nil,
      label: "Balance",
      invoice_date: ~D[2027-02-01],
      due_date: nil,
      paid_on: nil
    }

    earlier = %Invoice{
      id: 1,
      category_id: 1,
      offer_id: nil,
      label: "Deposit",
      invoice_date: ~D[2027-01-01],
      due_date: nil,
      paid_on: nil
    }

    lines = [
      %InvoiceLine{id: 10, invoice_id: 2, label: "Balance line", amount: Money.new(500)},
      %InvoiceLine{id: 9, invoice_id: 1, label: "Deposit line", amount: Money.new(1_000)}
    ]

    snapshot = %Snapshot{
      categories: [venue],
      offers: [],
      invoices: [later, earlier],
      invoice_lines: lines
    }

    table = Invoices.table(snapshot, @today)

    assert table.stem == "invoices"

    assert table.headers == [
             "Category",
             "Invoice",
             "Invoice date",
             "Due date",
             "Paid on",
             "Paid",
             "Overdue",
             "Linked offer",
             "Line",
             "Amount",
             "Currency"
           ]

    assert [deposit_row, balance_row] = table.rows
    assert Enum.at(deposit_row, 1) == "Deposit"
    assert Enum.at(balance_row, 1) == "Balance"
  end

  test "Linked offer is the linked offer's vendor name, or blank" do
    venue = %Category{id: 1, name: "Venue"}
    offer = %Offer{id: 5, vendor_name: "Kasteel Heers"}

    linked =
      %Invoice{
        id: 1,
        category_id: 1,
        offer_id: 5,
        label: "Deposit",
        invoice_date: ~D[2027-01-01],
        due_date: nil,
        paid_on: nil
      }

    unlinked =
      %Invoice{
        id: 2,
        category_id: 1,
        offer_id: nil,
        label: "Flowers",
        invoice_date: ~D[2027-01-02],
        due_date: nil,
        paid_on: nil
      }

    lines = [
      %InvoiceLine{id: 1, invoice_id: 1, label: "Line", amount: Money.new(10)},
      %InvoiceLine{id: 2, invoice_id: 2, label: "Line", amount: Money.new(20)}
    ]

    snapshot = %Snapshot{
      categories: [venue],
      offers: [offer],
      invoices: [linked, unlinked],
      invoice_lines: lines
    }

    [linked_row, unlinked_row] = Invoices.table(snapshot, @today).rows
    assert Enum.at(linked_row, 7) == "Kasteel Heers"
    assert Enum.at(unlinked_row, 7) == nil
  end

  describe "FP-92f — Paid and Overdue" do
    defp invoice(attrs) do
      struct!(
        %Invoice{
          id: 1,
          category_id: 1,
          offer_id: nil,
          label: "Deposit",
          invoice_date: ~D[2027-01-01]
        },
        attrs
      )
    end

    defp table_for(invoice) do
      venue = %Category{id: 1, name: "Venue"}
      line = %InvoiceLine{id: 1, invoice_id: 1, label: "Line", amount: Money.new(10)}

      snapshot = %Snapshot{
        categories: [venue],
        offers: [],
        invoices: [invoice],
        invoice_lines: [line]
      }

      [row] = Invoices.table(snapshot, @today).rows
      row
    end

    test "an unpaid invoice due today is not overdue" do
      row = table_for(invoice(due_date: @today, paid_on: nil))
      assert Enum.at(row, 5) == false
      assert Enum.at(row, 6) == false
    end

    test "an unpaid invoice due yesterday is overdue" do
      row = table_for(invoice(due_date: Date.add(@today, -1), paid_on: nil))
      assert Enum.at(row, 5) == false
      assert Enum.at(row, 6) == true
    end

    test "a paid invoice, even overdue by date, is never overdue" do
      row = table_for(invoice(due_date: Date.add(@today, -1), paid_on: ~D[2027-01-05]))
      assert Enum.at(row, 5) == true
      assert Enum.at(row, 6) == false
    end
  end

  test "Currency is EUR on every row" do
    venue = %Category{id: 1, name: "Venue"}

    invoice = %Invoice{
      id: 1,
      category_id: 1,
      offer_id: nil,
      label: "Deposit",
      invoice_date: @today
    }

    line = %InvoiceLine{id: 1, invoice_id: 1, label: "Line", amount: Money.new(10)}

    snapshot = %Snapshot{
      categories: [venue],
      offers: [],
      invoices: [invoice],
      invoice_lines: [line]
    }

    [row] = Invoices.table(snapshot, @today).rows

    assert Enum.at(row, 10) == "EUR"
  end
end
