defmodule WeddingPlanner.Valuation.BudgetDbTest do
  @moduledoc """
  `WeddingPlanner.Valuation.Budget` over **real rows**: B1 and B2 entered through the
  contexts (`NormativeOfferRows`, `NormativeGuests`, `OfferFixtures.confirm_directly!/1`,
  `WeddingPlanner.Invoices`), plus a category with a real planning pick
  (`Offers.set_planning_pick/2`), loaded with `Snapshot.load/1` — the same figures as the
  in-memory tests. Not `example:`-tagged: the pure tests in
  `WeddingPlanner.Valuation.BudgetTest` carry the tags (`OfferDbTest` precedent).
  """
  use WeddingPlanner.DataCase, async: true

  import WeddingPlanner.OfferFixtures, only: [scope_fixture: 0, confirm_directly!: 1]

  alias WeddingPlanner.Categories
  alias WeddingPlanner.Invoices, as: InvoicesContext
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeGuests
  alias WeddingPlanner.NormativeOfferRows, as: Rows
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Valuation.Budget
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Snapshot

  @moduletag :real_path

  defp eur(amount), do: WeddingPlanner.Money.new(amount)

  defp assert_money(actual, expected, what) do
    assert Money.equal?(actual, expected),
           "#{what}: expected #{Money.to_string!(expected)}, got #{Money.to_string!(actual)}"
  end

  defp money(%Formula{total: {:money, %Money{} = money}}), do: money

  defp budget_now do
    snapshot = Snapshot.load(Repo)
    likely = Enum.find(snapshot.headcount_presets, &(&1.role == :likely))
    overall = Budget.overall(snapshot, likely)
    Map.new(overall.categories, &{&1.category.name, &1})
  end

  test "B1 then B2, and a real planning pick: the same layers through storage and the loader" do
    scope = scope_fixture()
    dinner = Rows.dinner!(scope)
    {venue, services} = Rows.category!(scope, NE.venue_category())
    %{offer: offer} = Rows.offer!(scope, :venue_a, venue, services, dinner)
    _guests = NormativeGuests.shared_dinner!(scope, dinner)

    # A category with a target and a real planning pick whose total replaces it (CST-44).
    {:ok, flowers} =
      Categories.create_category(scope, %{"name" => "Flowers", "target_input" => "1000"})

    {:ok, florist} = Offers.create_offer(scope, flowers, %{"vendor_name" => "Florist F"})

    {:ok, _line} =
      Offers.create_line(scope, florist, %{
        "label" => "Arch",
        "state" => "mandatory",
        "basis" => "flat",
        "amount" => eur(500)
      })

    {:ok, _pick} = Offers.set_planning_pick(scope, florist)

    # CST-40, DR-61: confirmed with its frozen selection.
    offer = confirm_directly!(offer)
    [deposit_given] = NE.given("B1").invoices

    {:ok, deposit} =
      InvoicesContext.create_invoice(
        scope,
        venue,
        %{label: deposit_given.label, invoice_date: ~D[2027-01-15], offer_id: offer.id},
        %{label: deposit_given.label, amount: deposit_given.amount}
      )

    {:ok, _deposit} = InvoicesContext.mark_paid(scope, deposit, ~D[2027-01-31])

    b1 = NE.expected("B1")
    %{"Venue" => venue_layers, "Flowers" => flowers_layers} = budget_now()

    assert venue_layers.branch == :confirmed
    assert [%{source: :committed}] = venue_layers.confirmed_offers
    assert_money(money(venue_layers.forecast), b1.forecast, "B1 forecast")
    assert_money(money(venue_layers.committed), NE.given("B1").committed, "B1 committed")
    assert_money(venue_layers.invoiced, b1.invoiced, "B1 invoiced")
    assert_money(venue_layers.paid, b1.paid, "B1 paid")
    assert_money(venue_layers.outstanding, b1.outstanding, "B1 outstanding")

    assert flowers_layers.branch == :planning_pick
    assert flowers_layers.fallback_winner == :base
    assert flowers_layers.planning_pick.offer.id == florist.id
    assert_money(flowers_layers.target, eur(1_000), "Flowers target")
    assert_money(money(flowers_layers.forecast), eur(500), "Flowers forecast = the pick")

    final_given = Enum.find(NE.given("B2").invoices, &(&1.label == "Final invoice"))

    {:ok, _final} =
      InvoicesContext.create_invoice(
        scope,
        venue,
        %{label: final_given.label, invoice_date: ~D[2027-06-20], offer_id: offer.id},
        %{label: final_given.label, amount: final_given.amount}
      )

    {:ok, _offer} = InvoicesContext.set_invoicing_complete(scope, offer, true)

    %{"Venue" => venue_layers} = budget_now()

    assert [%{source: :invoicing_complete}] = venue_layers.confirmed_offers
    assert_money(money(venue_layers.forecast), NE.expected("B2").forecast, "B2 forecast")
    assert_money(venue_layers.invoiced, NE.expected("B2").forecast, "B2 invoiced")
    assert_money(venue_layers.paid, b1.paid, "B2 paid (final invoice unpaid)")
    assert_money(venue_layers.outstanding, final_given.amount, "B2 outstanding")
  end
end
