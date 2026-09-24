defmodule WeddingPlannerWeb.Live.OfferLiveInvoicesTest do
  @moduledoc """
  Invoices, variance and invoicing complete on `/offers/:id` (task 70;
  `docs/modules/invoices-and-budget.md` `BIL-05`, `BIL-07`; `DR-58`). The section only
  ever shows for a **confirmed** offer — before C5 (W11) that never happens through the
  UI, so every test here confirms the offer directly at the database level
  (`Repo.update_all/2`), the same `DR-58` precedent
  `WeddingPlannerWeb.Live.InvoiceLiveTest`/`WeddingPlannerWeb.Live.InvoicesLiveTest` use.

  Real database rows throughout (`WeddingPlanner.NormativeGuests`,
  `WeddingPlanner.NormativeOfferRows`) → `WeddingPlanner.Valuation.Snapshot.load/1` →
  the production path, the same real-row construction
  `WeddingPlanner.Valuation.InvoicesTest`'s own "B1/B2 over real rows" describe block
  uses — B1 and B2 (`docs/07-normative-examples.md`) exercised end to end through the UI
  (named "B1 (UI)"/"B2 (UI)", tagged `:ui_example` — task 68 owns the `example:` tag).

  `async: false`: mutates stored offer status directly and reads stored preset roles.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Money
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeGuests
  alias WeddingPlanner.NormativeOfferRows, as: Rows
  alias WeddingPlanner.OfferFixtures
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Invoices, as: InvoiceValuation
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Format

  setup %{conn: conn} do
    scope = OfferFixtures.scope_fixture()
    dinner = Rows.dinner!(scope)
    NormativeGuests.shared_dinner!(scope, dinner)
    {category, services} = Rows.category!(scope, NE.venue_category())
    %{offer: offer} = Rows.offer!(scope, :venue_a, category, services, dinner)

    %{conn: log_in_user(conn, scope.user), scope: scope, category: category, offer: offer}
  end

  # -- helpers -------------------------------------------------------------------------------

  defp nbsp, do: <<0xA0::utf8>>
  defp eur(str), do: "€#{nbsp()}#{str}"

  # DR-58: no changeset writes :confirmed until C5 — confirm at the database level.
  defp confirm!(offer) do
    {1, _} =
      Repo.update_all(from(o in Offers.Offer, where: o.id == ^offer.id),
        set: [status: :confirmed]
      )

    Offers.get_offer!(offer.id)
  end

  defp deposit!(scope, category, offer) do
    {:ok, deposit} =
      Invoices.create_invoice(
        scope,
        category,
        %{label: "Deposit", invoice_date: ~D[2027-01-15], offer_id: offer.id},
        %{label: "Deposit", amount: Money.new(3000)}
      )

    {:ok, deposit} = Invoices.mark_paid(scope, deposit, ~D[2027-01-31])
    deposit
  end

  defp final_invoice!(scope, category, offer) do
    {:ok, final} =
      Invoices.create_invoice(
        scope,
        category,
        %{label: "Final invoice", invoice_date: ~D[2027-06-20], offer_id: offer.id},
        %{label: "Final invoice", amount: Money.new(8900)}
      )

    final
  end

  # -- non-confirmed offer (DR-58, fail-proof 2) ---------------------------------------------

  test "a non-confirmed offer shows no Invoices section at all", %{conn: conn, offer: offer} do
    {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

    refute has_element?(view, "#offer-invoices")
  end

  # -- B1 through the UI ----------------------------------------------------------------------

  describe "B1 (UI)" do
    setup %{scope: scope, category: category, offer: offer} do
      offer = confirm!(offer)
      deposit = deposit!(scope, category, offer)

      %{offer: offer, deposit: deposit}
    end

    @tag :ui_example
    test "invoiced/paid/outstanding figures and the variance under the default (Likely) preset",
         %{conn: conn, offer: offer, deposit: deposit} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      assert has_element?(view, "#offer-invoice-#{deposit.id}", "Deposit")

      assert has_element?(view, "#offer-invoice-figures", eur("3.000,00"))
      assert has_element?(view, "#offer-invoice-figures", eur("0,00"))

      assert has_element?(view, "#offer-variance", eur("8.726,00"))
      assert has_element?(view, "#offer-variance", "not yet invoiced")
      assert has_element?(view, "#offer-variance", "Likely")
      assert has_element?(view, "#offer-variance-formula")
    end
  end

  # -- B2 through the UI ----------------------------------------------------------------------

  describe "B2 (UI)" do
    setup %{scope: scope, category: category, offer: offer} do
      offer = confirm!(offer)
      _deposit = deposit!(scope, category, offer)
      _final = final_invoice!(scope, category, offer)
      {:ok, offer} = Invoices.set_invoicing_complete(scope, offer, true)

      %{offer: offer}
    end

    @tag :ui_example
    test "variance flips above committed once the final invoice lands, invoicing complete is set",
         %{conn: conn, offer: offer} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      assert has_element?(view, "#offer-variance", eur("174,00"))
      assert has_element?(view, "#offer-variance", "above committed")

      assert has_element?(view, "#offer-invoicing-complete", "Invoicing complete")
      assert has_element?(view, "#offer-history", "marked invoicing complete for offer")
    end
  end

  # -- the variance follows the Cost card's own preset chip (BIL-07, fail-proof 1) ------------

  describe "the variance follows the Cost card preset chip" do
    setup %{scope: scope, category: category, offer: offer} do
      offer = confirm!(offer)
      deposit = deposit!(scope, category, offer)

      %{offer: offer, deposit: deposit}
    end

    test "switching to Minimum recomputes the variance under Minimum, not a hard-coded preset",
         %{conn: conn, offer: offer} do
      snapshot = Snapshot.load(Repo)
      loaded = Enum.find(snapshot.offers, &(&1.id == offer.id))
      minimum = Enum.find(snapshot.headcount_presets, &(&1.role == :minimum))
      likely = Enum.find(snapshot.headcount_presets, &(&1.role == :likely))
      expected = InvoiceValuation.variance(snapshot, loaded, minimum)

      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      # Sanity: Minimum's committed total differs from Likely's, so a test that passed
      # under a hard-coded Likely preset would fail here.
      refute InvoiceValuation.variance(snapshot, loaded, likely).amount == expected.amount

      view
      |> element("#offer-cost-preset-form")
      |> render_change(%{"offer-cost-preset-preset" => to_string(minimum.id)})

      assert has_element?(view, "#offer-variance", Format.money(expected.amount))
      assert has_element?(view, "#offer-variance", "Minimum")
    end
  end

  # -- delete blocker (DR-58) ------------------------------------------------------------------

  describe "delete blocker (DR-58)" do
    setup %{scope: scope, category: category, offer: offer} do
      offer = confirm!(offer)
      invoice = deposit!(scope, category, offer)

      %{offer: offer, invoice: invoice}
    end

    test "opening delete shows the blocker naming 1 invoice, no confirm button", %{
      conn: conn,
      offer: offer
    } do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      view |> element("#offer-delete") |> render_click()

      assert has_element?(view, "#offer-delete-blocked", "1 invoice")
      refute has_element?(view, "#offer-delete-confirm")
    end
  end
end
