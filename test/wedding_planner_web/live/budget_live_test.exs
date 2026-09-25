defmodule WeddingPlannerWeb.Live.BudgetLiveTest do
  @moduledoc """
  `/budget` (task 82; `docs/modules/invoices-and-budget.md` `BUD-01`, `BUD-02`, `BUD-04`,
  `BUD-05`, `BUD-07`, `BUD-08`, `BIL-06`; `docs/modules/headcount.md` `HC-10`; `DR-71`,
  `DR-72`, `DR-76`): tiles, the overall budget edited in place, the overdue banner,
  category cards, the preset selector and the role-value buttons' one-interaction
  disclosure. Real database rows throughout (`WeddingPlanner.NormativeGuests`,
  `WeddingPlanner.NormativeOfferRows`) so a headcount-dependent figure genuinely varies
  with the preset — the production path, no `headcount:` test seam.

  `async: false`: several tests read stored `WeddingPlanner.Presets.HeadcountPreset` rows
  by name (`preset_named/1`), the same reason `WeddingPlannerWeb.Live.OfferLiveCostTest`
  is `async: false`.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WeddingPlanner.InvoiceFixtures
  import WeddingPlanner.OfferFixtures

  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeGuests
  alias WeddingPlanner.NormativeOfferRows, as: Rows
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Presets.HeadcountPreset
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Settings
  alias WeddingPlanner.Tasks.TodoList
  alias WeddingPlannerWeb.Format

  setup %{conn: conn} do
    scope = scope_fixture()
    %{conn: log_in_user(conn, scope.user), scope: scope}
  end

  # -- helpers ---------------------------------------------------------------------------

  defp today, do: TodoList.today(Format.default_time_zone())
  defp preset_named(name), do: Repo.get_by!(HeadcountPreset, name: name)

  # Venue A on the shared Dinner guests (the `OfferLiveCostTest` precedent): a real,
  # confirmed, per-attendee-dependent offer, so its Committed/Forecast genuinely differ
  # across the three role presets.
  defp confirmed_venue_a(scope) do
    dinner = Rows.dinner!(scope)
    guests = NormativeGuests.shared_dinner!(scope, dinner)
    {venue, services} = Rows.category!(scope, NE.venue_category())
    %{offer: offer} = Rows.offer!(scope, :venue_a, venue, services, dinner)
    {:ok, confirmed} = Offers.confirm_offer(scope, offer)
    %{category: venue, offer: confirmed, dinner: dinner, guests: guests}
  end

  # A simple flat, headcount-independent confirmed offer (Studio Licht, the `DR-76` dev
  # seed's own precedent) for the tiles/invoice-focused tests.
  defp confirmed_photography(scope) do
    {:ok, category} = WeddingPlanner.Categories.create_category(scope, %{"name" => "Photography"})

    {:ok, offer} =
      Offers.create_simple_offer(scope, category, %{
        "vendor_name" => "Studio Licht",
        "amount_input" => "1.000"
      })

    {:ok, confirmed} = Offers.confirm_offer(scope, offer)
    %{category: category, offer: confirmed}
  end

  # -- page (BUD-02, BUD-05, BUD-07) ------------------------------------------------------

  describe "page" do
    test "renders tiles, one category card per category incl. an empty one, and the nav entry", %{
      conn: conn,
      scope: scope
    } do
      %{category: venue} = confirmed_venue_a(scope)
      %{category: photography} = confirmed_photography(scope)
      flowers = category_fixture(scope, %{"name" => "Flowers"})

      {:ok, view, _html} = live(conn, ~p"/budget")

      assert has_element?(view, "#budget-tiles")
      assert has_element?(view, "#tile-available")
      assert has_element?(view, "#tile-forecast")
      assert has_element?(view, "#tile-spent")
      assert has_element?(view, "#tile-outstanding")
      assert has_element?(view, "#budget-categories")
      assert has_element?(view, "#budget-category-#{venue.id}")
      assert has_element?(view, "#budget-category-#{photography.id}")
      assert has_element?(view, "#budget-category-#{flowers.id}")
      assert has_element?(view, "#budget-category-#{flowers.id}-badge", "Nothing yet")
      assert has_element?(view, "#nav-primary #nav-budget")
    end
  end

  # -- the collapsed card's summary forecast (orchestrator review, 2026-09-25) -----------

  describe "the collapsed card's summary forecast" do
    test "shows a low–high range for a headcount-dependent category and one value for a flat one",
         %{conn: conn, scope: scope} do
      %{category: venue} = confirmed_venue_a(scope)
      %{category: photography} = confirmed_photography(scope)

      {:ok, view, _html} = live(conn, ~p"/budget")

      venue_summary =
        view |> element("#budget-category-#{venue.id}-summary-forecast") |> render()

      assert venue_summary =~ "Forecast"
      assert venue_summary =~ "–"

      photography_summary =
        view |> element("#budget-category-#{photography.id}-summary-forecast") |> render()

      assert photography_summary =~ "Forecast #{Format.money(WeddingPlanner.Money.new(1_000))}"
      refute photography_summary =~ "–"
    end
  end

  # -- overall budget in place (BUD-01, DR-72, DR-23, XC-10, FP-82c) ----------------------

  describe "overall budget in place" do
    test "editing to 40.000 updates the Available tile and persists, with an activity entry (FP-82c)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/budget")
      before_tile = view |> element("#tile-available") |> render()

      view
      |> form("#overall-budget-form", settings: %{overall_budget_input: "40.000"})
      |> render_submit()

      after_tile = view |> element("#tile-available") |> render()
      refute before_tile == after_tile

      assert Settings.get().overall_budget == WeddingPlanner.Money.new(Decimal.new("40000"))

      entries = Query.for_entity(:settings, Settings.get().id)
      assert Enum.any?(entries, &(&1.description =~ "40.000"))
    end

    test "an invalid amount shows the DR-23 comma-decimal error and changes nothing", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/budget")

      html =
        view
        |> form("#overall-budget-form", settings: %{overall_budget_input: "1500.50"})
        |> render_submit()

      assert html =~ "Use a comma for the decimal part"
      assert Settings.get().overall_budget == nil
    end
  end

  # -- preset selector vs. role values (HC-10, DR-71, FP-82a) -----------------------------

  describe "the preset selector" do
    test "changes a category's forecast-formula preset step but never the tile's three values", %{
      conn: conn,
      scope: scope
    } do
      %{category: venue} = confirmed_venue_a(scope)
      minimum = preset_named("Minimum")

      {:ok, view, _html} = live(conn, ~p"/budget")
      before_tile = view |> element("#tile-forecast-values") |> render()

      view
      |> element("#budget-preset-form")
      |> render_change(%{"budget-preset-selector-preset" => to_string(minimum.id)})

      after_tile = view |> element("#tile-forecast-values") |> render()
      assert before_tile == after_tile

      assert has_element?(
               view,
               "#budget-category-#{venue.id}-forecast-formula-step-0",
               "Minimum"
             )
    end
  end

  describe "a role-value button" do
    test "selects that preset and opens its formula in one click (DR-71)", %{
      conn: conn,
      scope: scope
    } do
      %{category: _venue} = confirmed_venue_a(scope)
      minimum = preset_named("Minimum")

      {:ok, view, _html} = live(conn, ~p"/budget")

      view |> element("#tile-forecast-values-minimum") |> render_click()

      assert has_element?(view, "#budget-overall-forecast-formula-step-0", "Minimum")
      assert has_element?(view, "#budget-preset-selector-option-#{minimum.id}[checked]")
    end
  end

  # -- live updates (XC-01, FP-82b) --------------------------------------------------------

  describe "live updates" do
    test "marking an invoice paid updates #tile-spent without a reload (FP-82b)", %{
      conn: conn,
      scope: scope
    } do
      %{category: photography, offer: offer} = confirmed_photography(scope)

      invoice =
        invoice_fixture(
          scope,
          photography,
          %{"label" => "Studio invoice", "offer_id" => offer.id},
          %{"amount_input" => "1.000"}
        )

      {:ok, view, _html} = live(conn, ~p"/budget")
      before_spent = view |> element("#tile-spent") |> render()

      {:ok, _paid} = Invoices.mark_paid(scope, invoice, today())

      after_spent = view |> element("#tile-spent") |> render()
      refute before_spent == after_spent
    end

    test "changing an invitation status updates a confirmed offer's per-person committed values" do
      scope = scope_fixture()
      %{category: venue, dinner: dinner, guests: guests} = confirmed_venue_a(scope)
      [certain_adult | _] = guests.certain_adults

      conn = log_in_user(Phoenix.ConnTest.build_conn(), scope.user)
      {:ok, view, _html} = live(conn, ~p"/budget")

      before_html = view |> element("#budget-category-#{venue.id}-committed-tile") |> render()

      {:ok, _} = Invitations.set_invitation_status(scope, certain_adult, dinner, :declined)

      after_html = view |> element("#budget-category-#{venue.id}-committed-tile") |> render()
      refute before_html == after_html
    end
  end

  # -- overdue banner (BIL-06, DR-59, FP-82d) ---------------------------------------------

  describe "the overdue banner" do
    test "appears live for an overdue unpaid invoice, and disappears once paid", %{
      conn: conn,
      scope: scope
    } do
      category = category_fixture(scope, %{"name" => "Attire"})

      {:ok, view, _html} = live(conn, ~p"/budget")
      refute has_element?(view, "#budget-overdue")

      due_today =
        invoice_fixture(scope, category, %{"label" => "Due today", "due_date" => today()})

      # Due today is not overdue yet (FP-82d).
      refute has_element?(view, "#budget-overdue")
      refute has_element?(view, "#budget-overdue-#{due_today.id}")

      invoice =
        invoice_fixture(scope, category, %{
          "label" => "Tailor invoice",
          "due_date" => Date.add(today(), -1)
        })

      assert has_element?(view, "#budget-overdue")
      assert has_element?(view, "#budget-overdue-#{invoice.id}")
      refute has_element?(view, "#budget-overdue-#{due_today.id}")

      {:ok, _} = Invoices.mark_paid(scope, invoice, today())

      refute has_element?(view, "#budget-overdue-#{invoice.id}")
      refute has_element?(view, "#budget-overdue")
    end
  end

  # -- no leaked boolean text (a known trap, design record §7) ----------------------------

  describe "no leaked boolean text" do
    test "the page never renders a bare 'false' text node", %{conn: conn, scope: scope} do
      confirmed_venue_a(scope)
      confirmed_photography(scope)
      category_fixture(scope, %{"name" => "Flowers"})

      attire = category_fixture(scope, %{"name" => "Attire"})
      invoice_fixture(scope, attire, %{"due_date" => Date.add(today(), -1)})

      {:ok, view, _html} = live(conn, ~p"/budget")

      refute render(view) =~ ">false<"
    end
  end
end
