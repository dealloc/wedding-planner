defmodule WeddingPlanner.Valuation.OfferTest do
  @moduledoc """
  `WeddingPlanner.Valuation.Offer.total/4` and `breakdown/4` — the offer cost engine
  (`docs/modules/offers-and-comparison.md` `CST-30`…`CST-36`; `NFR-12`, `NFR-14`;
  `XC-42`, `D-26`; `DR-50`) over in-memory snapshots. Pure: no database.

  The normative examples O1–O6 run on `WeddingPlanner.NormativeSnapshots` through the
  `headcount:` test seam (`WeddingPlanner.NormativeExamples.fixed_headcount/0`) and are
  tagged `@tag example: "<id>"`. The property tests at the bottom compare the engine with
  a brute-force oracle written here that shares no code with the engine or
  `WeddingPlanner.Money`: it re-derives the selection from the rule text and computes the
  whole `CST-36` chain in exact integer arithmetic (cents × basis points, i.e. units of
  €10⁻⁶), turning the result into a `Decimal` only to compare it.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeSnapshots, as: NS
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Formula.Step
  alias WeddingPlanner.Valuation.Offer
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.FormulaPresenter

  # -- helpers -------------------------------------------------------------------------------

  defp eur(amount), do: WeddingPlanner.Money.new(amount)
  defp dec(string), do: Decimal.new(string)

  defp preset(name), do: Enum.find(Preset.defaults(), &(&1.name == name))

  # The normative examples' headcounts come through the test seam, said at the call site.
  defp seam_total(built, preset_name) do
    Offer.total(built.snapshot, built.offer, preset(preset_name),
      headcount: WeddingPlanner.NormativeExamples.fixed_headcount()
    )
  end

  defp seam_breakdown(built, preset_name) do
    Offer.breakdown(built.snapshot, built.offer, preset(preset_name),
      headcount: WeddingPlanner.NormativeExamples.fixed_headcount()
    )
  end

  defp money!(%Formula{total: {:money, money}}), do: money

  defp assert_money(%Money{} = actual, %Money{} = expected, what \\ "") do
    assert Money.equal?(actual, expected),
           "#{what} expected #{Money.to_string!(expected)}, got #{Money.to_string!(actual)} " <>
             "(#{Decimal.to_string(actual.amount)})"
  end

  # Steps compared structurally; money by `Money.equal?/2`, rates by `Decimal.equal?/2`.
  defp assert_steps(actual, expected) do
    assert length(actual) == length(expected),
           "expected #{length(expected)} steps, got #{length(actual)}:\n" <>
             inspect(actual, pretty: true)

    for {{a, e}, index} <- Enum.with_index(Enum.zip(actual, expected)) do
      assert %Step{} = a

      assert same_label?(a.label, e.label) and same_value?(a.value, e.value),
             "step #{index}: expected #{inspect(e)}, got #{inspect(a)}"
    end
  end

  defp same_label?(a, e) when is_binary(a) and is_binary(e), do: a == e

  defp same_label?(a, e) when is_list(a) and is_list(e),
    do: length(a) == length(e) and Enum.all?(Enum.zip(a, e), fn {x, y} -> same_segment?(x, y) end)

  defp same_label?(_a, _e), do: false

  defp same_segment?(a, e) when is_binary(a) and is_binary(e), do: a == e
  defp same_segment?(a, e), do: same_value?(a, e)

  defp same_value?({:money, %Money{} = a}, {:money, %Money{} = e}), do: Money.equal?(a, e)
  defp same_value?({:rate, %Decimal{} = a}, {:rate, %Decimal{} = e}), do: Decimal.equal?(a, e)
  defp same_value?({kind, a}, {kind, e}) when kind in [:count, :preset], do: a == e
  defp same_value?(_a, _e), do: false

  defp step(label, value), do: %Step{label: label, value: value}

  defp step_labels(%Formula{steps: steps}), do: Enum.map(steps, & &1.label)

  defp fixture_line(offer_map, number), do: Enum.find(offer_map.lines, &(&1.number == number))

  # -- O1, O2 (Venue A) ----------------------------------------------------------------------

  describe "Venue A (worked example, CST-36)" do
    setup do: %{built: NS.snapshot(:venue_a)}

    @tag example: "O1"
    test "O1: Likely → € 11.726, every line as the doc states it, the exact DR-50 formula",
         %{built: built} do
      formula = seam_total(built, "Likely")
      breakdown = seam_breakdown(built, "Likely")

      assert_money(money!(formula), NE.expected("O1").total)
      assert_money(breakdown.total, NE.expected("O1").total)
      assert %Formula{label: "Total"} = formula

      # Counted lines in DR-41 order: services in category order, then ad hoc by id.
      assert Enum.map(breakdown.lines, & &1.line.id) == [2, 3, 4, 1, 7]

      for result <- breakdown.lines do
        expected = fixture_line(NE.venue_a(), result.line.id).result["Likely"]
        assert_money(result.total, expected, "line #{result.line.id}")
      end

      # Lines that do not count (included, not wanted, unknown) are not priced at all.
      for number <- [5, 6, 8] do
        refute Enum.any?(breakdown.lines, &(&1.line.id == number))
      end

      assert_steps(formula.steps, [
        step("Headcount preset", {:preset, "Likely"}),
        step(
          [
            "Seating",
            " — (",
            {:count, 78},
            " attendees at Dinner − ",
            {:count, 50},
            " included) × ",
            {:money, eur(12)}
          ],
          {:money, eur(336)}
        ),
        step(
          ["Catering", " — ", {:count, 72}, " adults at Dinner × ", {:money, eur(85)}],
          {:money, eur(6120)}
        ),
        step("Catering — minimum charge applied", {:money, eur(6800)}),
        step(
          ["Catering", " — ", {:count, 6}, " children at Dinner × ", {:money, eur(40)}],
          {:money, eur(240)}
        ),
        step("Base price", {:money, eur(4000)}),
        step("Cleaning fee", {:money, eur(350)})
      ])

      # Rendered money has a non-breaking space after the euro sign (DR-17).
      presented = FormulaPresenter.present(formula)
      assert presented.total == "€ 11.726,00"
      assert presented.total_label == "Total"

      assert Enum.at(presented.steps, 1).label ==
               "Seating — (78 attendees at Dinner − 50 included) × € 12,00"
    end

    @tag example: "O2"
    test "O2: Minimum → € 11.478, every line as the doc's Minimum table states it",
         %{built: built} do
      formula = seam_total(built, "Minimum")
      breakdown = seam_breakdown(built, "Minimum")

      assert_money(money!(formula), NE.expected("O2").total)
      assert Enum.map(breakdown.lines, & &1.line.id) == [2, 3, 4, 1, 7]

      for result <- breakdown.lines do
        expected = fixture_line(NE.venue_a(), result.line.id).result["Minimum"]
        assert_money(result.total, expected, "line #{result.line.id}")
      end

      assert %{count: 64, included: 50, billable: 14} =
               Enum.find(breakdown.lines, &(&1.line.id == 2))

      assert %{count: 60, billable: 60, minimum_charge_applied: true} =
               Enum.find(breakdown.lines, &(&1.line.id == 3))

      refute breakdown.minimum_spend_applied
      assert is_nil(breakdown.minimum_spend)
    end
  end

  # -- O3 (Venue B) --------------------------------------------------------------------------

  @tag example: "O3"
  test "O3: Venue B's total excludes catering — total(B) = total(A) − lines 3 and 4, both variants" do
    venue_a = NS.snapshot(:venue_a)

    for variant <- [:no_line, :not_offered_line], preset_name <- ["Likely", "Minimum"] do
      built = NS.snapshot({:venue_b, variant})
      catering_id = Map.fetch!(built.services, "Catering").id
      breakdown = seam_breakdown(built, preset_name)

      refute Enum.any?(breakdown.lines, &(&1.line.service_id == catering_id)),
             "#{variant} #{preset_name}: a Catering line was priced"

      catering =
        Money.add!(
          fixture_line(NE.venue_a(), 3).result[preset_name],
          fixture_line(NE.venue_a(), 4).result[preset_name]
        )

      expected = Money.sub!(money!(seam_total(venue_a, preset_name)), catering)
      assert_money(money!(seam_total(built, preset_name)), expected, "#{variant} #{preset_name}")
      assert_money(breakdown.total, expected, "#{variant} #{preset_name} breakdown")
    end
  end

  # -- O4, O5, O6 (Caterer C) ----------------------------------------------------------------

  describe "Caterer C (VAT exclusive, mixed rates, minimums — CST-36)" do
    setup do: %{built: NS.snapshot(:caterer_c)}

    @tag example: "O4"
    test "O4: Likely → € 7.641,50; each line floored then grossed up on its own rate",
         %{built: built} do
      formula = seam_total(built, "Likely")
      breakdown = seam_breakdown(built, "Likely")
      expected = NE.expected("O4")

      assert_money(money!(formula), expected.total)
      assert_money(breakdown.line_sum, expected.line_sum)
      assert breakdown.minimum_spend_applied == expected.minimum_spend_applied
      assert_money(breakdown.minimum_spend, eur(7000))

      assert Enum.map(breakdown.lines, & &1.line.id) == [1, 2, 3, 4]

      for result <- breakdown.lines do
        %{subtotal: subtotal, total: total} =
          fixture_line(NE.caterer_c(), result.line.id).result["Likely"]

        assert_money(result.subtotal, subtotal, "line #{result.line.id} subtotal")
        assert_money(result.total, total, "line #{result.line.id} total")
      end

      rates = Enum.map(breakdown.lines, & &1.rate)

      assert Enum.zip_with(rates, ~w(0.12 0.12 0.21 0.21), &Decimal.equal?(&1, dec(&2))) ==
               [true, true, true, true]

      assert Enum.map(breakdown.lines, & &1.minimum_charge_applied) == [false, false, false, true]

      labels = step_labels(formula)
      refute "Sum of lines" in labels
      refute "Minimum spend applied" in labels

      assert_steps(formula.steps, [
        step("Headcount preset", {:preset, "Likely"}),
        step(
          ["Dinner catering", " — ", {:count, 72}, " adults at Dinner × ", {:money, eur(60)}],
          {:money, eur(4320)}
        ),
        step(
          ["Dinner catering", " — incl. ", {:rate, dec("0.12")}, " VAT"],
          {:money, eur(dec("4838.40"))}
        ),
        step(
          ["Dinner catering", " — ", {:count, 6}, " children at Dinner × ", {:money, eur(30)}],
          {:money, eur(180)}
        ),
        step(
          ["Dinner catering", " — incl. ", {:rate, dec("0.12")}, " VAT"],
          {:money, eur(dec("201.60"))}
        ),
        step(
          ["Drinks", " — ", {:count, 78}, " attendees at Dinner × ", {:money, eur(25)}],
          {:money, eur(1950)}
        ),
        step(
          ["Drinks", " — incl. ", {:rate, dec("0.21")}, " VAT"],
          {:money, eur(dec("2359.50"))}
        ),
        step("Travel", {:money, eur(150)}),
        step("Travel — minimum charge applied", {:money, eur(200)}),
        step(["Travel", " — incl. ", {:rate, dec("0.21")}, " VAT"], {:money, eur(242)})
      ])
    end

    @tag example: "O5"
    test "O5: Minimum → € 7.000,00; the sum € 6.344,40 is below the minimum spend",
         %{built: built} do
      formula = seam_total(built, "Minimum")
      breakdown = seam_breakdown(built, "Minimum")
      expected = NE.expected("O5")

      assert_money(money!(formula), expected.total)
      assert_money(breakdown.line_sum, expected.line_sum)
      assert breakdown.minimum_spend_applied == expected.minimum_spend_applied

      for result <- breakdown.lines do
        %{subtotal: subtotal, total: total} =
          fixture_line(NE.caterer_c(), result.line.id).result["Minimum"]

        assert_money(result.subtotal, subtotal, "line #{result.line.id} subtotal")
        assert_money(result.total, total, "line #{result.line.id} total")
      end

      assert_steps(Enum.take(formula.steps, -2), [
        step("Sum of lines", {:money, eur(dec("6344.40"))}),
        step("Minimum spend applied", {:money, eur(7000)})
      ])
    end

    @tag example: "O6"
    test "O6: the engine never produces either wrong-order figure (€ 8.046,50, € 8.470)",
         %{built: built} do
      %{sum_then_one_rate: sum_then_one_rate, minimum_spend_before_vat: before_vat} =
        NE.expected("O6")

      subtotals = fn preset_name ->
        Enum.map(NE.caterer_c().lines, & &1.result[preset_name].subtotal)
      end

      # Wrong order 1: sum the subtotals, then gross up once at 21 %.
      wrong_sum_then_rate =
        WeddingPlanner.Money.gross_up(
          WeddingPlanner.Money.sum(subtotals.("Likely")),
          sum_then_one_rate.rate
        )

      # Wrong order 2: apply the minimum spend before VAT, then gross up at 21 %.
      wrong_minimum_before_vat =
        WeddingPlanner.Money.gross_up(
          WeddingPlanner.Money.max(WeddingPlanner.Money.sum(subtotals.("Minimum")), eur(7000)),
          before_vat.rate
        )

      assert_money(wrong_sum_then_rate, eur(dec("8046.50")))
      assert_money(wrong_sum_then_rate, sum_then_one_rate.wrong_total)
      assert_money(wrong_minimum_before_vat, eur(8470))
      assert_money(wrong_minimum_before_vat, before_vat.wrong_total)

      likely = money!(seam_total(built, "Likely"))
      minimum = money!(seam_total(built, "Minimum"))

      assert_money(likely, sum_then_one_rate.correct_total)
      assert_money(minimum, before_vat.correct_total)

      for engine <- [likely, minimum], wrong <- [wrong_sum_then_rate, wrong_minimum_before_vat] do
        refute Money.equal?(engine, wrong)
      end
    end
  end

  # -- hand-built offers ---------------------------------------------------------------------

  @dinner %Event{id: 1, name: "Dinner", sort_order: 0}
  @party %Event{id: 2, name: "Party", sort_order: 1}

  # An offer (id 1, category 1) with `lines` on a snapshot holding Dinner and Party and two
  # services: Seating (id 10, nice-to-have) and Garden (id 11, not wanted).
  defp custom(offer_attrs, lines, overrides \\ []) do
    offer =
      struct!(
        %Offers.Offer{
          id: 1,
          category_id: 1,
          vendor_name: "Custom",
          status: :considering,
          vat_basis: :inclusive
        },
        offer_attrs
      )

    services = [
      %Service{
        id: 10,
        category_id: 1,
        name: "Seating",
        wanted_priority: :nice_to_have,
        sort_order: 0
      },
      %Service{
        id: 11,
        category_id: 1,
        name: "Garden",
        wanted_priority: :not_wanted,
        sort_order: 1
      }
    ]

    lines = Enum.map(lines, &%{&1 | offer_id: offer.id})

    %{
      snapshot: %Snapshot{
        events: [@dinner, @party],
        services: services,
        offers: [offer],
        offer_lines: lines,
        overrides: overrides
      },
      offer: offer
    }
  end

  defp line(id, attrs) do
    struct!(%OfferLine{id: id, state: :mandatory, basis: :flat, enabled: false}, attrs)
  end

  # A headcount function over `table` (event id → {adults, children}) that reports each
  # call to the test process. Passed through the seam at each call site below.
  defp counting_headcount(table) do
    test = self()

    fn %Snapshot{}, %Preset{}, %Event{id: id} ->
      send(test, {:headcount_called, id})
      {adults, children} = Map.fetch!(table, id)
      %{adults: adults, children: children, total: adults + children}
    end
  end

  describe "unrounded (NFR-14, CST-36)" do
    test "a gross-up with more than two decimals keeps full precision; the total is the unrounded sum" do
      built =
        custom(%{vat_basis: :exclusive, vat_rate_bp: 550}, [
          line(1,
            label: "Per head",
            basis: :per_attendee,
            event_id: 1,
            amount: eur(dec("10.01"))
          ),
          line(2, label: "Flat", amount: eur(dec("10.01")))
        ])

      headcount = counting_headcount(%{1 => {2, 1}})

      breakdown =
        Offer.breakdown(built.snapshot, built.offer, preset("Likely"), headcount: headcount)

      formula = Offer.total(built.snapshot, built.offer, preset("Likely"), headcount: headcount)

      # € 10,01 × 3 = € 30,03; × 1,055 = € 31,68165. € 10,01 × 1,055 = € 10,56055.
      [per_head, flat] = breakdown.lines
      assert_money(per_head.computed, eur(dec("30.03")))
      assert Decimal.equal?(per_head.total.amount, dec("31.68165"))
      assert Decimal.equal?(flat.total.amount, dec("10.56055"))
      assert Decimal.equal?(breakdown.total.amount, dec("42.2422"))
      assert Decimal.equal?(money!(formula).amount, dec("42.2422"))

      # The VAT steps carry the unrounded line totals.
      vat_values =
        for %Step{label: [_, " — incl. ", _, " VAT"], value: {:money, m}} <- formula.steps,
            do: m.amount

      assert Enum.zip_with(vat_values, ~w(31.68165 10.56055), &Decimal.equal?(&1, dec(&2))) ==
               [true, true]

      # Not the sum of the rounded steps (€ 31,68 + € 10,56 = € 42,24).
      refute Money.equal?(money!(formula), eur(dec("42.24")))
      assert FormulaPresenter.present(formula).total == "€ 42,24"
    end
  end

  describe "edge cases (CST-31, CST-32, CST-36, XC-42, DR-50)" do
    test "included ≥ count bills nobody (computed € 0); a minimum charge then applies" do
      built =
        custom(%{}, [
          line(1,
            service_id: 10,
            basis: :per_adult,
            event_id: 1,
            amount: eur(50),
            included_quantity: 10,
            minimum_charge: eur(100)
          ),
          line(2,
            label: "Exactly",
            basis: :per_child,
            event_id: 1,
            amount: eur(5),
            included_quantity: 3
          )
        ])

      headcount = counting_headcount(%{1 => {8, 3}})

      breakdown =
        Offer.breakdown(built.snapshot, built.offer, preset("Likely"), headcount: headcount)

      formula = Offer.total(built.snapshot, built.offer, preset("Likely"), headcount: headcount)

      [seating, exactly] = breakdown.lines
      assert %{count: 8, included: 10, billable: 0, minimum_charge_applied: true} = seating
      assert_money(seating.computed, eur(0))
      assert_money(seating.subtotal, eur(100))
      assert %{count: 3, included: 3, billable: 0, minimum_charge_applied: false} = exactly
      assert_money(exactly.total, eur(0))
      assert_money(money!(formula), eur(100))

      assert_steps(formula.steps, [
        step("Headcount preset", {:preset, "Likely"}),
        step(
          [
            "Seating",
            " — (",
            {:count, 8},
            " adults at Dinner − ",
            {:count, 10},
            " included) × ",
            {:money, eur(50)}
          ],
          {:money, eur(0)}
        ),
        step("Seating — minimum charge applied", {:money, eur(100)}),
        step(
          [
            "Exactly",
            " — (",
            {:count, 3},
            " children at Dinner − ",
            {:count, 3},
            " included) × ",
            {:money, eur(5)}
          ],
          {:money, eur(0)}
        )
      ])
    end

    test "an included quantity of 0 still shows the included form; a count of 1 is singular" do
      built =
        custom(%{}, [
          line(1,
            label: "Kids",
            basis: :per_child,
            event_id: 1,
            amount: eur(7),
            included_quantity: 0
          ),
          line(2, label: "Adult", basis: :per_adult, event_id: 1, amount: eur(9)),
          line(3, label: "Guest", basis: :per_attendee, event_id: 1, amount: eur(1))
        ])

      formula =
        Offer.total(built.snapshot, built.offer, preset("Likely"),
          headcount: counting_headcount(%{1 => {1, 1}})
        )

      assert_steps(formula.steps, [
        step("Headcount preset", {:preset, "Likely"}),
        step(
          [
            "Kids",
            " — (",
            {:count, 1},
            " child at Dinner − ",
            {:count, 0},
            " included) × ",
            {:money, eur(7)}
          ],
          {:money, eur(7)}
        ),
        step(
          ["Adult", " — ", {:count, 1}, " adult at Dinner × ", {:money, eur(9)}],
          {:money, eur(9)}
        ),
        step(
          ["Guest", " — ", {:count, 2}, " attendees at Dinner × ", {:money, eur(1)}],
          {:money, eur(2)}
        )
      ])
    end

    test "a minimum charge equal to the computed amount, or a minimum spend equal to the sum, is not applied" do
      built =
        custom(%{minimum_spend: eur(300)}, [
          line(1, label: "A", amount: eur(200), minimum_charge: eur(200)),
          line(2, label: "B", amount: eur(100))
        ])

      breakdown = Offer.breakdown(built.snapshot, built.offer, preset("Likely"))
      formula = Offer.total(built.snapshot, built.offer, preset("Likely"))

      assert Enum.map(breakdown.lines, & &1.minimum_charge_applied) == [false, false]
      refute breakdown.minimum_spend_applied
      assert_money(breakdown.total, eur(300))
      assert step_labels(formula) == ["A", "B"]
    end

    test "per-person lines on two events call the headcount function once per event" do
      built =
        custom(%{}, [
          line(1, label: "Adults", basis: :per_adult, event_id: 1, amount: eur(10)),
          line(2, label: "Children", basis: :per_child, event_id: 1, amount: eur(5)),
          line(3, label: "Party", basis: :per_attendee, event_id: 2, amount: eur(2)),
          line(4, label: "Party again", basis: :per_adult, event_id: 2, amount: eur(1)),
          line(5, label: "Flat", amount: eur(100))
        ])

      breakdown =
        Offer.breakdown(built.snapshot, built.offer, preset("Likely"),
          headcount: counting_headcount(%{1 => {4, 2}, 2 => {10, 1}})
        )

      assert_received {:headcount_called, 1}
      assert_received {:headcount_called, 2}
      refute_received {:headcount_called, _}

      assert Enum.map(breakdown.lines, & &1.count) == [4, 2, 11, 10, 1]

      assert Enum.map(breakdown.lines, &(&1.event && &1.event.name)) ==
               ["Dinner", "Dinner", "Party", "Party", nil]

      # 40 + 10 + 22 + 10 + 100
      assert_money(breakdown.total, eur(182))
    end

    test "an invalid counted line is one € 0 step, and no preset step if it was the only per-person line" do
      built =
        custom(%{vat_basis: :exclusive, vat_rate_bp: 2100}, [
          line(1,
            service_id: 10,
            basis: :per_adult,
            event_id: nil,
            amount: eur(85),
            minimum_charge: eur(500)
          ),
          line(2, label: "Flat", amount: eur(100))
        ])

      headcount = counting_headcount(%{})

      breakdown =
        Offer.breakdown(built.snapshot, built.offer, preset("Likely"), headcount: headcount)

      formula = Offer.total(built.snapshot, built.offer, preset("Likely"), headcount: headcount)

      refute_received {:headcount_called, _}

      [invalid, flat] = breakdown.lines

      assert %{
               invalid: true,
               event: nil,
               count: nil,
               included: nil,
               billable: nil,
               rate: nil,
               minimum_charge_applied: false
             } = invalid

      for amount <- [invalid.computed, invalid.subtotal, invalid.total],
          do: assert_money(amount, eur(0))

      refute flat.invalid
      assert_money(breakdown.total, eur(121))

      assert_steps(formula.steps, [
        step("Seating — invalid (its event was deleted), not counted", {:money, eur(0)}),
        step("Flat", {:money, eur(100)}),
        step(["Flat", " — incl. ", {:rate, dec("0.21")}, " VAT"], {:money, eur(121)})
      ])
    end

    test "a VAT-inclusive offer is never grossed up, even with a retained line rate (DR-41)" do
      built =
        custom(%{vat_basis: :inclusive}, [
          line(1, label: "Retained", amount: eur(100), vat_rate_bp: 2100)
        ])

      breakdown = Offer.breakdown(built.snapshot, built.offer, preset("Likely"))
      formula = Offer.total(built.snapshot, built.offer, preset("Likely"))

      assert [%{rate: nil} = result] = breakdown.lines
      assert_money(result.total, eur(100))
      assert_money(result.total, result.subtotal)
      assert_money(money!(formula), eur(100))
      assert_steps(formula.steps, [step("Retained", {:money, eur(100)})])
    end

    test "a VAT-exclusive line override wins over the offer default" do
      built =
        custom(%{vat_basis: :exclusive, vat_rate_bp: 2100}, [
          line(1, label: "Food", amount: eur(100), vat_rate_bp: 600),
          line(2, label: "Drinks", amount: eur(100))
        ])

      breakdown = Offer.breakdown(built.snapshot, built.offer, preset("Likely"))

      assert Enum.zip_with(breakdown.lines, ~w(0.06 0.21), &Decimal.equal?(&1.rate, dec(&2))) ==
               [true, true]

      assert_money(breakdown.total, eur(227))
    end

    test "no counted lines: € 0 and no steps; with a minimum spend, the sum/minimum pair" do
      empty = custom(%{}, [line(1, label: "Off", state: :optional, enabled: false)])
      formula = Offer.total(empty.snapshot, empty.offer, preset("Likely"))

      assert formula.steps == []
      assert_money(money!(formula), eur(0))

      with_minimum = custom(%{minimum_spend: eur(2500)}, [])
      formula = Offer.total(with_minimum.snapshot, with_minimum.offer, preset("Likely"))

      assert_steps(formula.steps, [
        step("Sum of lines", {:money, eur(0)}),
        step("Minimum spend applied", {:money, eur(2500)})
      ])

      assert_money(money!(formula), eur(2500))
    end

    test "a flat-only offer has no preset step" do
      built =
        custom(%{}, [
          line(1, label: "Base", amount: eur(4000)),
          line(2, label: "Fee", amount: eur(350))
        ])

      formula = Offer.total(built.snapshot, built.offer, preset("Likely"))

      assert step_labels(formula) == ["Base", "Fee"]
      assert_money(money!(formula), eur(4350))
    end

    test "a not-selected optional line and an included line produce no step and no amount" do
      built =
        custom(%{}, [
          # Garden is not wanted → optional line not selected.
          line(1, service_id: 11, state: :optional, amount: eur(500)),
          line(2, service_id: 10, state: :included, basis: nil, amount: nil),
          line(3, label: "Ad hoc off", state: :optional, amount: eur(70), enabled: false),
          line(4, label: "Ad hoc on", state: :optional, amount: eur(30), enabled: true)
        ])

      breakdown = Offer.breakdown(built.snapshot, built.offer, preset("Likely"))
      formula = Offer.total(built.snapshot, built.offer, preset("Likely"))

      assert Enum.map(breakdown.lines, & &1.line.id) == [4]
      assert step_labels(formula) == ["Ad hoc on"]
      assert_money(money!(formula), eur(30))

      # An override turns the not-wanted service on (CST-24, through Selection).
      overridden =
        custom(%{}, built.snapshot.offer_lines, [%{offer_id: 1, service_id: 11, wanted: true}])

      assert step_labels(Offer.total(overridden.snapshot, overridden.offer, preset("Likely"))) ==
               ["Garden", "Ad hoc on"]
    end

    test "a per-person line whose event is not in the snapshot is a bug and raises" do
      built =
        custom(%{}, [line(1, label: "Ghost", basis: :per_adult, event_id: 99, amount: eur(1))])

      assert_raise ArgumentError, ~r/event 99/, fn ->
        Offer.breakdown(built.snapshot, built.offer, preset("Likely"),
          headcount: counting_headcount(%{})
        )
      end
    end

    test "total/4 is built from breakdown/4: same total, same order of lines" do
      built = NS.snapshot(:caterer_c)

      for name <- ["Likely", "Minimum"] do
        assert_money(money!(seam_total(built, name)), seam_breakdown(built, name).total)
      end
    end
  end

  describe "invalid_lines/2 and needs_attention?/2 (XC-41, XC-42, DR-84)" do
    test "lists every invalid line, counted or not, in Selection.lines/2 order; flat lines never invalid" do
      built =
        custom(%{}, [
          # Mandatory per-person line, its event gone → invalid, and counted.
          line(1, service_id: 10, basis: :per_adult, event_id: nil, amount: eur(85)),
          # Optional per-person line of a not-wanted service, its event gone → invalid,
          # but not counted — XC-42's condition does not care either way (DR-84).
          line(2,
            service_id: 11,
            state: :optional,
            basis: :per_child,
            event_id: nil,
            amount: eur(40)
          ),
          # Flat lines are never invalid, whatever their event.
          line(3, label: "Cleaning fee", amount: eur(350))
        ])

      [mandatory_invalid, uncounted_invalid, _flat] = built.snapshot.offer_lines

      assert Offer.invalid_lines(built.snapshot, built.offer) ==
               [mandatory_invalid, uncounted_invalid]
    end

    test "needs_attention?/2 is true for a counted invalid line" do
      built =
        custom(%{}, [
          line(1, service_id: 10, basis: :per_adult, event_id: nil, amount: eur(85))
        ])

      assert Offer.needs_attention?(built.snapshot, built.offer)
    end

    test "needs_attention?/2 is true for an uncounted invalid line too (the matrix's condition)" do
      built =
        custom(%{}, [
          line(1,
            service_id: 11,
            state: :optional,
            basis: :per_child,
            event_id: nil,
            amount: eur(40)
          )
        ])

      assert Offer.needs_attention?(built.snapshot, built.offer)
    end

    test "needs_attention?/2 is false with no invalid lines" do
      built =
        custom(%{}, [
          line(1, service_id: 10, basis: :per_adult, event_id: 1, amount: eur(85)),
          line(2, label: "Flat", amount: eur(100))
        ])

      refute Offer.needs_attention?(built.snapshot, built.offer)
    end
  end

  describe "total/3 — the production path (Headcount.evaluate/3)" do
    test "counts an in-memory guest list: 2 accepted adults + 1 invited child, Likely → € 30" do
      built =
        custom(%{}, [
          line(1, label: "Per head", basis: :per_attendee, event_id: 1, amount: eur(10))
        ])

      snapshot = %{
        built.snapshot
        | persons: [
            %Person{id: 1, first_name: "A", age_category: :adult},
            %Person{id: 2, first_name: "B", age_category: :adult},
            %Person{id: 3, first_name: "C", age_category: :child}
          ],
          invitations: [
            %Invitation{id: 1, person_id: 1, event_id: 1, status: :accepted},
            %Invitation{id: 2, person_id: 2, event_id: 1, status: :accepted},
            %Invitation{id: 3, person_id: 3, event_id: 1, status: :invited}
          ]
      }

      formula = Offer.total(snapshot, built.offer, preset("Likely"))

      assert_money(money!(formula), eur(30))

      assert_steps(formula.steps, [
        step("Headcount preset", {:preset, "Likely"}),
        step(
          ["Per head", " — ", {:count, 3}, " attendees at Dinner × ", {:money, eur(10)}],
          {:money, eur(30)}
        )
      ])

      # Minimum counts only the certain (accepted) adults.
      assert_money(money!(Offer.total(snapshot, built.offer, preset("Minimum"))), eur(20))
    end
  end

  # -- property tests against a brute-force oracle ------------------------------------------

  describe "property: random offers against a brute-force oracle" do
    @describetag :property

    @seed {56, 36, 2026}
    @iterations 500

    test "totals and every line equal the exact-integer oracle; invariants hold (500 cases)" do
      :rand.seed(:exsss, @seed)

      for iteration <- 1..@iterations do
        spec = random_spec()

        try do
          check_case(spec)
        rescue
          error in ExUnit.AssertionError ->
            message =
              "seed #{inspect(@seed)}, iteration #{iteration}\n#{error.message}\nspec: " <>
                inspect(spec, pretty: true, limit: :infinity)

            reraise %{error | message: message}, __STACKTRACE__
        end
      end
    end
  end

  defp check_case(spec) do
    %{snapshot: snapshot, offer: offer, preset: preset, headcount: headcount} = to_structs(spec)
    oracle = oracle(spec)

    breakdown = Offer.breakdown(snapshot, offer, preset, headcount: headcount)
    formula = Offer.total(snapshot, offer, preset, headcount: headcount)

    # The selection and its order.
    assert Enum.map(breakdown.lines, & &1.line.id) == Enum.map(oracle.lines, & &1.id),
           "counted lines / order"

    # Every line, exactly.
    for {result, expected} <- Enum.zip(breakdown.lines, oracle.lines) do
      what = "line #{expected.id}"
      assert result.invalid == expected.invalid, what
      assert result.count == expected.count, what <> " count"
      assert result.billable == expected.billable, what <> " billable"
      assert result.minimum_charge_applied == expected.minimum_charge_applied, what
      assert_exact(result.computed, cents(expected.computed), what <> " computed")
      assert_exact(result.subtotal, cents(expected.subtotal), what <> " subtotal")
      assert_exact(result.total, micros(expected.total), what <> " total")

      case expected.rate_bp do
        nil -> assert is_nil(result.rate), what <> " rate"
        bp -> assert Decimal.equal?(result.rate, Decimal.new(1, bp, -4)), what <> " rate"
      end
    end

    assert_exact(breakdown.line_sum, micros(oracle.line_sum), "line sum")
    assert breakdown.minimum_spend_applied == oracle.minimum_spend_applied, "min spend applied"
    assert_exact(breakdown.total, micros(oracle.total), "total")
    assert_exact(money!(formula), micros(oracle.total), "formula total")

    # Invariants.
    assert Money.compare!(breakdown.total, breakdown.line_sum) != :lt, "total ≥ line sum"

    if offer.minimum_spend do
      assert Money.compare!(breakdown.total, offer.minimum_spend) != :lt, "total ≥ minimum spend"
    end

    for %{invalid: false, line: %{minimum_charge: %Money{} = minimum}} = result <- breakdown.lines do
      assert Money.compare!(result.subtotal, minimum) != :lt, "subtotal ≥ minimum charge"
    end

    if offer.vat_basis == :inclusive do
      for result <- breakdown.lines, do: assert(Money.equal?(result.total, result.subtotal))
    end

    # The formula's steps are exactly derivable from the breakdown.
    assert_steps_derivable(formula, breakdown, offer, preset)
  end

  defp assert_exact(%Money{currency: :EUR, amount: amount}, %Decimal{} = expected, what) do
    assert Decimal.equal?(amount, expected),
           "#{what}: expected #{Decimal.to_string(expected)}, got #{Decimal.to_string(amount)}"
  end

  defp cents(n), do: Decimal.new(1, n, -2)
  defp micros(n), do: Decimal.new(1, n, -6)

  defp assert_steps_derivable(formula, breakdown, offer, preset) do
    preset_step =
      if Enum.any?(breakdown.lines, &(not &1.invalid and &1.line.basis != :flat)),
        do: [{:preset, preset.name}],
        else: []

    line_values =
      Enum.flat_map(breakdown.lines, fn
        %{invalid: true} ->
          [{:money, WeddingPlanner.Money.new(0)}]

        result ->
          [{:money, result.computed}] ++
            if(result.minimum_charge_applied,
              do: [{:money, result.line.minimum_charge}],
              else: []
            ) ++
            if(offer.vat_basis == :exclusive, do: [{:money, result.total}], else: [])
      end)

    spend =
      if breakdown.minimum_spend_applied,
        do: [{:money, breakdown.line_sum}, {:money, offer.minimum_spend}],
        else: []

    expected = preset_step ++ line_values ++ spend
    actual = Enum.map(formula.steps, & &1.value)

    assert length(actual) == length(expected), "formula step count"

    for {a, e} <- Enum.zip(actual, expected) do
      assert same_value?(a, e), "formula step #{inspect(a)} vs #{inspect(e)}"
    end
  end

  # -- the oracle: rule text, exact integers -------------------------------------------------
  #
  # Money is integer cents; a rate is integer basis points; a line total is
  # cents × (10000 + bp) (exclusive) or cents × 10000 (inclusive) — units of €10⁻⁶.

  defp oracle(spec) do
    services = Map.new(spec.services, &{&1.id, &1})

    counted =
      spec.lines
      |> Enum.filter(&counts?(&1, spec, services))
      |> Enum.sort_by(fn line ->
        case line.service_id do
          nil -> {1, 0, 0, line.id}
          id -> {0, services[id].sort_order, id, line.id}
        end
      end)

    lines = Enum.map(counted, &oracle_line(&1, spec))
    line_sum = lines |> Enum.map(& &1.total) |> Enum.sum()

    {total, applied} =
      case spec.offer.minimum_spend do
        nil -> {line_sum, false}
        cents -> if line_sum < cents * 10_000, do: {cents * 10_000, true}, else: {line_sum, false}
      end

    %{lines: lines, line_sum: line_sum, total: total, minimum_spend_applied: applied}
  end

  # CST-21/22/24: mandatory always; included / not offered / unknown never; optional with a
  # service iff an override (for this offer) says so, else iff must-have or nice-to-have;
  # optional ad hoc iff its toggle is on.
  defp counts?(%{state: :mandatory}, _spec, _services), do: true
  defp counts?(%{state: state}, _, _) when state in [:included, :not_offered, :unknown], do: false
  defp counts?(%{state: :optional, service_id: nil, enabled: enabled}, _, _), do: enabled

  defp counts?(%{state: :optional, service_id: service_id}, spec, services) do
    case Enum.find(spec.overrides, &(&1.offer_id == 1 and &1.service_id == service_id)) do
      %{wanted: wanted} -> wanted
      nil -> services[service_id].priority in [:must_have, :nice_to_have]
    end
  end

  defp oracle_line(%{basis: basis, event_id: nil} = line, _spec) when basis != :flat do
    %{
      id: line.id,
      invalid: true,
      count: nil,
      billable: nil,
      computed: 0,
      subtotal: 0,
      minimum_charge_applied: false,
      rate_bp: nil,
      total: 0
    }
  end

  defp oracle_line(line, spec) do
    count =
      case line.basis do
        :flat ->
          1

        basis ->
          {adults, children} = Map.fetch!(spec.counts, {line.event_id, spec.preset})

          case basis do
            :per_adult -> adults
            :per_child -> children
            :per_attendee -> adults + children
          end
      end

    billable = if line.basis == :flat, do: 1, else: Kernel.max(0, count - (line.included || 0))
    computed = line.amount * billable

    {subtotal, applied} =
      if line.minimum_charge != nil and computed < line.minimum_charge,
        do: {line.minimum_charge, true},
        else: {computed, false}

    rate_bp =
      if spec.offer.vat_basis == :exclusive, do: line.rate_bp || spec.offer.rate_bp, else: nil

    total = if rate_bp, do: subtotal * (10_000 + rate_bp), else: subtotal * 10_000

    %{
      id: line.id,
      invalid: false,
      count: count,
      billable: billable,
      computed: computed,
      subtotal: subtotal,
      minimum_charge_applied: applied,
      rate_bp: rate_bp,
      total: total
    }
  end

  # -- random input: a plain spec (integers), then structs built from it ---------------------

  defp pick(list), do: Enum.at(list, :rand.uniform(length(list)) - 1)
  defp chance(n), do: :rand.uniform(n) == 1

  @preset_names ["Minimum", "Likely", "Maximum", "Custom"]

  defp random_bp, do: pick([0, 600, 1200, 2100, 550, :rand.uniform(10_001) - 1])

  defp random_cents do
    case :rand.uniform(4) do
      1 -> 0
      2 -> :rand.uniform(100) * 100
      _ -> :rand.uniform(250_000)
    end
  end

  defp random_spec do
    event_ids = Enum.take_random(1..6, :rand.uniform(3))

    services =
      for id <- Enum.take_random(100..120, :rand.uniform(5)) do
        %{
          id: id,
          priority: pick([:must_have, :nice_to_have, :not_wanted]),
          sort_order: :rand.uniform(4)
        }
      end

    service_ids = Enum.map(services, & &1.id)
    exclusive? = chance(2)

    offer = %{
      vat_basis: if(exclusive?, do: :exclusive, else: :inclusive),
      rate_bp: if(exclusive?, do: random_bp()),
      minimum_spend: if(chance(2), do: random_cents() * :rand.uniform(4))
    }

    lines =
      for id <- Enum.take_random(1..60, :rand.uniform(9) - 1),
          do: random_line(id, service_ids, event_ids)

    noise_lines =
      for id <- Enum.take_random(61..80, :rand.uniform(3) - 1),
          do: random_line(id, service_ids, event_ids)

    overrides =
      for service_id <- service_ids, chance(3) do
        %{offer_id: pick([1, 1, 2]), service_id: service_id, wanted: chance(2)}
      end
      |> Enum.uniq_by(&{&1.offer_id, &1.service_id})

    counts =
      for event_id <- event_ids, name <- @preset_names, into: %{} do
        {{event_id, name}, {:rand.uniform(121) - 1, :rand.uniform(21) - 1}}
      end

    %{
      event_ids: event_ids,
      services: services,
      offer: offer,
      lines: lines,
      noise_lines: noise_lines,
      overrides: overrides,
      counts: counts,
      preset: pick(@preset_names)
    }
  end

  defp random_line(id, service_ids, event_ids) do
    ad_hoc? = chance(3)
    state = if ad_hoc?, do: pick([:mandatory, :optional]), else: pick(OfferLine.states())
    priced? = state in [:mandatory, :optional]
    basis = if priced?, do: pick(OfferLine.bases())
    per_person? = basis in [:per_adult, :per_child, :per_attendee]

    %{
      id: id,
      service_id: if(ad_hoc?, do: nil, else: pick(service_ids)),
      state: state,
      basis: basis,
      # Occasionally invalid: a per-person line whose event was deleted (XC-41).
      event_id: if(per_person? and not chance(8), do: pick(event_ids)),
      amount: if(priced?, do: random_cents()),
      included: if(per_person? and chance(2), do: :rand.uniform(80) - 1),
      minimum_charge: if(priced? and chance(3), do: random_cents() * :rand.uniform(3)),
      # A retained override is possible on an inclusive offer too (DR-41).
      rate_bp: if(priced? and chance(3), do: random_bp()),
      enabled: ad_hoc? and state == :optional and chance(2)
    }
  end

  defp to_structs(spec) do
    events = for id <- spec.event_ids, do: %Event{id: id, name: "Event #{id}", sort_order: id}

    services =
      for s <- spec.services do
        %Service{
          id: s.id,
          category_id: 1,
          name: "Service #{s.id}",
          wanted_priority: s.priority,
          sort_order: s.sort_order
        }
      end

    offer = %Offers.Offer{
      id: 1,
      category_id: 1,
      vendor_name: "Random",
      status: :considering,
      vat_basis: spec.offer.vat_basis,
      vat_rate_bp: spec.offer.rate_bp,
      minimum_spend: money_or_nil(spec.offer.minimum_spend)
    }

    lines =
      Enum.map(spec.lines, &offer_line(&1, 1)) ++ Enum.map(spec.noise_lines, &offer_line(&1, 2))

    counts = spec.counts

    headcount = fn %Snapshot{}, %Preset{name: name}, %Event{id: id} ->
      {adults, children} = Map.fetch!(counts, {id, name})
      %{adults: adults, children: children, total: adults + children}
    end

    %{
      snapshot: %Snapshot{
        events: events,
        services: services,
        offers: [offer],
        offer_lines: Enum.shuffle(lines),
        overrides: spec.overrides
      },
      offer: offer,
      preset: %Preset{name: spec.preset},
      headcount: headcount
    }
  end

  defp offer_line(line, offer_id) do
    %OfferLine{
      id: line.id,
      offer_id: offer_id,
      service_id: line.service_id,
      label: if(is_nil(line.service_id), do: "Ad hoc #{line.id}"),
      state: line.state,
      basis: line.basis,
      event_id: line.event_id,
      amount: money_or_nil(line.amount),
      included_quantity: line.included,
      minimum_charge: money_or_nil(line.minimum_charge),
      vat_rate_bp: line.rate_bp,
      enabled: line.enabled
    }
  end

  defp money_or_nil(nil), do: nil
  defp money_or_nil(cents), do: WeddingPlanner.Money.new(Decimal.new(1, cents, -2))
end
