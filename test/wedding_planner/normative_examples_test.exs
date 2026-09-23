defmodule WeddingPlanner.NormativeExamplesTest do
  @moduledoc """
  Transcription self-checks for `WeddingPlanner.NormativeExamples`: every frozen figure
  is re-derived from its frozen inputs with `WeddingPlanner.Money` alone, and rendered
  through `WeddingPlannerWeb.Format.money/1`, so a mistyped amount — or one built 100×
  wrong from a string (`DR-18`) — fails here instead of silently becoming the oracle.

  These are **not** implementations of the examples: they are tagged
  `:normative_fixture` and never `example:` (see the fixture's moduledoc).
  """
  use ExUnit.Case, async: true

  @moduletag :normative_fixture

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Money
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Format

  defp eur(amount), do: Money.new(amount)
  defp dec(string), do: Decimal.new(string)

  defp line(offer, number), do: Enum.find(offer.lines, &(&1.number == number))

  defp money_results(offer, preset) do
    for %{result: %{^preset => %Elixir.Money{} = money}} <- offer.lines, do: money
  end

  defp caterer_results(preset), do: for(line <- NE.caterer_c().lines, do: line.result[preset])

  defp rate(offer, line), do: line.vat_rate || offer.default_vat_rate

  # The CST-36 per-line arithmetic, steps 1–5, as an independent re-derivation of each
  # frozen per-line result from its frozen inputs and the shared headcount. Selection
  # (CST-24) is not re-derived: only lines whose frozen result is a priced amount are fed
  # in.
  defp derive(offer, line, preset) do
    count =
      case line.basis do
        :flat -> 1
        basis -> count(NE.shared_headcount()[line.event][preset], basis)
      end

    billable = max(0, count - (line.included || 0))
    computed = Money.multiply(line.amount, billable)

    subtotal =
      if line.minimum_charge, do: Money.max(computed, line.minimum_charge), else: computed

    total =
      case offer.vat_basis do
        :inclusive -> subtotal
        :exclusive -> Money.gross_up(subtotal, rate(offer, line))
      end

    %{subtotal: subtotal, total: total}
  end

  defp count(counts, :per_adult), do: counts.adults
  defp count(counts, :per_child), do: counts.children
  defp count(counts, :per_attendee), do: counts.total

  defp assert_money(actual, expected) do
    assert Elixir.Money.equal?(actual, expected),
           "expected #{Format.money(expected)}, got #{Format.money(actual)}"
  end

  describe "O1, O2 — Venue A" do
    test "the Likely per-line results are 4000, 336, 6800, 240, 350 and sum to O1's 11726" do
      results = NE.venue_a() |> money_results("Likely") |> Enum.reject(&Elixir.Money.zero?/1)

      assert Enum.map(results, &Decimal.to_integer(&1.amount)) == [4000, 336, 6800, 240, 350]
      assert_money(Money.sum(results), NE.expected("O1").total)
      assert_money(NE.expected("O1").total, eur(11_726))
    end

    test "the Minimum per-line results are 4000, 168, 6800, 160, 350 and sum to O2's 11478" do
      results = money_results(NE.venue_a(), "Minimum")

      assert Enum.map(results, &Decimal.to_integer(&1.amount)) == [4000, 168, 6800, 160, 350]
      assert_money(Money.sum(results), NE.expected("O2").total)
      assert_money(NE.expected("O2").total, eur(11_478))
    end

    test "every priced per-line result re-derives from the line's inputs and the shared headcount" do
      offer = NE.venue_a()

      for preset <- ["Likely", "Minimum"],
          line <- offer.lines,
          line.state != :included,
          %Elixir.Money{} = frozen <- [line.result[preset]] do
        assert_money(derive(offer, line, preset).total, frozen)
      end

      # The one line the doc states works through its minimum charge: 72 × €85 = €6,120
      # (Likely) and 60 × €85 = €5,100 (Minimum), both floored to €6,800.
      catering = line(offer, 3)
      assert_money(Money.multiply(catering.amount, 72), eur(6120))
      assert_money(Money.multiply(catering.amount, 60), eur(5100))
    end

    test "the unpriced lines carry the doc's outcome, not an amount" do
      offer = NE.venue_a()

      assert line(offer, 5).result == %{"Likely" => eur(0)}
      assert line(offer, 6).result == %{"Likely" => :excluded_not_wanted}
      assert line(offer, 8).result == %{"Likely" => :ask_the_vendor}
    end
  end

  describe "O4, O5 — Caterer C" do
    test "the Likely line totals are 4838.40, 201.60, 2359.50, 242.00 and sum to O4's 7641.50" do
      totals = for %{total: total} <- caterer_results("Likely"), do: total

      expected = [dec("4838.40"), dec("201.60"), dec("2359.50"), dec("242.00")]
      for {total, want} <- Enum.zip(totals, expected), do: assert_money(total, eur(want))

      assert_money(Money.sum(totals), NE.expected("O4").line_sum)
      assert_money(NE.expected("O4").total, eur(dec("7641.50")))
      # Minimum spend €7,000 does not bite.
      assert_money(
        Money.max(Money.sum(totals), NE.caterer_c().minimum_spend),
        NE.expected("O4").total
      )

      refute NE.expected("O4").minimum_spend_applied
    end

    test "each line total is its own subtotal grossed up on its own rate (CST-36 step 5)" do
      offer = NE.caterer_c()

      for preset <- ["Likely", "Minimum"], line <- offer.lines do
        %{subtotal: subtotal, total: total} = line.result[preset]
        assert_money(Money.gross_up(subtotal, rate(offer, line)), total)
      end

      assert Enum.map(offer.lines, &rate(offer, &1)) ==
               [dec("0.12"), dec("0.12"), dec("0.21"), dec("0.21")]
    end

    test "every subtotal and line total re-derives from the line's inputs and the shared headcount" do
      offer = NE.caterer_c()

      for preset <- ["Likely", "Minimum"], line <- offer.lines do
        derived = derive(offer, line, preset)
        assert_money(derived.subtotal, line.result[preset].subtotal)
        assert_money(derived.total, line.result[preset].total)
      end
    end

    test "the Minimum line totals sum to 6344.40 and max(6344.40, 7000) is O5's 7000.00" do
      totals = for %{total: total} <- caterer_results("Minimum"), do: total

      assert_money(Money.sum(totals), eur(dec("6344.40")))
      assert_money(Money.sum(totals), NE.expected("O5").line_sum)

      assert_money(
        Money.max(NE.expected("O5").line_sum, NE.caterer_c().minimum_spend),
        NE.expected("O5").total
      )

      assert_money(NE.expected("O5").total, eur(7000))
      assert NE.expected("O5").minimum_spend_applied
    end
  end

  describe "O6 — Caterer C computed in the wrong order" do
    test "summing the Likely subtotals (6650) and grossing up once at 21% gives 8046.50" do
      o6 = NE.expected("O6").sum_then_one_rate
      subtotals = for %{subtotal: subtotal} <- caterer_results("Likely"), do: subtotal

      assert Enum.map(subtotals, &Decimal.to_integer(&1.amount)) == [4320, 180, 1950, 200]
      assert_money(Money.sum(subtotals), eur(6650))
      assert_money(Money.sum(subtotals), o6.subtotal_sum)
      assert_money(Money.gross_up(o6.subtotal_sum, o6.rate), o6.wrong_total)
      assert_money(o6.wrong_total, eur(dec("8046.50")))
      assert_money(o6.correct_total, NE.expected("O4").total)
      refute Elixir.Money.equal?(o6.wrong_total, o6.correct_total)
    end

    test "flooring the Minimum subtotals (5520) at 7000 before grossing up at 21% gives 8470" do
      o6 = NE.expected("O6").minimum_spend_before_vat
      subtotals = for %{subtotal: subtotal} <- caterer_results("Minimum"), do: subtotal

      assert Enum.map(subtotals, &Decimal.to_integer(&1.amount)) == [3600, 120, 1600, 200]
      assert_money(Money.sum(subtotals), eur(5520))
      assert_money(Money.sum(subtotals), o6.subtotal_sum)

      floored = Money.max(o6.subtotal_sum, NE.caterer_c().minimum_spend)
      assert_money(floored, eur(7000))
      assert_money(Money.gross_up(floored, o6.rate), o6.wrong_total)
      assert_money(o6.wrong_total, eur(8470))
      assert_money(o6.correct_total, NE.expected("O5").total)
      refute Elixir.Money.equal?(o6.wrong_total, o6.correct_total)
    end
  end

  describe "O3 — Venue B" do
    test "is recorded as an expectation, with no figure" do
      o3 = NE.expected("O3")

      assert o3.gap == %{service: "Catering", priority: :must_have, marker: :prominent_warning}
      assert o3.total_excludes_service == "Catering"
      assert o3.like_for_like == false
      refute Map.has_key?(o3, :total)

      catering = Enum.find(NE.venue_category().services, &(&1.name == "Catering"))
      assert catering.priority == :must_have
    end
  end

  describe "B1–B4 — budget" do
    test "B1: committed is O1; invoiced = paid = the deposit; outstanding 0; 8726 not yet invoiced" do
      given = NE.given("B1")
      b1 = NE.expected("B1")

      assert_money(given.committed, NE.expected("O1").total)
      invoiced = given.invoices |> Enum.map(& &1.amount) |> Money.sum()
      paid = for(%{paid: true, amount: amount} <- given.invoices, do: amount) |> Money.sum()

      assert_money(invoiced, b1.invoiced)
      assert_money(paid, b1.paid)
      assert_money(Money.sum([b1.paid, b1.outstanding]), b1.invoiced)
      assert_money(b1.outstanding, eur(0))
      # Not complete: forecast = max(committed, invoiced so far) (BUD-03).
      assert_money(Money.max(given.committed, invoiced), b1.forecast)
      assert_money(b1.forecast, eur(11_726))
      assert b1.variance.direction == :not_yet_invoiced
      assert_money(Money.sum([b1.invoiced, b1.variance.amount]), given.committed)
      assert_money(b1.variance.amount, eur(8726))
    end

    test "B2: complete, so forecast = invoiced (3000 + 8900 = 11900), 174 above committed" do
      given = NE.given("B2")
      b2 = NE.expected("B2")

      assert given.invoicing_complete
      invoiced = given.invoices |> Enum.map(& &1.amount) |> Money.sum()

      assert_money(invoiced, b2.forecast)
      assert_money(b2.forecast, eur(11_900))
      assert b2.variance.direction == :above_committed
      assert_money(Money.sum([given.committed, b2.variance.amount]), invoiced)
      assert_money(b2.variance.amount, eur(174))
    end

    test "B3: no offers, so the forecast is the target, 2500" do
      category = NE.given("B3").category

      assert category.offers == []
      assert_money(NE.expected("B3").forecast_under_every_preset, category.target)
      assert_money(category.target, eur(2500))
    end

    test "B4: the forbidden naive delta is 2 × €85 + €40 + 3 × €12 = 246, from Venue A's rates" do
      %{offer: offer, what_if: %{adds: adds}} = NE.given("B4")

      naive =
        Money.sum([
          Money.multiply(line(offer, 3).amount, adds.adults),
          Money.multiply(line(offer, 4).amount, adds.children),
          Money.multiply(line(offer, 2).amount, adds.adults + adds.children)
        ])

      assert {adds.adults, adds.children} == {2, 1}
      assert_money(naive, NE.expected("B4").naive_delta)
      assert_money(NE.expected("B4").naive_delta, eur(246))
    end
  end

  describe "rendering — no amount was built 100× wrong (DR-18, DR-17)" do
    test "every expected figure renders as the nl-BE string it should" do
      cases = [
        {NE.expected("O1").total, "€ 11.726,00"},
        {NE.expected("O2").total, "€ 11.478,00"},
        {NE.expected("O4").total, "€ 7.641,50"},
        {NE.expected("O4").line_sum, "€ 7.641,50"},
        {NE.expected("O5").total, "€ 7.000,00"},
        {NE.expected("O5").line_sum, "€ 6.344,40"},
        {NE.expected("O6").sum_then_one_rate.subtotal_sum, "€ 6.650,00"},
        {NE.expected("O6").sum_then_one_rate.wrong_total, "€ 8.046,50"},
        {NE.expected("O6").minimum_spend_before_vat.subtotal_sum, "€ 5.520,00"},
        {NE.expected("O6").minimum_spend_before_vat.wrong_total, "€ 8.470,00"},
        {NE.expected("B1").forecast, "€ 11.726,00"},
        {NE.expected("B1").paid, "€ 3.000,00"},
        {NE.expected("B1").invoiced, "€ 3.000,00"},
        {NE.expected("B1").outstanding, "€ 0,00"},
        {NE.expected("B1").variance.amount, "€ 8.726,00"},
        {NE.expected("B2").forecast, "€ 11.900,00"},
        {NE.expected("B2").variance.amount, "€ 174,00"},
        {NE.expected("B3").forecast_under_every_preset, "€ 2.500,00"},
        {NE.expected("B4").naive_delta, "€ 246,00"}
      ]

      for {money, string} <- cases, do: assert(Format.money(money) == string)
    end

    test "every input amount renders as the nl-BE string it should" do
      venue_a = for line <- NE.venue_a().lines, line.amount, do: Format.money(line.amount)
      caterer_c = for line <- NE.caterer_c().lines, do: Format.money(line.amount)

      assert venue_a == [
               "€ 4.000,00",
               "€ 12,00",
               "€ 85,00",
               "€ 40,00",
               "€ 500,00",
               "€ 350,00"
             ]

      assert caterer_c == [
               "€ 60,00",
               "€ 30,00",
               "€ 25,00",
               "€ 150,00"
             ]

      assert Format.money(line(NE.venue_a(), 3).minimum_charge) == "€ 6.800,00"
      assert Format.money(line(NE.caterer_c(), 4).minimum_charge) == "€ 200,00"
      assert Format.money(NE.caterer_c().minimum_spend) == "€ 7.000,00"

      assert Format.money(NE.given("B2").invoices |> List.last() |> Map.fetch!(:amount)) ==
               "€ 8.900,00"
    end

    test "every amount anywhere in the fixture is a plausible, already-rounded euro figure" do
      data =
        [NE.venue_a(), NE.venue_b(), NE.caterer_c(), NE.attire_category()] ++
          Enum.map(NE.example_ids(), &NE.given/1) ++ Enum.map(NE.example_ids(), &NE.expected/1)

      amounts = collect_money(data, [])

      assert length(amounts) > 50

      for money <- amounts do
        assert money.currency == :EUR
        # Nothing in these examples reaches €12,000; a string-built amount would be 100×.
        assert Decimal.compare(money.amount, 0) in [:gt, :eq]
        assert Decimal.compare(money.amount, 12_000) == :lt
        # Every stated figure is whole cents; Format.money/1 rounding must be a no-op.
        assert Decimal.equal?(Decimal.round(money.amount, 2), money.amount)
      end
    end
  end

  describe "fixed_headcount/0 — the seam function" do
    setup do
      dinner = %Event{id: 1, name: "Dinner", sort_order: 0}
      %{snapshot: %Snapshot{events: [dinner]}, dinner: dinner, fun: NE.fixed_headcount()}
    end

    test "gives the shared counts for Dinner under Likely and Minimum", ctx do
      assert ctx.fun.(ctx.snapshot, %Preset{name: "Likely"}, ctx.dinner) ==
               %{adults: 72, children: 6, total: 78}

      assert ctx.fun.(ctx.snapshot, %Preset{name: "Minimum"}, ctx.dinner) ==
               %{adults: 60, children: 4, total: 64}

      for {_event, presets} <- NE.shared_headcount(), {_preset, counts} <- presets do
        assert counts.total == counts.adults + counts.children
      end
    end

    test "raises for Maximum, which the docs give no figure for", ctx do
      assert_raise ArgumentError, ~r/"Dinner" under preset "Maximum"/, fn ->
        ctx.fun.(ctx.snapshot, %Preset{name: "Maximum"}, ctx.dinner)
      end
    end

    test "raises for another event, and for :all_events", ctx do
      party = %Event{id: 2, name: "Party", sort_order: 1}

      assert_raise ArgumentError, ~r/"Party" under preset "Likely"/, fn ->
        ctx.fun.(ctx.snapshot, %Preset{name: "Likely"}, party)
      end

      assert_raise ArgumentError, ~r/:all_events under preset "Likely"/, fn ->
        ctx.fun.(ctx.snapshot, %Preset{name: "Likely"}, :all_events)
      end
    end
  end

  defp collect_money(%Elixir.Money{} = money, acc), do: [money | acc]
  defp collect_money(%Decimal{}, acc), do: acc
  defp collect_money(%{} = map, acc), do: map |> Map.values() |> collect_money(acc)
  defp collect_money(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect_money/2)
  defp collect_money(_other, acc), do: acc
end
