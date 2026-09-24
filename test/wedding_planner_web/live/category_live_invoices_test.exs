defmodule WeddingPlannerWeb.Live.CategoryLiveInvoicesTest do
  @moduledoc """
  The category page's Invoices section (task 70; `docs/modules/invoices-and-budget.md`
  `BIL-06`): every invoice in the category, each row's figures read off a freshly loaded
  `WeddingPlanner.Valuation.Snapshot` (never re-derived), overdue ones highlighted, kept
  live, "+ Add invoice" linking to `/invoices?category=<id>` (task 69's prefill).
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WeddingPlanner.InvoiceFixtures
  import WeddingPlanner.OfferFixtures

  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Tasks.TodoList
  alias WeddingPlannerWeb.Format

  setup %{conn: conn} do
    scope = scope_fixture()
    category = category_fixture(scope)

    %{conn: log_in_user(conn, scope.user), scope: scope, category: category}
  end

  # -- helpers -------------------------------------------------------------------------------

  defp nbsp, do: <<0xA0::utf8>>
  defp eur(str), do: "€#{nbsp()}#{str}"
  defp today, do: TodoList.today(Format.default_time_zone())
  defp yesterday, do: Date.add(today(), -1)

  defp attr_of(html, selector, name) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  # -- listing (BIL-06) ------------------------------------------------------------------

  test "empty state when the category has no invoices", %{conn: conn, category: category} do
    {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

    assert has_element?(view, "#category-invoices-empty")
  end

  test "lists an invoice with its total, linking to its own page", %{
    conn: conn,
    scope: scope,
    category: category
  } do
    invoice = invoice_fixture(scope, category, %{"label" => "Venue deposit"})

    {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

    assert has_element?(view, "#category-invoice-#{invoice.id}", "Venue deposit")
    assert has_element?(view, "#category-invoice-#{invoice.id}", eur("1.000,00"))

    assert attr_of(render(view), "#category-invoice-#{invoice.id}-link", "href") ==
             ["/invoices/#{invoice.id}"]
  end

  # -- overdue highlight, live (BIL-06, XC-01) --------------------------------------------

  test "an unpaid invoice due yesterday is overdue; marking it paid clears the marker live", %{
    conn: conn,
    scope: scope,
    category: category
  } do
    invoice = invoice_fixture(scope, category, %{"due_date" => yesterday()})

    {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

    assert has_element?(view, "#category-invoice-#{invoice.id}-overdue")
    refute has_element?(view, "#category-invoice-#{invoice.id}-paid")

    {:ok, _} = Invoices.mark_paid(scope, invoice, today())

    refute has_element?(view, "#category-invoice-#{invoice.id}-overdue")
    assert has_element?(view, "#category-invoice-#{invoice.id}-paid")
  end

  test "an invoice with no due date is neither overdue nor paid", %{
    conn: conn,
    scope: scope,
    category: category
  } do
    invoice = invoice_fixture(scope, category)

    {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

    refute has_element?(view, "#category-invoice-#{invoice.id}-overdue")
    assert has_element?(view, "#category-invoice-#{invoice.id}-unpaid")
  end

  # -- add invoice link (task 69's prefill) -----------------------------------------------

  test "Add invoice links to the prefilled form", %{conn: conn, category: category} do
    {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

    assert attr_of(render(view), "#category-add-invoice", "href") ==
             ["/invoices?category=#{category.id}"]
  end
end
