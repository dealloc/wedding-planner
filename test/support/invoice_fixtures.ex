defmodule WeddingPlanner.InvoiceFixtures do
  @moduledoc """
  Test support for invoices (`docs/modules/invoices-and-budget.md` `BIL-01`, `BIL-02`;
  `DR-59`) — a scope, a category and a label are all a caller usually needs; every option
  can be overridden through `attrs`/`line_attrs`.
  """

  alias WeddingPlanner.Invoices

  @doc """
  A freshly inserted invoice in `category`, with one line ("Deposit", € 1.000,00 by
  default). `attrs` overrides the invoice's own fields, `line_attrs` the first line's.
  """
  def invoice_fixture(scope, category, attrs \\ %{}, line_attrs \\ %{}) do
    {:ok, invoice} =
      Invoices.create_invoice(
        scope,
        category,
        Map.merge(%{"label" => "Venue deposit", "invoice_date" => ~D[2027-01-01]}, attrs),
        Map.merge(%{"label" => "Deposit", "amount_input" => "1000"}, line_attrs)
      )

    invoice
  end
end
