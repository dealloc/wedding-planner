defmodule WeddingPlanner.Valuation.BudgetTest do
  @moduledoc """
  `WeddingPlanner.Valuation.Budget` — `BUD-02`'s layers with `BUD-03`'s forecast in every
  branch, the `BUD-05` overall figures, `BUD-04`'s role-preset evaluations and every
  formula's steps (`BUD-08`; `DR-70`, `DR-71`, `DR-72`) — over in-memory snapshots
  (`WeddingPlanner.BudgetSnapshots`), through the real headcount, offer and invoice
  engines.

  * `@tag example: "B1" | "B2" | "B3"` — the forecast halves of B1 and B2 and all of B3,
    with no `headcount:` seam (B1/B2's offer-level and variance halves are tagged in
    `WeddingPlanner.Valuation.InvoicesTest`).
  * Only the "seam pass-through" test passes `headcount:`, and says so.

  The property test compares the engine with an oracle written here in exact integer
  cents (NFR-12 governs production arithmetic, not test oracles — `DR-50`), which shares
  no code with it: it sums the generator's own integer amounts.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.BudgetSnapshots
  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Invoices.InvoiceLine
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeInvoices
  alias WeddingPlanner.Offers.FrozenService
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Settings
  alias WeddingPlanner.Valuation.Budget
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Formula.Step
  alias WeddingPlanner.Valuation.Offer, as: OfferEngine
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Snapshot

  # -- helpers -------------------------------------------------------------------------------

  defp eur(amount), do: WeddingPlanner.Money.new(amount)

  defp assert_money(actual, expected, what) do
    assert Money.equal?(actual, expected),
           "#{what}: expected #{Money.to_string!(expected)}, got #{Money.to_string!(actual)}"
  end

  defp money(%Formula{total: {:money, %Money{} = money}}), do: money

  defp likely, do: NormativeInvoices.preset("Likely")
  defp minimum, do: NormativeInvoices.preset("Minimum")

  defp layers(categories, name), do: Enum.find(categories, &(&1.category.name == name))

  defp layers_of(snapshot, name, preset \\ likely()),
    do: snapshot |> Budget.forecast(preset) |> layers(name)

  # Steps with every %Money{} replaced by its normalised amount, so `€ 11726` and
  # `€ 11726.00` compare equal and a failure prints readable amounts.
  defp norm(%Money{amount: amount}),
    do: {:eur, amount |> Decimal.normalize() |> Decimal.to_string(:normal)}

  defp norm(%Step{label: label, value: value}), do: {norm(label), norm(value)}
  defp norm(list) when is_list(list), do: Enum.map(list, &norm/1)
  defp norm(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> norm() |> List.to_tuple()
  defp norm(other), do: other

  defp e(amount), do: norm(eur(amount))

  defp put_invoice(snapshot, id, category_id, offer_id, label, amount, attrs \\ []) do
    invoice =
      struct!(
        %Invoice{
          id: id,
          category_id: category_id,
          offer_id: offer_id,
          label: label,
          invoice_date: ~D[2027-01-10]
        },
        attrs
      )

    line = %InvoiceLine{id: id * 100, invoice_id: id, label: label, amount: amount}
    Snapshot.apply(snapshot, [{:put, :invoices, invoice}, {:put, :invoice_lines, line}])
  end

  defp put_offer(snapshot, %Offer{} = offer), do: Snapshot.apply(snapshot, {:put, :offers, offer})

  # -- normative examples ----------------------------------------------------------------------

  describe "normative examples B1, B2, B3 (forecast halves; real engines, no seam)" do
    @tag example: "B1"
    test "B1: confirmed Venue A, paid deposit, invoicing not complete → forecast = committed" do
      %{snapshot: snapshot} = BudgetSnapshots.b1()
      b1 = NE.expected("B1")
      venue = layers_of(snapshot, b1.category, NormativeInvoices.preset(b1.preset))

      assert venue.branch == :confirmed
      assert_money(money(venue.forecast), b1.forecast, "B1 forecast")
      assert_money(money(venue.committed), NE.given("B1").committed, "B1 committed")
      assert_money(venue.invoiced, b1.invoiced, "B1 invoiced")
      assert_money(venue.paid, b1.paid, "B1 paid")
      assert_money(venue.outstanding, b1.outstanding, "B1 outstanding")
      assert [%{source: :committed} = offer] = venue.confirmed_offers
      assert_money(offer.forecast, b1.forecast, "B1 Venue A forecast")
    end

    @tag example: "B2"
    test "B2: B1 plus the final invoice, invoicing complete → forecast = invoiced €11,900" do
      %{snapshot: snapshot} = BudgetSnapshots.b2()
      b2 = NE.expected("B2")
      invoiced = NE.given("B2").invoices |> Enum.map(& &1.amount) |> WeddingPlanner.Money.sum()
      venue = layers_of(snapshot, b2.category, NormativeInvoices.preset(b2.preset))

      assert venue.branch == :confirmed
      assert_money(money(venue.forecast), b2.forecast, "B2 forecast")
      assert_money(venue.invoiced, invoiced, "B2 invoiced")
      assert_money(venue.invoiced, b2.forecast, "B2 invoiced equals the forecast")
      # The fixture's final invoice is unpaid (NormativeInvoices), so only the deposit is paid.
      assert_money(venue.paid, NE.expected("B1").paid, "B2 paid")

      assert_money(
        venue.outstanding,
        WeddingPlanner.Money.subtract(invoiced, NE.expected("B1").paid),
        "B2 outstanding"
      )

      assert [%{source: :invoicing_complete}] = venue.confirmed_offers
    end

    @tag example: "B3"
    test "B3: Attire, no offers, target €2,500 → forecast €2,500 under every preset" do
      %{snapshot: snapshot} = BudgetSnapshots.b3()
      b3 = NE.expected("B3")
      ad_hoc = %Preset{name: "Ad hoc", id: nil}

      for preset <- Preset.defaults() ++ [ad_hoc] do
        attire = layers_of(snapshot, b3.category, preset)

        assert attire.branch == :target, preset.name
        assert attire.fallback_winner == :base, preset.name
        assert_money(money(attire.forecast), b3.forecast_under_every_preset, preset.name)
        assert norm(attire.committed.steps) == [{"No confirmed offer", {:money, e(0)}}]
        assert_money(money(attire.committed), eur(0), "B3 committed")
      end
    end
  end

  # -- every branch -----------------------------------------------------------------------------

  describe "every BUD-03 branch (BudgetSnapshots.branches/0)" do
    setup do
      %{snapshot: snapshot} = built = BudgetSnapshots.branches()
      Map.put(built, :categories_out, Budget.forecast(snapshot, likely()))
    end

    test "every category is listed, in snapshot.categories order", ctx do
      assert Enum.map(ctx.categories_out, & &1.category.name) ==
               ~w(Venue Photography Flowers Attire Church)
    end

    test "invoicing complete forecasts the invoiced total, even below committed (D-23)", ctx do
      photography = layers(ctx.categories_out, "Photography")

      assert photography.branch == :confirmed
      assert_money(money(photography.committed), eur(2_000), "committed")
      assert_money(photography.invoiced, eur(1_800), "invoiced")
      assert_money(money(photography.forecast), eur(1_800), "forecast")
      assert [%{source: :invoicing_complete, forecast: forecast}] = photography.confirmed_offers
      assert_money(forecast, eur(1_800), "offer forecast")
    end

    test "a planning pick larger than the unlinked invoices forecasts the pick, not the target",
         ctx do
      flowers = layers(ctx.categories_out, "Flowers")

      assert flowers.branch == :planning_pick
      assert flowers.fallback_winner == :base
      assert flowers.planning_pick.offer.vendor_name == "Florist F"
      assert_money(money(flowers.planning_pick.total), eur(1_280), "pick total")
      assert_money(flowers.planning_pick.breakdown.total, eur(1_280), "pick breakdown total")
      assert_money(money(flowers.forecast), eur(1_280), "forecast")
      assert flowers.confirmed_offers == []
      assert [%{invoice: %Invoice{label: "Florist deposit"}}] = flowers.unlinked_invoices
      assert_money(flowers.unlinked_invoiced, eur(300), "unlinked")
    end

    test "a target smaller than the unlinked invoices forecasts the invoices", ctx do
      attire = layers(ctx.categories_out, "Attire")

      assert attire.branch == :target
      assert attire.fallback_winner == :unlinked_invoices
      assert_money(money(attire.forecast), eur(3_100), "forecast")
      assert attire.planning_pick == nil
    end

    test "the empty category is listed, forecasting €0 with branch :no_target", ctx do
      church = layers(ctx.categories_out, "Church")

      assert church.branch == :no_target
      assert church.target == nil
      assert_money(money(church.forecast), eur(0), "forecast")
      assert_money(church.invoiced, eur(0), "invoiced")
      assert church.invoices == []
    end

    test "invoiced / paid / outstanding over every invoice of the category", ctx do
      flowers = layers(ctx.categories_out, "Flowers")
      assert_money(flowers.invoiced, eur(300), "invoiced")
      assert_money(flowers.paid, eur(0), "paid")
      assert_money(flowers.outstanding, eur(300), "outstanding")
      assert Enum.map(flowers.invoices, & &1.id) == [ctx.invoices["Florist deposit"].id]
    end
  end

  # -- needs attention (XC-42, D-26, DR-84) ----------------------------------------------------

  describe "needs attention (XC-42, D-26, DR-84)" do
    test "a confirmed offer's counted invalid line names it in its category (role: :confirmed)" do
      %{snapshot: snapshot, offers: %{"Venue A" => venue_a}} = BudgetSnapshots.branches()
      # Line 2 is Venue A's mandatory "Seating" line (always counted, CST-21) — orphaning
      # its event makes it invalid without touching whether it counts.
      seating = Enum.find(snapshot.offer_lines, &(&1.id == 2))
      invalid_seating = %{seating | event_id: nil}
      snapshot = Snapshot.apply(snapshot, {:put, :offer_lines, invalid_seating})

      venue = layers_of(snapshot, "Venue")

      assert venue.needs_attention == [
               %{offer: venue_a, role: :confirmed, invalid_lines: [invalid_seating]}
             ]

      # D-26: the money stays visible in the offer's own committed formula, unchanged.
      offer_committed = Enum.find(venue.confirmed_offers, &(&1.offer.id == venue_a.id)).committed

      assert Enum.any?(
               offer_committed.steps,
               &(&1.label == "Seating — invalid (its event was deleted), not counted")
             )
    end

    test "a confirmed offer's uncounted invalid line (outside its frozen scope) is listed too (DR-84)" do
      %{snapshot: snapshot, offers: %{"Venue A" => venue_a}} = BudgetSnapshots.branches()
      # "Garden ceremony" is not wanted and outside Venue A's frozen scope (it is not in
      # `NormativeInvoices`' frozen list) — an optional line for it never counts, but XC-42's
      # condition (any invalid line) does not care whether a line counts.
      garden = Enum.find(snapshot.services, &(&1.name == "Garden ceremony"))

      uncounted_invalid = %OfferLine{
        id: 500,
        offer_id: venue_a.id,
        service_id: garden.id,
        state: :optional,
        basis: :per_adult,
        event_id: nil,
        amount: eur(1),
        enabled: false
      }

      snapshot = Snapshot.apply(snapshot, {:put, :offer_lines, uncounted_invalid})
      venue = layers_of(snapshot, "Venue")

      assert venue.needs_attention == [
               %{offer: venue_a, role: :confirmed, invalid_lines: [uncounted_invalid]}
             ]
    end

    test "the planning pick's invalid line marks its category (role: :planning_pick); a non-pick shortlisted offer's invalid line does not" do
      %{snapshot: snapshot, offers: %{"Florist F" => florist_f, "Florist G" => florist_g}} =
        BudgetSnapshots.branches()

      # Florist F is Flowers' planning pick (BudgetSnapshots.branches/0); its mandatory,
      # per-attendee "Table flowers" line (id 202) is the forecast's base once invalid.
      table_flowers = Enum.find(snapshot.offer_lines, &(&1.id == 202))
      invalid_pick_line = %{table_flowers | event_id: nil}

      # Florist G is merely shortlisted (not the pick, not confirmed) — its own invalid
      # line must never surface here.
      not_the_pick = %OfferLine{
        id: 500,
        offer_id: florist_g.id,
        label: "Chairs",
        state: :mandatory,
        basis: :per_adult,
        event_id: nil,
        amount: eur(5),
        enabled: false
      }

      snapshot =
        Snapshot.apply(snapshot, [
          {:put, :offer_lines, invalid_pick_line},
          {:put, :offer_lines, not_the_pick}
        ])

      categories_out = Budget.forecast(snapshot, likely())
      flowers = layers(categories_out, "Flowers")

      assert flowers.branch == :planning_pick
      assert flowers.planning_pick.offer.id == florist_f.id

      assert flowers.needs_attention == [
               %{offer: florist_f, role: :planning_pick, invalid_lines: [invalid_pick_line]}
             ]

      # The target and no-target categories carry the key too, empty.
      assert layers(categories_out, "Attire").needs_attention == []
      assert layers(categories_out, "Church").needs_attention == []
    end

    test "no invalid lines anywhere: every category's needs_attention is [], carried through overall/3 and for_roles/2" do
      %{snapshot: snapshot} = BudgetSnapshots.branches()

      categories_out = Budget.forecast(snapshot, likely())
      assert Enum.all?(categories_out, &(&1.needs_attention == []))

      overall = Budget.overall(snapshot, likely())
      assert Enum.all?(overall.categories, &(&1.needs_attention == []))

      {:ok, by_role} = Budget.for_roles(snapshot)

      for {_role, role_overall} <- by_role do
        assert Enum.all?(role_overall.categories, &(&1.needs_attention == []))
      end
    end
  end

  describe "confirmed offers (D-20, D-23, DR-70)" do
    test "invoiced above committed, invoicing not complete → forecast = invoiced, :invoiced" do
      %{snapshot: snapshot, offer: venue_a} = BudgetSnapshots.b1()
      snapshot = put_invoice(snapshot, 50, venue_a.category_id, venue_a.id, "Extra", eur(12_000))
      venue = layers_of(snapshot, "Venue")

      assert [%{source: :invoiced, forecast: forecast}] = venue.confirmed_offers
      assert_money(forecast, eur(15_000), "offer forecast")
      assert_money(money(venue.forecast), eur(15_000), "forecast")
      assert_money(venue.invoiced, eur(15_000), "invoiced")
    end

    test "tie: committed == invoiced → source :committed" do
      %{snapshot: snapshot, offer: venue_a} = BudgetSnapshots.b1()
      rest = WeddingPlanner.Money.subtract(NE.given("B1").committed, NE.expected("B1").paid)
      snapshot = put_invoice(snapshot, 50, venue_a.category_id, venue_a.id, "Rest", rest)
      venue = layers_of(snapshot, "Venue")

      assert [%{source: :committed}] = venue.confirmed_offers
      assert_money(money(venue.forecast), NE.given("B1").committed, "forecast")
    end

    test "two confirmed offers in one category: committed and forecast are sums, no double count" do
      %{snapshot: snapshot, categories: %{"Photography" => photography}} =
        BudgetSnapshots.branches()

      second = %Offer{
        id: 60,
        category_id: photography.id,
        vendor_name: "Photographer Q",
        status: :confirmed,
        vat_basis: :inclusive
      }

      line = %OfferLine{
        id: 600,
        offer_id: 60,
        label: "Album",
        state: :mandatory,
        basis: :flat,
        amount: eur(1_000)
      }

      snapshot =
        snapshot
        |> put_offer(second)
        |> Snapshot.apply({:put, :offer_lines, line})
        |> put_invoice(61, photography.id, 60, "Album deposit", eur(400))

      layers = layers_of(snapshot, "Photography")

      assert Enum.map(layers.confirmed_offers, & &1.offer.vendor_name) ==
               ["Photographer P", "Photographer Q"]

      assert_money(money(layers.committed), eur(3_000), "committed")
      # 1,800 (complete) + max(1,000, 400)
      assert_money(money(layers.forecast), eur(2_800), "forecast")
      assert_money(layers.invoiced, eur(2_200), "invoiced")
      assert layers.unlinked_invoices == []
      assert_money(layers.unlinked_invoiced, eur(0), "unlinked")

      q = Enum.find(layers.confirmed_offers, &(&1.offer.id == 60))
      assert Enum.map(q.invoices, & &1.id) == [61]
      assert_money(q.invoiced, eur(400), "Q invoiced")
      assert_money(q.outstanding, eur(400), "Q outstanding")
    end
  end

  describe "ties in the fallback branch" do
    test "base == unlinked invoices → fallback_winner :base" do
      %{snapshot: snapshot, category: attire} = BudgetSnapshots.b3()
      target = NE.given("B3").category.target
      snapshot = put_invoice(snapshot, 70, attire.id, nil, "Suit", target)
      attire_layers = layers_of(snapshot, "Attire")

      assert attire_layers.fallback_winner == :base
      assert_money(money(attire_layers.forecast), target, "forecast")
    end
  end

  describe "states the contexts forbid stay defined (DR-70)" do
    test "an invoice linked to a shortlisted offer counts as unlinked" do
      %{snapshot: snapshot, offers: %{"Florist G" => florist_g}} = BudgetSnapshots.branches()
      snapshot = put_invoice(snapshot, 80, florist_g.category_id, florist_g.id, "G", eur(2_000))
      flowers = layers_of(snapshot, "Flowers")

      assert Enum.map(flowers.unlinked_invoices, & &1.invoice.id) |> Enum.sort() == [32, 80]
      assert_money(flowers.unlinked_invoiced, eur(2_300), "unlinked")
      assert flowers.fallback_winner == :unlinked_invoices
      assert_money(money(flowers.forecast), eur(2_300), "forecast")
    end

    test "a planning_pick flag in a category with a confirmed offer is ignored" do
      %{snapshot: snapshot, offer: venue_a} = BudgetSnapshots.b1()

      pick = %Offer{
        id: 90,
        category_id: venue_a.category_id,
        vendor_name: "Venue Z",
        status: :shortlisted,
        planning_pick: true,
        vat_basis: :inclusive
      }

      venue = snapshot |> put_offer(pick) |> layers_of("Venue")

      assert venue.branch == :confirmed
      assert venue.planning_pick == nil
      assert venue.fallback_winner == nil
      assert_money(money(venue.forecast), NE.expected("B1").forecast, "forecast")
    end

    test "a planning pick on a rejected offer is ignored (the target applies)" do
      %{snapshot: snapshot, offers: %{"Florist F" => florist_f}} = BudgetSnapshots.branches()
      snapshot = put_offer(snapshot, %{florist_f | status: :rejected})
      flowers = layers_of(snapshot, "Flowers")

      assert flowers.branch == :target
      assert_money(money(flowers.forecast), eur(1_000), "forecast = target")
    end

    test "an invoice linked to an offer of another category counts once, in its own category" do
      %{snapshot: snapshot, offers: %{"Photographer P" => photographer}, categories: cats} =
        BudgetSnapshots.branches()

      snapshot = put_invoice(snapshot, 81, cats["Attire"].id, photographer.id, "Odd", eur(50))
      out = Budget.overall(snapshot, likely())

      photography = layers(out.categories, "Photography")
      attire = layers(out.categories, "Attire")
      assert_money(photography.invoiced, eur(1_800), "Photography invoiced")
      assert [%{invoices: [%Invoice{id: 31}]}] = photography.confirmed_offers
      assert 81 in Enum.map(attire.unlinked_invoices, & &1.invoice.id)
      assert_money(attire.invoiced, eur(3_150), "Attire invoiced")
      assert_money(out.invoiced, eur(3_000 + 1_800 + 300 + 3_150), "overall invoiced")
    end
  end

  # -- formulas ---------------------------------------------------------------------------------

  describe "formulas (BUD-08): labels and steps, exactly" do
    setup do
      %{snapshot: snapshot} = built = BudgetSnapshots.branches()
      Map.put(built, :overall, Budget.overall(snapshot, likely()))
    end

    test ":confirmed, not complete — preset step, then the larger-of step", ctx do
      venue = layers(ctx.overall.categories, "Venue")

      assert venue.committed.label == "Committed"
      assert venue.forecast.label == "Forecast"

      assert norm(venue.committed.steps) == [
               {"Headcount preset", {:preset, "Likely"}},
               {"Venue A", {:money, e(11_726)}}
             ]

      assert norm(venue.forecast.steps) == [
               {"Headcount preset", {:preset, "Likely"}},
               {[
                  "Venue A",
                  " — larger of committed ",
                  {:money, e(11_726)},
                  " and invoiced so far ",
                  {:money, e(3_000)}
                ], {:money, e(11_726)}}
             ]
    end

    test ":confirmed, all-flat and invoicing complete — no preset step anywhere", ctx do
      photography = layers(ctx.overall.categories, "Photography")

      assert norm(photography.committed.steps) == [{"Photographer P", {:money, e(2_000)}}]

      assert norm(photography.forecast.steps) == [
               {["Photographer P", " — invoicing complete, invoiced total"], {:money, e(1_800)}}
             ]
    end

    test "an all-flat confirmed offer that is not complete has no preset step either" do
      %{snapshot: snapshot, offers: %{"Photographer P" => p}} = BudgetSnapshots.branches()
      snapshot = put_offer(snapshot, %{p | invoicing_complete: false})
      photography = layers_of(snapshot, "Photography")

      assert norm(photography.forecast.steps) == [
               {[
                  "Photographer P",
                  " — larger of committed ",
                  {:money, e(2_000)},
                  " and invoiced so far ",
                  {:money, e(1_800)}
                ], {:money, e(2_000)}}
             ]
    end

    test ":confirmed with an unlinked invoice — the invoice step follows the offers" do
      %{snapshot: snapshot, categories: %{"Photography" => cat}} = BudgetSnapshots.branches()
      snapshot = put_invoice(snapshot, 82, cat.id, nil, "Prints", eur(75))
      photography = layers_of(snapshot, "Photography")

      assert norm(photography.forecast.steps) == [
               {["Photographer P", " — invoicing complete, invoiced total"], {:money, e(1_800)}},
               {["Prints", " — not linked to an offer"], {:money, e(75)}}
             ]

      assert_money(money(photography.forecast), eur(1_875), "forecast")
    end

    test ":planning_pick — preset step, pick, unlinked invoice, larger of the two", ctx do
      flowers = layers(ctx.overall.categories, "Flowers")

      assert norm(flowers.committed.steps) == [{"No confirmed offer", {:money, e(0)}}]

      assert norm(flowers.forecast.steps) == [
               {"Headcount preset", {:preset, "Likely"}},
               {["Planning pick — ", "Florist F"], {:money, e(1_280)}},
               {["Florist deposit", " — not linked to an offer"], {:money, e(300)}},
               {"Larger of the two", {:money, e(1_280)}}
             ]
    end

    test ":target — target, unlinked invoice, larger of the two (no preset step)", ctx do
      attire = layers(ctx.overall.categories, "Attire")

      assert norm(attire.forecast.steps) == [
               {"Target", {:money, e(2_500)}},
               {["Tailor invoice", " — not linked to an offer"], {:money, e(3_100)}},
               {"Larger of the two", {:money, e(3_100)}}
             ]
    end

    test ":no_target without invoices — one step", ctx do
      church = layers(ctx.overall.categories, "Church")
      assert norm(church.forecast.steps) == [{"No target set — counts as zero", {:money, e(0)}}]
    end

    test "overall Committed, Forecast and Available", ctx do
      overall = ctx.overall
      preset = {"Headcount preset", {:preset, "Likely"}}

      assert overall.committed.label == "Committed"

      assert norm(overall.committed.steps) == [
               preset,
               {"Venue", {:money, e(11_726)}},
               {"Photography", {:money, e(2_000)}},
               {"Flowers", {:money, e(0)}},
               {"Attire", {:money, e(0)}},
               {"Church", {:money, e(0)}}
             ]

      assert overall.forecast.label == "Forecast"

      assert norm(overall.forecast.steps) == [
               preset,
               {"Venue", {:money, e(11_726)}},
               {"Photography", {:money, e(1_800)}},
               {"Flowers", {:money, e(1_280)}},
               {"Attire", {:money, e(3_100)}},
               {"Church", {:money, e(0)}}
             ]

      assert overall.available.label == "Available"

      assert norm(overall.available.steps) == [
               preset,
               {"Overall budget", {:money, e(20_000)}},
               {"Forecast", {:money, e(17_906)}}
             ]

      assert_money(money(overall.available), eur(2_094), "available")
    end

    test "no preset step in the overall formulas when nothing depends on the preset" do
      %{snapshot: snapshot} = BudgetSnapshots.b3()
      snapshot = %{snapshot | settings: %Settings{overall_budget: eur(3_000)}}
      overall = Budget.overall(snapshot, likely())

      assert norm(overall.committed.steps) == [{"Attire", {:money, e(0)}}]
      assert norm(overall.forecast.steps) == [{"Attire", {:money, e(2_500)}}]

      assert norm(overall.available.steps) == [
               {"Overall budget", {:money, e(3_000)}},
               {"Forecast", {:money, e(2_500)}}
             ]
    end

    test "nothing rounds: sub-cent amounts survive to every total" do
      category = %Category{id: 1, name: "Cake", sort_order: 0}

      offer = %Offer{
        id: 1,
        category_id: 1,
        vendor_name: "Baker",
        status: :confirmed,
        vat_basis: :inclusive
      }

      line = %OfferLine{
        id: 1,
        offer_id: 1,
        label: "Cake",
        state: :mandatory,
        basis: :flat,
        amount: eur(Decimal.new("1000.005"))
      }

      snapshot = %Snapshot{
        categories: [category],
        offers: [offer],
        offer_lines: [line],
        settings: %Settings{overall_budget: eur(2_000)}
      }

      snapshot = put_invoice(snapshot, 1, 1, nil, "Topper", eur(Decimal.new("0.004")))
      overall = Budget.overall(snapshot, likely())
      [cake] = overall.categories

      assert Decimal.equal?(money(cake.committed).amount, Decimal.new("1000.005"))
      assert Decimal.equal?(money(cake.forecast).amount, Decimal.new("1000.009"))
      assert Decimal.equal?(money(overall.forecast).amount, Decimal.new("1000.009"))
      assert Decimal.equal?(money(overall.available).amount, Decimal.new("999.991"))
      assert Decimal.equal?(overall.invoiced.amount, Decimal.new("0.004"))
    end
  end

  # -- overall ----------------------------------------------------------------------------------

  describe "overall/3 (BUD-05, DR-72)" do
    setup do
      %{snapshot: snapshot} = built = BudgetSnapshots.branches()
      Map.put(built, :overall, Budget.overall(snapshot, likely()))
    end

    test "every total is the sum of the category layers; spent == paid", %{overall: overall} do
      sum = fn fun -> overall.categories |> Enum.map(fun) |> WeddingPlanner.Money.sum() end

      assert overall.preset == likely()
      assert_money(overall.invoiced, sum.(& &1.invoiced), "invoiced")
      assert_money(overall.paid, sum.(& &1.paid), "paid")
      assert_money(overall.outstanding, sum.(& &1.outstanding), "outstanding")
      assert_money(money(overall.committed), sum.(&money(&1.committed)), "committed")
      assert_money(money(overall.forecast), sum.(&money(&1.forecast)), "forecast")
      assert_money(overall.spent, overall.paid, "spent")

      assert_money(overall.invoiced, eur(3_000 + 1_800 + 300 + 3_100), "invoiced value")
      assert_money(overall.paid, eur(3_000 + 1_800 + 3_100), "paid value")
      assert_money(overall.outstanding, eur(300), "outstanding value")
      assert_money(money(overall.forecast), eur(17_906), "forecast value")
    end

    test "target total ignores unset targets", %{overall: overall} do
      # Flowers €1,000 + Attire €2,500; Venue, Photography and Church have none.
      assert_money(overall.target, eur(3_500), "target")
    end

    test "within budget: available = budget − forecast, no over_budget", %{overall: overall} do
      assert overall.overall_budget == BudgetSnapshots.branches_budget()
      assert_money(money(overall.available), eur(2_094), "available")
      assert overall.over_budget == nil
    end

    test "over budget: available negative, over_budget = forecast − budget", %{snapshot: snapshot} do
      snapshot = %{snapshot | settings: %Settings{overall_budget: eur(10_000)}}
      overall = Budget.overall(snapshot, likely())

      assert_money(money(overall.available), eur(-7_906), "available")
      assert_money(overall.over_budget, eur(7_906), "over budget")
    end

    test "exactly on budget: available €0, over_budget nil", %{snapshot: snapshot} do
      snapshot = %{snapshot | settings: %Settings{overall_budget: eur(17_906)}}
      overall = Budget.overall(snapshot, likely())

      assert_money(money(overall.available), eur(0), "available")
      assert overall.over_budget == nil
    end

    test "no overall budget → available :no_budget, over_budget nil", %{snapshot: snapshot} do
      overall = Budget.overall(%{snapshot | settings: %Settings{}}, likely())

      assert overall.overall_budget == nil
      assert overall.available == :no_budget
      assert overall.over_budget == nil
    end

    test "a snapshot without categories gives zero totals" do
      overall = Budget.overall(%Snapshot{}, likely())

      assert overall.categories == []
      assert_money(money(overall.forecast), eur(0), "forecast")
      assert_money(overall.target, eur(0), "target")
      assert overall.forecast.steps == []
    end
  end

  # -- for_roles --------------------------------------------------------------------------------

  describe "for_roles/2 (BUD-04, DR-71)" do
    test "one overall per role preset; Likely's equals overall/2 under the likely preset" do
      %{snapshot: snapshot} = BudgetSnapshots.branches()

      assert {:ok, %{minimum: min, likely: lik, maximum: max}} = Budget.for_roles(snapshot)

      assert lik == Budget.overall(snapshot, likely())
      assert min == Budget.overall(snapshot, minimum())
      assert max == Budget.overall(snapshot, NormativeInvoices.preset("Maximum"))
      assert min.preset.role == :minimum
      assert_money(money(layers(min.categories, "Flowers").forecast), eur(1_140), "Minimum pick")
      assert_money(money(layers(lik.categories, "Flowers").forecast), eur(1_280), "Likely pick")
    end

    test "presets are found by role, not by name" do
      %{snapshot: snapshot} = BudgetSnapshots.branches()

      renamed =
        Enum.map(snapshot.headcount_presets, fn
          %Preset{role: :likely} = p -> %{p | name: "Expected"}
          p -> p
        end)

      assert {:ok, %{likely: %{preset: %Preset{name: "Expected"}}}} =
               Budget.for_roles(%{snapshot | headcount_presets: Enum.reverse(renamed)})
    end

    test ":missing when a role is unassigned" do
      %{snapshot: snapshot} = BudgetSnapshots.branches()
      without_max = Enum.reject(snapshot.headcount_presets, &(&1.role == :maximum))

      assert Budget.for_roles(%{snapshot | headcount_presets: without_max}) == :missing
    end
  end

  # -- the seam, the frozen selection -----------------------------------------------------------

  describe "the headcount: seam" do
    test "forecast/3 passes opts to every Offer.total/4 and breakdown/4 (SEAM: fixed_headcount)" do
      %{snapshot: snapshot} = BudgetSnapshots.b1()
      no_guests = %{snapshot | persons: [], invitations: []}

      # Without the seam and without guests, the total is different (so the check below is
      # not vacuous).
      refute Money.equal?(money(layers_of(no_guests, "Venue").forecast), eur(11_726))

      # SEAM: the doc's stated headcount replaces the (empty) guest list.
      venue =
        no_guests
        |> Budget.forecast(likely(), headcount: NE.fixed_headcount())
        |> layers("Venue")

      assert_money(money(venue.forecast), NE.expected("B1").forecast, "forecast")
      [offer] = venue.confirmed_offers
      assert_money(money(offer.committed), NE.expected("B1").forecast, "committed")
      assert_money(offer.breakdown.total, NE.expected("B1").forecast, "breakdown total")

      # overall/3 and for_roles/2 pass it on too.
      overall = Budget.overall(no_guests, likely(), headcount: NE.fixed_headcount())
      assert_money(money(overall.forecast), NE.expected("B1").forecast, "overall")
    end

    test "a planning pick's total and breakdown get the opts too (SEAM: fixed_headcount)" do
      %{snapshot: snapshot} = BudgetSnapshots.branches()

      no_guests = %{
        snapshot
        | persons: [],
          invitations: [],
          categories: [Enum.find(snapshot.categories, &(&1.name == "Flowers"))]
      }

      # SEAM: Likely 78 attendees at Dinner.
      [flowers] = Budget.forecast(no_guests, likely(), headcount: NE.fixed_headcount())
      assert_money(money(flowers.planning_pick.total), eur(1_280), "pick total")
      assert_money(flowers.planning_pick.breakdown.total, eur(1_280), "pick breakdown")
    end
  end

  describe "the frozen selection (CST-40, CST-41)" do
    test "a priority change does not move a confirmed offer; a counted person does" do
      %{snapshot: snapshot} = BudgetSnapshots.b1()
      %Service{} = catering = Enum.find(snapshot.services, &(&1.name == "Catering"))

      changed =
        Snapshot.apply(
          snapshot,
          {:put, :services, %Service{catering | wanted_priority: :not_wanted}}
        )

      venue = layers_of(changed, "Venue")
      assert_money(money(venue.committed), NE.expected("B1").forecast, "committed")
      assert_money(money(venue.forecast), NE.expected("B1").forecast, "forecast")

      # Not vacuous: the same change does move the offer while it is not confirmed.
      [offer] = changed.offers
      unconfirmed = put_offer(changed, %{offer | status: :shortlisted})

      refute Money.equal?(
               money(OfferEngine.total(unconfirmed, %{offer | status: :shortlisted}, likely())),
               NE.expected("B1").forecast
             )

      # CST-41: one more certain adult invited to Dinner → Seating counts 79 attendees.
      [dinner] = snapshot.events

      guest = %Person{
        id: 5000,
        first_name: "New",
        certainty: :certain,
        age_category: :adult,
        want_tier: :yes
      }

      invitation = %Invitation{id: 6000, person_id: 5000, event_id: dinner.id, status: :invited}

      grown =
        Snapshot.apply(snapshot, [{:put, :persons, guest}, {:put, :invitations, invitation}])

      venue = layers_of(grown, "Venue")
      assert_money(money(venue.committed), eur(11_738), "committed follows the guest list")
      assert_money(money(venue.forecast), eur(11_738), "forecast follows the guest list")
    end
  end

  # -- property ---------------------------------------------------------------------------------

  @runs 300

  describe "property (independent integer-cents oracle)" do
    test "per category: forecast, committed, invoiced, paid, outstanding; forecast ≥ invoiced; overall = Σ" do
      seen =
        for run <- 1..@runs, reduce: MapSet.new() do
          seen ->
            %{snapshot: snapshot, spec: spec} = random_case()
            preset = Enum.random(Preset.defaults())
            oracle = oracle(spec)
            context = "run #{run}: #{inspect(spec, limit: :infinity)}"
            overall = Budget.overall(snapshot, preset)

            assert length(overall.categories) == length(spec.categories), context

            seen =
              Enum.zip_reduce(overall.categories, oracle.categories, seen, fn layers, o, seen ->
                assert layers.category.id == o.id, context
                assert layers.branch == o.branch, context
                assert cents(money(layers.forecast)) == o.forecast, context
                assert cents(money(layers.committed)) == o.committed, context
                assert cents(layers.invoiced) == o.invoiced, context
                assert cents(layers.paid) == o.paid, context
                assert cents(layers.outstanding) == o.invoiced - o.paid, context
                assert cents(money(layers.forecast)) >= cents(layers.invoiced), context

                assert Enum.map(layers.confirmed_offers, & &1.source) == o.sources, context

                seen
                |> MapSet.put(layers.branch)
                |> MapSet.put(layers.fallback_winner)
                |> MapSet.union(MapSet.new(o.sources))
              end)

            assert cents(money(overall.forecast)) == oracle.forecast, context
            assert cents(money(overall.committed)) == oracle.committed, context
            assert cents(overall.invoiced) == oracle.invoiced, context
            assert cents(overall.paid) == oracle.paid, context
            assert cents(overall.spent) == oracle.paid, context
            assert cents(overall.outstanding) == oracle.invoiced - oracle.paid, context
            assert cents(overall.target) == oracle.target, context

            case spec.budget do
              nil ->
                assert overall.available == :no_budget, context
                assert overall.over_budget == nil, context
                MapSet.put(seen, :no_budget)

              budget ->
                assert cents(money(overall.available)) == budget - oracle.forecast, context

                if oracle.forecast > budget do
                  assert cents(overall.over_budget) == oracle.forecast - budget, context
                  MapSet.put(seen, :over_budget)
                else
                  assert overall.over_budget == nil, context
                  MapSet.put(seen, :within_budget)
                end
            end
        end

      for outcome <- [
            :confirmed,
            :planning_pick,
            :target,
            :no_target,
            :base,
            :unlinked_invoices,
            :committed,
            :invoiced,
            :invoicing_complete,
            :no_budget,
            :over_budget,
            :within_budget
          ] do
        assert outcome in seen, "#{inspect(outcome)} never generated in #{@runs} runs"
      end
    end
  end

  # A random case (see the task): 0–4 categories, each with 0–2 services, 0–3 offers of
  # 0–3 flat mandatory lines (service or ad hoc), random status; confirmed ones carry the
  # frozen rows `Selection.freeze/2` gives and a random `invoicing_complete`; at most one
  # planning pick on a non-rejected, non-confirmed offer where no offer is confirmed; 0–4
  # invoices of 1–3 lines, linked to a random confirmed offer of the category or to none,
  # randomly paid; a random target or none; a random overall budget or none.
  defp random_case do
    category_specs =
      for c <- 1..Enum.random(0..4)//1 do
        services =
          for s <- 1..Enum.random(0..2)//1,
              do: %{
                id: c * 10 + s,
                priority: Enum.random([:must_have, :nice_to_have, :not_wanted])
              }

        offers =
          for o <- 1..Enum.random(0..3)//1 do
            status = Enum.random([:considering, :shortlisted, :rejected, :confirmed, :confirmed])

            %{
              id: c * 100 + o,
              status: status,
              complete: status == :confirmed and :rand.uniform(2) == 1,
              pick: false,
              lines:
                for l <- 1..Enum.random(0..3)//1 do
                  service_id =
                    if services != [] and :rand.uniform(2) == 1, do: Enum.random(services).id

                  %{
                    id: (c * 100 + o) * 10 + l,
                    service_id: service_id,
                    cents: Enum.random(0..500_000)
                  }
                end
            }
          end

        offers =
          case {Enum.any?(offers, &(&1.status == :confirmed)),
                Enum.filter(offers, &(&1.status in [:considering, :shortlisted]))} do
            {false, [_ | _] = eligible} ->
              if :rand.uniform(3) > 1 do
                pick_id = Enum.random(eligible).id
                Enum.map(offers, &%{&1 | pick: &1.id == pick_id})
              else
                offers
              end

            _ ->
              offers
          end

        confirmed_ids = for o <- offers, o.status == :confirmed, do: o.id

        invoices =
          for i <- 1..Enum.random(0..4)//1 do
            offer_id =
              if confirmed_ids != [] and :rand.uniform(3) > 1, do: Enum.random(confirmed_ids)

            %{
              id: c * 100 + i,
              offer_id: offer_id,
              paid: :rand.uniform(2) == 1,
              line_cents: for(_ <- 1..Enum.random(1..3), do: Enum.random(0..300_000))
            }
          end

        %{
          id: c,
          target: if(:rand.uniform(2) == 1, do: Enum.random(0..800_000)),
          services: services,
          offers: offers,
          invoices: invoices
        }
      end

    spec = %{
      categories: category_specs,
      budget: if(:rand.uniform(4) > 1, do: Enum.random(0..2_000_000))
    }

    %{snapshot: build_snapshot(spec), spec: spec}
  end

  defp build_snapshot(spec) do
    categories =
      for c <- spec.categories do
        %Category{
          id: c.id,
          name: "Category #{c.id}",
          sort_order: c.id,
          target: c.target && from_cents(c.target)
        }
      end

    services =
      for c <- spec.categories, s <- c.services do
        %Service{
          id: s.id,
          category_id: c.id,
          name: "Service #{s.id}",
          wanted_priority: s.priority,
          sort_order: s.id
        }
      end

    offers =
      for c <- spec.categories, o <- c.offers do
        %Offer{
          id: o.id,
          category_id: c.id,
          vendor_name: "Vendor #{o.id}",
          status: o.status,
          invoicing_complete: o.complete,
          planning_pick: o.pick,
          vat_basis: :inclusive
        }
      end

    lines =
      for c <- spec.categories, o <- c.offers, l <- o.lines do
        %OfferLine{
          id: l.id,
          offer_id: o.id,
          service_id: l.service_id,
          label: if(is_nil(l.service_id), do: "Line #{l.id}"),
          state: :mandatory,
          basis: :flat,
          amount: from_cents(l.cents)
        }
      end

    {invoices, invoice_lines} =
      for c <- spec.categories, i <- c.invoices, reduce: {[], []} do
        {invoices, invoice_lines} ->
          invoice = %Invoice{
            id: i.id,
            category_id: c.id,
            offer_id: i.offer_id,
            label: "Invoice #{i.id}",
            invoice_date: ~D[2027-01-01],
            paid_on: if(i.paid, do: ~D[2027-02-01])
          }

          new_lines =
            i.line_cents
            |> Enum.with_index()
            |> Enum.map(fn {cents, n} ->
              %InvoiceLine{
                id: i.id * 10 + n,
                invoice_id: i.id,
                label: "L",
                amount: from_cents(cents)
              }
            end)

          {invoices ++ [invoice], invoice_lines ++ new_lines}
      end

    snapshot = %Snapshot{
      categories: categories,
      services: services,
      offers: offers,
      offer_lines: lines,
      invoices: invoices,
      invoice_lines: Enum.shuffle(invoice_lines),
      headcount_presets: Preset.defaults(),
      settings: %Settings{overall_budget: spec.budget && from_cents(spec.budget)}
    }

    # CST-40: each confirmed offer carries what the engine freezes.
    frozen =
      for %Offer{status: :confirmed} = offer <- offers,
          service_id <- Selection.freeze(snapshot, offer),
          do: %FrozenService{
            id: {offer.id, service_id},
            offer_id: offer.id,
            service_id: service_id
          }

    %{snapshot | frozen_services: frozen}
  end

  # The oracle: integer cents only, straight from the spec.
  defp oracle(spec) do
    categories =
      for c <- spec.categories do
        invoice_cents = Map.new(c.invoices, &{&1.id, Enum.sum(&1.line_cents)})
        confirmed = Enum.filter(c.offers, &(&1.status == :confirmed))
        confirmed_ids = Enum.map(confirmed, & &1.id)
        offer_committed = fn o -> o.lines |> Enum.map(& &1.cents) |> Enum.sum() end

        per_offer =
          for o <- confirmed do
            committed = offer_committed.(o)

            invoiced =
              for(i <- c.invoices, i.offer_id == o.id, do: invoice_cents[i.id]) |> Enum.sum()

            cond do
              o.complete -> {committed, invoiced, :invoicing_complete}
              invoiced > committed -> {committed, invoiced, :invoiced}
              true -> {committed, committed, :committed}
            end
          end

        unlinked =
          for(i <- c.invoices, i.offer_id not in confirmed_ids, do: invoice_cents[i.id])
          |> Enum.sum()

        {branch, forecast} =
          if confirmed != [] do
            {:confirmed, (per_offer |> Enum.map(&elem(&1, 1)) |> Enum.sum()) + unlinked}
          else
            {branch, base} =
              case Enum.find(c.offers, & &1.pick) do
                nil when is_nil(c.target) -> {:no_target, 0}
                nil -> {:target, c.target}
                pick -> {:planning_pick, offer_committed.(pick)}
              end

            {branch, max(base, unlinked)}
          end

        %{
          id: c.id,
          branch: branch,
          forecast: forecast,
          committed: per_offer |> Enum.map(&elem(&1, 0)) |> Enum.sum(),
          sources: Enum.map(per_offer, &elem(&1, 2)),
          invoiced: invoice_cents |> Map.values() |> Enum.sum(),
          paid: for(i <- c.invoices, i.paid, do: invoice_cents[i.id]) |> Enum.sum()
        }
      end

    total = fn key -> categories |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum() end

    %{
      categories: categories,
      forecast: total.(:forecast),
      committed: total.(:committed),
      invoiced: total.(:invoiced),
      paid: total.(:paid),
      target: spec.categories |> Enum.map(&(&1.target || 0)) |> Enum.sum()
    }
  end

  defp from_cents(c), do: WeddingPlanner.Money.new(Decimal.new(1, c, -2))

  defp cents(%Money{amount: amount}), do: amount |> Decimal.mult(100) |> Decimal.to_integer()
end
