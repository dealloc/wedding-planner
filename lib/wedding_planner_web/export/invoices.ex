defmodule WeddingPlannerWeb.Export.Invoices do
  @moduledoc """
  The invoices export (`XC-30`, `BIL-02`, `BIL-06`, `DR-88`): one row per invoice
  **line**, for invoices ordered by invoice date then id — `BIL-02` guarantees every
  invoice has at least one line, so no invoice is ever dropped; lines are ordered by id
  within their invoice.

  Columns: `Category, Invoice, Invoice date, Due date, Paid on, Paid, Overdue, Linked
  offer, Line, Amount, Currency`.

    * `Paid` = `WeddingPlanner.Valuation.Invoices.paid?/1`; `Overdue` =
      `WeddingPlanner.Valuation.Invoices.overdue?/2` against the export's `today` (an
      invoice due **today** is not overdue yet, `DR-59`) — `BIL-06`.
    * `Linked offer` is the linked offer's vendor name, or blank when the invoice is not
      linked to one.
    * `Amount` is the line's own `%Money{}`; there is deliberately no repeated
      invoice-total column (a spreadsheet sums the `Amount` column itself).

  `Currency` is the one `Currency` column the export contract requires, last, taken from
  each row's own `Amount`.
  """

  @behaviour WeddingPlannerWeb.Export.Exporter

  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Invoices, as: InvoiceValuation
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Export.Table

  @impl true
  @spec load() :: Snapshot.t()
  def load, do: Snapshot.load(Repo)

  @impl true
  @spec table(Snapshot.t(), Date.t()) :: Table.t()
  def table(%Snapshot{} = snapshot, %Date{} = today) do
    categories_by_id = Map.new(snapshot.categories, &{&1.id, &1})
    offers_by_id = Map.new(snapshot.offers, &{&1.id, &1})
    lines_by_invoice = Enum.group_by(snapshot.invoice_lines, & &1.invoice_id)

    rows =
      snapshot.invoices
      |> Enum.sort_by(&{Date.to_erl(&1.invoice_date), &1.id})
      |> Enum.flat_map(&invoice_rows(&1, today, categories_by_id, offers_by_id, lines_by_invoice))

    %{
      stem: "invoices",
      headers: [
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
      ],
      rows: rows
    }
  end

  defp invoice_rows(invoice, today, categories_by_id, offers_by_id, lines_by_invoice) do
    category = Map.get(categories_by_id, invoice.category_id)
    offer = offer_of(invoice, offers_by_id)
    lines = lines_by_invoice |> Map.get(invoice.id, []) |> Enum.sort_by(& &1.id)

    paid? = InvoiceValuation.paid?(invoice)
    overdue? = InvoiceValuation.overdue?(invoice, today)

    Enum.map(lines, fn line ->
      [
        category && category.name,
        invoice.label,
        invoice.invoice_date,
        invoice.due_date,
        invoice.paid_on,
        paid?,
        overdue?,
        offer && offer.vendor_name,
        line.label,
        line.amount,
        currency_of(line.amount)
      ]
    end)
  end

  defp offer_of(%{offer_id: nil}, _offers_by_id), do: nil
  defp offer_of(%{offer_id: offer_id}, offers_by_id), do: Map.get(offers_by_id, offer_id)

  defp currency_of(%Money{currency: currency}), do: Atom.to_string(currency)
  defp currency_of(nil), do: nil
end
