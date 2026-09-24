defmodule WeddingPlannerWeb.Live.InvoicesLiveTest do
  @moduledoc """
  `docs/modules/invoices-and-budget.md` `BIL-01`–`BIL-06`; `docs/04-cross-cutting.md`
  `XC-01`, `XC-10`; `DR-18`, `DR-23`, `DR-44`, `DR-58`, `DR-59` — the invoices list
  (task 69): overdue highlight and order, category/paid filters in the URL, the
  new-invoice form.
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import WeddingPlanner.OfferFixtures
  import WeddingPlanner.InvoiceFixtures

  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Money
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks.TodoList
  alias WeddingPlannerWeb.Format

  setup %{conn: conn} do
    scope = scope_fixture("Wannes")
    category = category_fixture(scope)

    %{conn: log_in_user(conn, scope.user), scope: scope, category: category}
  end

  defp today, do: TodoList.today(Format.default_time_zone())

  defp row_position(html, id) do
    {pos, _len} = :binary.match(html, "invoice-row-#{id}\"")
    pos
  end

  describe "nav" do
    test "Invoices appears after Categories", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices")

      html = render(view)
      categories_pos = :binary.match(html, "id=\"nav-categories\"") |> elem(0)
      invoices_pos = :binary.match(html, "id=\"nav-invoices\"") |> elem(0)
      assert categories_pos < invoices_pos
    end
  end

  describe "order and overdue highlight (BIL-06, DR-59)" do
    test "an unpaid invoice due yesterday is overdue and sorts first", %{
      conn: conn,
      scope: scope,
      category: category
    } do
      not_overdue =
        invoice_fixture(scope, category, %{"label" => "Not overdue yet", "due_date" => today()})

      overdue =
        invoice_fixture(scope, category, %{
          "label" => "Overdue one",
          "due_date" => Date.add(today(), -1)
        })

      {:ok, view, _html} = live(conn, ~p"/invoices")

      assert has_element?(view, "#invoice-row-#{overdue.id}-overdue")
      refute has_element?(view, "#invoice-row-#{not_overdue.id}-overdue")

      html = render(view)
      assert row_position(html, overdue.id) < row_position(html, not_overdue.id)
    end

    test "an invoice due today is not overdue", %{conn: conn, scope: scope, category: category} do
      invoice = invoice_fixture(scope, category, %{"due_date" => today()})

      {:ok, view, _html} = live(conn, ~p"/invoices")

      refute has_element?(view, "#invoice-row-#{invoice.id}-overdue")
      assert has_element?(view, "#invoice-row-#{invoice.id}-unpaid")
    end

    test "a paid invoice is listed under Paid (N), never overdue", %{
      conn: conn,
      scope: scope,
      category: category
    } do
      invoice = invoice_fixture(scope, category, %{"due_date" => Date.add(today(), -30)})
      {:ok, _} = Invoices.mark_paid(scope, invoice, today())

      {:ok, view, _html} = live(conn, ~p"/invoices")

      assert has_element?(view, "#invoices-paid", "Paid (1)")
      refute has_element?(view, "#invoice-row-#{invoice.id}-overdue")
      assert has_element?(view, "#invoice-row-#{invoice.id}-paid")
    end

    # Fail-proof 2: rendering the overdue marker as `invoice.overdue && "Overdue"`-style
    # boolean interpolation instead of `:if` leaves a literal "false" in a non-overdue
    # row. Edit `invoice_row/1` to do that, re-run, watch this fail, then restore.
    test "a non-overdue row never renders the literal word 'false'", %{
      conn: conn,
      scope: scope,
      category: category
    } do
      invoice = invoice_fixture(scope, category, %{"due_date" => today()})

      {:ok, view, _html} = live(conn, ~p"/invoices")

      refute has_element?(view, "#invoice-row-#{invoice.id}-overdue")
      row_html = view |> element("#invoice-row-#{invoice.id}") |> render()
      refute row_html =~ "false"
    end

    # Fail-proof 1 (NFR-22): using `Date.utc_today/0` instead of the viewer's today
    # would use the server's calendar date always. Self-adjusting so it never depends on
    # what time of day the suite happens to run: it compares `Date.utc_today/0` against
    # `TodoList.today/1` in two fixed-offset zones that together always cover the whole
    # UTC day, picks whichever actually differs right now, and asserts the direction
    # that difference implies. Edit `refresh/1` to use `Date.utc_today/0` for `today`,
    # re-run, watch it fail, then restore.
    test "overdue uses the viewer's today (@time_zone), not the server's Date.utc_today/0",
         %{conn: conn, scope: scope, category: category} do
      utc_today = Date.utc_today()

      {zone, viewer_today} =
        Enum.find_value(["Pacific/Kiritimati", "Etc/GMT+12"], fn zone ->
          viewer_today = TodoList.today(zone)
          if Date.compare(viewer_today, utc_today) != :eq, do: {zone, viewer_today}
        end)

      {due_date, expect_overdue?} =
        if Date.compare(viewer_today, utc_today) == :gt do
          {utc_today, true}
        else
          {viewer_today, false}
        end

      invoice = invoice_fixture(scope, category, %{"due_date" => due_date})

      {:ok, view, _html} = live(conn, ~p"/invoices")
      render_hook(view, "time_zone", %{"zone" => zone})

      # Trigger a normal refresh path so the now-updated @time_zone is actually used.
      view
      |> form("#invoices-filter-form", filter: %{"category_id" => "", "paid" => ""})
      |> render_change()

      if expect_overdue? do
        assert has_element?(view, "#invoice-row-#{invoice.id}-overdue")
      else
        refute has_element?(view, "#invoice-row-#{invoice.id}-overdue")
      end
    end
  end

  describe "filters (DR-44)" do
    test "category filter narrows the list and survives a reload", %{
      conn: conn,
      scope: scope,
      category: category
    } do
      other_category = category_fixture(scope, %{"name" => "Catering"})
      in_category = invoice_fixture(scope, category)
      other = invoice_fixture(scope, other_category)

      {:ok, view, _html} = live(conn, ~p"/invoices")

      view
      |> form("#invoices-filter-form",
        filter: %{"category_id" => to_string(category.id), "paid" => ""}
      )
      |> render_change()

      assert_patch(view, ~p"/invoices?filter_category=#{category.id}")
      assert has_element?(view, "#invoice-row-#{in_category.id}")
      refute has_element?(view, "#invoice-row-#{other.id}")

      {:ok, reloaded, _html} = live(conn, ~p"/invoices?filter_category=#{category.id}")
      assert has_element?(reloaded, "#invoice-row-#{in_category.id}")
      refute has_element?(reloaded, "#invoice-row-#{other.id}")
    end

    test "paid/unpaid filter narrows the list and survives a reload", %{
      conn: conn,
      scope: scope,
      category: category
    } do
      unpaid = invoice_fixture(scope, category)
      paid = invoice_fixture(scope, category, %{"label" => "Paid one"})
      {:ok, _} = Invoices.mark_paid(scope, paid, today())

      {:ok, view, _html} = live(conn, ~p"/invoices")

      view
      |> form("#invoices-filter-form", filter: %{"category_id" => "", "paid" => "unpaid"})
      |> render_change()

      assert_patch(view, ~p"/invoices?filter_paid=unpaid")
      assert has_element?(view, "#invoice-row-#{unpaid.id}")
      refute has_element?(view, "#invoice-row-#{paid.id}")

      {:ok, reloaded, _html} = live(conn, ~p"/invoices?filter_paid=unpaid")
      assert has_element?(reloaded, "#invoice-row-#{unpaid.id}")
      refute has_element?(reloaded, "#invoice-row-#{paid.id}")
    end
  end

  describe "new invoice (DR-58, DR-59, DR-23)" do
    test "submitting category, label, date and a first line creates the invoice", %{
      conn: conn,
      category: category
    } do
      {:ok, view, _html} = live(conn, ~p"/invoices")

      view |> element("#invoice-new-toggle") |> render_click()
      assert has_element?(view, "#invoice-new-form")

      {:ok, redirected, _html} =
        view
        |> form("#invoice-new-form",
          invoice: %{
            "category_id" => to_string(category.id),
            "label" => "Venue deposit",
            "invoice_date" => "2027-01-01"
          },
          line: %{"label" => "Deposit", "amount_input" => "3.000"}
        )
        |> render_submit()
        |> follow_redirect(conn)

      assert has_element?(redirected, "#invoice-total", Format.money(Money.new(3_000)))
    end

    test "an invalid amount (DR-23) shows the error and creates nothing", %{
      conn: conn,
      category: category
    } do
      {:ok, view, _html} = live(conn, ~p"/invoices")

      view |> element("#invoice-new-toggle") |> render_click()

      html =
        view
        |> form("#invoice-new-form",
          invoice: %{
            "category_id" => to_string(category.id),
            "label" => "Venue deposit",
            "invoice_date" => "2027-01-01"
          },
          line: %{"label" => "Deposit", "amount_input" => "3000.50"}
        )
        |> render_submit()

      assert html =~ "Use a comma for the decimal part"
      assert Invoices.list_invoices(category.id) == []
    end

    test "?category=<id> preselects the category and opens the form", %{
      conn: conn,
      category: category
    } do
      {:ok, view, _html} = live(conn, ~p"/invoices?category=#{category.id}")

      assert has_element?(view, "#invoice-new-form")

      assert has_element?(
               view,
               "#invoice-new-category option[value=\"#{category.id}\"][selected]"
             )
    end
  end

  describe "offer link (DR-58)" do
    test "the offer select is disabled with a hint when the category has no confirmed offer", %{
      conn: conn,
      scope: scope,
      category: category
    } do
      _offer = offer_fixture(scope, category)

      {:ok, view, _html} = live(conn, ~p"/invoices?category=#{category.id}")

      assert has_element?(view, "#invoice-new-offer[disabled]")
      assert has_element?(view, "#invoice-new-form", "Only confirmed offers can be linked")
    end

    test "linking works once an offer is confirmed", %{
      conn: conn,
      scope: scope,
      category: category
    } do
      offer = offer_fixture(scope, category)
      {1, _} = Repo.update_all(Offers.Offer, set: [status: :confirmed])

      {:ok, view, _html} = live(conn, ~p"/invoices?category=#{category.id}")

      refute has_element?(view, "#invoice-new-offer[disabled]")

      {:ok, redirected, _html} =
        view
        |> form("#invoice-new-form",
          invoice: %{
            "category_id" => to_string(category.id),
            "label" => "Venue deposit",
            "invoice_date" => "2027-01-01",
            "offer_id" => to_string(offer.id)
          },
          line: %{"label" => "Deposit", "amount_input" => "3.000"}
        )
        |> render_submit()
        |> follow_redirect(conn)

      assert has_element?(redirected, "#invoice-form-category[disabled]")
    end
  end
end
