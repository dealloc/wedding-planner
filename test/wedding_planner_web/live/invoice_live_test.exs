defmodule WeddingPlannerWeb.Live.InvoiceLiveTest do
  @moduledoc """
  `docs/modules/invoices-and-budget.md` `BIL-01`–`BIL-06`; `docs/04-cross-cutting.md`
  `XC-01`, `XC-10`, `XC-11`, `XC-20`–`XC-24`, `XC-40`; `DR-18`, `DR-23`, `DR-28`, `DR-58`,
  `DR-59` — an invoice's own page (task 69): header edit, paid toggle, lines, references,
  history, delete.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WeddingPlanner.OfferFixtures
  import WeddingPlanner.InvoiceFixtures

  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Money
  alias WeddingPlanner.References
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks.TodoList
  alias WeddingPlannerWeb.Format

  setup %{conn: conn} do
    scope = scope_fixture("Wannes")
    category = category_fixture(scope)
    invoice = invoice_fixture(scope, category)

    %{conn: log_in_user(conn, scope.user), scope: scope, category: category, invoice: invoice}
  end

  defp today, do: TodoList.today(Format.default_time_zone())

  describe "show" do
    test "shows the label, unpaid pill and a back link", %{conn: conn, invoice: invoice} do
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")

      assert has_element?(view, "#invoice-status-pill", "Unpaid")
      assert has_element?(view, "#invoice-back-to-invoices")
    end

    test "a non-existent invoice 404s" do
      user = %WeddingPlanner.Accounts.User{}

      user =
        user |> WeddingPlanner.Accounts.User.changeset(%{display_name: "Solo"}) |> Repo.insert!()

      conn = build_conn() |> log_in_user(user)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/invoices/999999")
      end
    end
  end

  describe "header form (BIL-01, BIL-02, XC-10)" do
    test "renaming the label is logged", %{conn: conn, invoice: invoice} do
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")

      view
      |> form("#invoice-form", invoice: %{"label" => "Venue final invoice"})
      |> render_submit()

      assert has_element?(view, "h1", "Venue final invoice")
      assert has_element?(view, "#invoice-history", "changed the label of invoice")
    end
  end

  describe "paid toggle (BIL-02, DR-59)" do
    test "marking paid then unpaid flips the pill and is logged", %{
      conn: conn,
      scope: scope,
      invoice: invoice
    } do
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")

      view |> element("#invoice-paid-toggle") |> render_click()
      assert has_element?(view, "#invoice-paid-form")

      view
      |> form("#invoice-paid-form", paid: %{"paid_on" => Date.to_iso8601(today())})
      |> render_submit()

      assert has_element?(view, "#invoice-status-pill", "Paid")
      assert has_element?(view, "#invoice-history", "marked invoice '#{invoice.label}' as paid")
      assert Invoices.get_invoice!(invoice.id) |> then(&(&1.paid_on != nil))

      view |> element("#invoice-paid-toggle") |> render_click()

      assert has_element?(view, "#invoice-status-pill", "Unpaid")
      assert has_element?(view, "#invoice-history", "marked invoice '#{invoice.label}' as unpaid")
      refute Invoices.get_invoice!(invoice.id).paid_on

      _ = scope
    end
  end

  describe "lines (BIL-02, BIL-03)" do
    test "adding a second line updates the total", %{conn: conn, invoice: invoice} do
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")

      assert has_element?(view, "#invoice-total", Format.money(Money.new(1_000)))

      view |> element("#invoice-add-line") |> render_click()

      view
      |> form("#invoice-line-form", line: %{"label" => "Extra fee", "amount_input" => "500"})
      |> render_submit()

      assert has_element?(view, "#invoice-total", Format.money(Money.new(1_500)))
    end

    test "deleting a non-last line removes it", %{conn: conn, scope: scope, invoice: invoice} do
      {:ok, second_line} =
        Invoices.create_line(scope, invoice, %{"label" => "Extra fee", "amount_input" => "500"})

      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")

      view
      |> element("#invoice-line-#{second_line.id}-delete")
      |> render_click()

      view
      |> element("#invoice-line-#{second_line.id}-delete-confirm-confirm")
      |> render_click()

      refute has_element?(view, "#invoice-line-#{second_line.id}")
      assert has_element?(view, "#invoice-total", Format.money(Money.new(1_000)))
    end

    test "the last remaining line has no delete control, and the context refuses deleting it", %{
      conn: conn,
      scope: scope,
      invoice: invoice
    } do
      [line] = Invoices.get_invoice!(invoice.id).lines

      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")

      refute has_element?(view, "#invoice-line-#{line.id}-delete")
      assert Invoices.delete_line(scope, line) == {:error, :last_line}
    end
  end

  describe "references (XC-20-XC-24, DR-28)" do
    test "a URL reference is accepted and attached to the invoice", %{
      conn: conn,
      invoice: invoice
    } do
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")

      view
      |> form("#invoice-references-url-form",
        url: %{"label" => "Contract", "url" => "https://example.com"}
      )
      |> render_submit()

      assert has_element?(view, "#invoice-references-list", "Contract")

      [reference] = References.list_references(Invoices.reference_owner(invoice))
      assert reference.invoice_id == invoice.id
    end
  end

  describe "delete (XC-24, XC-40)" do
    test "deleting with confirmation navigates back to /invoices and removes it", %{
      conn: conn,
      invoice: invoice
    } do
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")

      view |> element("#invoice-delete") |> render_click()
      assert has_element?(view, "#invoice-delete-confirm")

      {:ok, redirected, _html} =
        view
        |> element("#invoice-delete-confirm-confirm")
        |> render_click()
        |> follow_redirect(conn, ~p"/invoices")

      refute has_element?(redirected, "#invoice-row-#{invoice.id}")
      assert_raise Ecto.NoResultsError, fn -> Invoices.get_invoice!(invoice.id) end
    end

    test "another process deleting the invoice navigates the viewer to /invoices", %{
      conn: conn,
      scope: scope,
      invoice: invoice
    } do
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")

      {:ok, _} = Invoices.delete_invoice(scope, invoice)

      assert_redirect(view, ~p"/invoices")
    end
  end

  describe "offer link (DR-58)" do
    test "the offer select is disabled with a hint when the category has no confirmed offer", %{
      conn: conn,
      scope: scope,
      category: category,
      invoice: invoice
    } do
      _offer = offer_fixture(scope, category)

      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")

      assert has_element?(view, "#invoice-form-offer[disabled]")
      assert has_element?(view, "#invoice-form", "Only confirmed offers can be linked")
    end

    test "linking works once an offer is confirmed, and the category select becomes disabled", %{
      conn: conn,
      scope: scope,
      category: category,
      invoice: invoice
    } do
      offer = offer_fixture(scope, category)
      offer = confirm_directly!(offer)

      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")
      refute has_element?(view, "#invoice-form-offer[disabled]")

      view
      |> form("#invoice-form", invoice: %{"offer_id" => to_string(offer.id)})
      |> render_submit()

      assert Invoices.get_invoice!(invoice.id).offer_id == offer.id
      assert has_element?(view, "#invoice-form-category[disabled]")
    end
  end

  # Fail-proof: putting `#invoice-paid-form` *inside* `#invoice-form` (nested forms)
  # instead of a sibling would make the paid toggle dead in a real browser (a nested
  # `<form>` is invalid HTML and the browser drops it) — LiveViewTest alone would not
  # catch this (see the task's UI-traps note); the real-browser CDP check confirms the
  # two are independent siblings.
  test "the paid form and the header form are independent siblings (never nested)", %{
    conn: conn,
    invoice: invoice
  } do
    {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")

    view |> element("#invoice-paid-toggle") |> render_click()
    assert has_element?(view, "#invoice-paid-form")

    header_form_html = view |> element("#invoice-form") |> render()
    refute header_form_html =~ "invoice-paid-form"
  end
end
