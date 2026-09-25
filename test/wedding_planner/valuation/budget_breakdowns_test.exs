defmodule WeddingPlanner.Valuation.BudgetBreakdownsTest do
  @moduledoc """
  `WeddingPlanner.Valuation.BudgetBreakdowns` — `BUD-07`'s by-event and per-guest
  breakdowns (`DR-73`, `DR-74`, `BUD-08`, `HC-03`, `HC-08`) over `Budget.overall/2`'s
  result, through the real headcount, offer, invoice and budget engines and in-memory
  guests (`WeddingPlanner.NormativeInvoices.shared_guests/0`,
  `WeddingPlanner.BudgetSnapshots`). No `headcount:` seam anywhere in this file.

  The property test's generator is written here (task 80's shape, extended with events,
  guests, per-person lines, minimum charges, minimum spends and VAT); its check needs no
  oracle — the invariant is that the rows add up to `Budget`'s own forecast exactly.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.BudgetSnapshots
  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Invoices.InvoiceLine
  alias WeddingPlanner.NormativeInvoices
  alias WeddingPlanner.NormativeSnapshots
  alias WeddingPlanner.Offers.FrozenService
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Settings
  alias WeddingPlanner.Valuation.Budget
  alias WeddingPlanner.Valuation.BudgetBreakdowns
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Snapshot

  # -- helpers -------------------------------------------------------------------------------

  defp eur(amount), do: WeddingPlanner.Money.new(amount)
  defp dec(string), do: eur(Decimal.new(string))

  defp likely, do: NormativeInvoices.preset("Likely")
  defp minimum, do: NormativeInvoices.preset("Minimum")

  defp money(%Formula{total: {:money, %Money{} = money}}), do: money

  defp assert_money(actual, expected, what) do
    assert Money.equal?(actual, expected),
           "#{what}: expected #{Money.to_string!(expected)}, got #{Money.to_string!(actual)}"
  end

  # Steps with every %Money{} replaced by its normalised amount, so `€ 336` and
  # `€ 336.00` compare equal and a failure prints readable amounts.
  defp norm(%Money{amount: amount}),
    do: {:eur, amount |> Decimal.normalize() |> Decimal.to_string(:normal)}

  defp norm(%WeddingPlanner.Valuation.Formula.Step{label: label, value: value}),
    do: {norm(label), norm(value)}

  defp norm(list) when is_list(list), do: Enum.map(list, &norm/1)
  defp norm(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> norm() |> List.to_tuple()
  defp norm(other), do: other

  defp e(amount) when is_integer(amount), do: norm(eur(amount))
  defp e(amount) when is_binary(amount), do: norm(dec(amount))

  defp preset_step(name), do: {"Headcount preset", {:preset, name}}

  defp rows(snapshot, preset) do
    overall = Budget.overall(snapshot, preset)
    {BudgetBreakdowns.by_event(snapshot, overall), overall}
  end

  defp row(rows, :general), do: Enum.find(rows, &(&1.event == :general))
  defp row(rows, name), do: Enum.find(rows, &match?(%{event: %Event{name: ^name}}, &1))

  defp labels(rows),
    do: Enum.map(rows, &if(&1.event == :general, do: "General", else: &1.event.name))

  defp sum_rows(rows), do: rows |> Enum.map(& &1.amount) |> WeddingPlanner.Money.sum()

  defp assert_exact(rows, overall, what) do
    assert WeddingPlanner.Money.compare(sum_rows(rows), money(overall.forecast)) == :eq,
           "#{what}: rows sum to #{Money.to_string!(sum_rows(rows))}, forecast is " <>
             Money.to_string!(money(overall.forecast))
  end

  defp by_category(row),
    do: Enum.map(row.by_category, &{&1.category.name, norm(&1.amount)})

  defp put_line(snapshot, %OfferLine{} = line),
    do: Snapshot.apply(snapshot, {:put, :offer_lines, line})

  defp put_invoice(snapshot, id, category_id, offer_id, label, amount) do
    invoice = %Invoice{
      id: id,
      category_id: category_id,
      offer_id: offer_id,
      label: label,
      invoice_date: ~D[2027-01-10]
    }

    line = %InvoiceLine{id: id * 100, invoice_id: id, label: label, amount: amount}
    Snapshot.apply(snapshot, [{:put, :invoices, invoice}, {:put, :invoice_lines, line}])
  end

  defp ad_hoc_per_attendee(id, offer, label, event_id, amount) do
    %OfferLine{
      id: id,
      offer_id: offer.id,
      label: label,
      state: :mandatory,
      basis: :per_attendee,
      event_id: event_id,
      amount: amount
    }
  end

  # The Venue A rows of B1 under Likely, as the doc's O1 lines (DR-50 extend labels).
  defp venue_dinner_steps_likely do
    [
      {[
         "Venue",
         " — ",
         "Venue A",
         " — ",
         "Seating",
         " — (",
         {:count, 78},
         " attendees at Dinner − ",
         {:count, 50},
         " included) × ",
         {:money, e(12)}
       ], {:money, e(336)}},
      {[
         "Venue",
         " — ",
         "Venue A",
         " — ",
         "Catering",
         " — ",
         {:count, 72},
         " adults at Dinner × ",
         {:money, e(85)}
       ], {:money, e(6_800)}},
      {[
         "Venue",
         " — ",
         "Venue A",
         " — ",
         "Catering",
         " — ",
         {:count, 6},
         " children at Dinner × ",
         {:money, e(40)}
       ], {:money, e(240)}}
    ]
  end

  defp venue_general_steps do
    [
      {["Venue", " — ", "Venue A", " — ", "Base price"], {:money, e(4_000)}},
      {["Venue", " — ", "Venue A", " — ", "Cleaning fee"], {:money, e(350)}}
    ]
  end

  # -- 1. Venue A by event --------------------------------------------------------------------

  describe "Venue A by event (B1 snapshot, real headcount)" do
    test "Likely: Dinner = Seating + Catering adults (minimum charge) + children; General = flat lines" do
      %{snapshot: snapshot} = BudgetSnapshots.b1()
      {rows, overall} = rows(snapshot, likely())

      assert labels(rows) == ["Dinner", "General"]

      dinner = row(rows, "Dinner")
      assert_money(dinner.amount, eur(7_376), "Dinner")
      assert dinner.formula.label == "Dinner"
      assert norm(dinner.formula.steps) == [preset_step("Likely") | venue_dinner_steps_likely()]
      assert norm(dinner.formula.total) == {:money, e(7_376)}

      general = row(rows, :general)
      assert_money(general.amount, eur(4_350), "General")
      assert general.formula.label == "General"
      assert norm(general.formula.steps) == venue_general_steps()

      assert_money(sum_rows(rows), eur(11_726), "Σ")
      assert_exact(rows, overall, "B1 Likely")
    end

    test "Minimum: Dinner €7,128 (168 + 6,800 + 160), General €4,350, Σ €11,478" do
      %{snapshot: snapshot} = BudgetSnapshots.b1()
      {rows, overall} = rows(snapshot, minimum())

      dinner = row(rows, "Dinner")
      assert_money(dinner.amount, eur(7_128), "Dinner")
      assert hd(norm(dinner.formula.steps)) == preset_step("Minimum")

      assert Enum.map(tl(dinner.formula.steps), &norm(&1.value)) ==
               [{:money, e(168)}, {:money, e(6_800)}, {:money, e(160)}]

      assert_money(row(rows, :general).amount, eur(4_350), "General")
      assert_money(sum_rows(rows), eur(11_478), "Σ")
      assert_exact(rows, overall, "B1 Minimum")
    end
  end

  # -- 2. invoiced source ---------------------------------------------------------------------

  describe "an invoiced forecast goes to General" do
    test "B2 (invoicing complete): the whole €11,900 in General, Dinner €0 but present" do
      %{snapshot: snapshot} = BudgetSnapshots.b2()

      for preset <- [likely(), minimum()] do
        {rows, overall} = rows(snapshot, preset)

        assert labels(rows) == ["Dinner", "General"]
        dinner = row(rows, "Dinner")
        assert_money(dinner.amount, eur(0), "Dinner")
        assert dinner.formula.steps == []
        assert dinner.by_category == []

        general = row(rows, :general)
        assert_money(general.amount, eur(11_900), "General")

        assert norm(general.formula.steps) == [
                 {["Venue", " — ", "Venue A", " — invoiced total"], {:money, e(11_900)}}
               ]

        assert_exact(rows, overall, "B2 #{preset.name}")
      end
    end

    test "invoiced above committed (source :invoiced): the offer's forecast in General" do
      %{snapshot: snapshot, offer: venue_a} = BudgetSnapshots.b1()
      snapshot = put_invoice(snapshot, 50, venue_a.category_id, venue_a.id, "Extra", eur(12_000))
      {rows, overall} = rows(snapshot, likely())

      assert [%{source: :invoiced}] = hd(overall.categories).confirmed_offers
      assert_money(row(rows, "Dinner").amount, eur(0), "Dinner")

      assert norm(row(rows, :general).formula.steps) == [
               {["Venue", " — ", "Venue A", " — invoiced total"], {:money, e(15_000)}}
             ]

      assert_exact(rows, overall, ":invoiced")
    end
  end

  # -- 3. minimum spend uplift ----------------------------------------------------------------

  # Caterer C confirmed with its frozen selection (what `Selection.freeze/2` gives) and the
  # shared Dinner guests.
  defp caterer_c_confirmed do
    %{snapshot: snapshot, offer: offer} = NormativeSnapshots.snapshot(:caterer_c)

    frozen =
      snapshot
      |> Selection.freeze(offer)
      |> Enum.with_index(1)
      |> Enum.map(fn {service_id, n} ->
        %FrozenService{id: 900 + n, offer_id: offer.id, service_id: service_id}
      end)

    {persons, invitations} = NormativeInvoices.shared_guests()

    %{
      snapshot
      | offers: [%{offer | status: :confirmed}],
        frozen_services: frozen,
        persons: persons,
        invitations: invitations,
        headcount_presets: Preset.defaults()
    }
  end

  describe "a minimum-spend uplift goes to General" do
    test "Caterer C under Minimum: Dinner €6,102.40; General = Travel €242 + uplift €655.60" do
      {rows, overall} = rows(caterer_c_confirmed(), minimum())

      dinner = row(rows, "Dinner")
      assert_money(dinner.amount, dec("6102.40"), "Dinner")

      assert norm(dinner.formula.steps) == [
               preset_step("Minimum"),
               {[
                  "Catering",
                  " — ",
                  "Caterer C",
                  " — ",
                  "Dinner catering",
                  " — ",
                  {:count, 60},
                  " adults at Dinner × ",
                  {:money, e(60)}
                ], {:money, e("4032.00")}},
               {[
                  "Catering",
                  " — ",
                  "Caterer C",
                  " — ",
                  "Dinner catering",
                  " — ",
                  {:count, 4},
                  " children at Dinner × ",
                  {:money, e(30)}
                ], {:money, e("134.40")}},
               {[
                  "Catering",
                  " — ",
                  "Caterer C",
                  " — ",
                  "Drinks",
                  " — ",
                  {:count, 64},
                  " attendees at Dinner × ",
                  {:money, e(25)}
                ], {:money, e("1936.00")}}
             ]

      general = row(rows, :general)
      assert_money(general.amount, dec("897.60"), "General")

      assert norm(general.formula.steps) == [
               {["Catering", " — ", "Caterer C", " — ", "Travel"], {:money, e("242.00")}},
               {["Catering", " — ", "Caterer C", " — minimum spend applied"],
                {:money, e("655.60")}}
             ]

      assert_money(sum_rows(rows), eur(7_000), "Σ")
      assert_exact(rows, overall, "Caterer C Minimum")
    end
  end

  # -- 4. fallback branches -------------------------------------------------------------------

  describe "fallback branches (BudgetSnapshots.branches/0)" do
    test "pick by its lines, invoiced-complete offer, unlinked-invoice winner → as DR-73 says" do
      %{snapshot: snapshot} = BudgetSnapshots.branches()
      {rows, overall} = rows(snapshot, likely())

      dinner = row(rows, "Dinner")
      assert_money(dinner.amount, eur(8_156), "Dinner")

      assert norm(dinner.formula.steps) ==
               [preset_step("Likely")] ++
                 venue_dinner_steps_likely() ++
                 [
                   {[
                      "Flowers",
                      " — ",
                      "Florist F",
                      " — ",
                      "Table flowers",
                      " — ",
                      {:count, 78},
                      " attendees at Dinner × ",
                      {:money, e(10)}
                    ], {:money, e(780)}}
                 ]

      general = row(rows, :general)
      assert_money(general.amount, eur(9_750), "General")

      assert norm(general.formula.steps) ==
               venue_general_steps() ++
                 [
                   {["Photography", " — ", "Photographer P", " — invoiced total"],
                    {:money, e(1_800)}},
                   {["Flowers", " — ", "Florist F", " — ", "Arch"], {:money, e(500)}},
                   {["Attire", " — invoice ", "Tailor invoice"], {:money, e(3_100)}}
                 ]

      assert_money(sum_rows(rows), eur(17_906), "Σ")
      assert_exact(rows, overall, "branches")
    end

    test "a winning target → General" do
      %{snapshot: snapshot, invoices: %{"Tailor invoice" => tailor}} = BudgetSnapshots.branches()

      snapshot = %{
        snapshot
        | invoices: Enum.reject(snapshot.invoices, &(&1.id == tailor.id)),
          invoice_lines: Enum.reject(snapshot.invoice_lines, &(&1.invoice_id == tailor.id))
      }

      {rows, overall} = rows(snapshot, likely())
      general = row(rows, :general)

      assert {["Attire", " — target"], {:money, e(2_500)}} in norm(general.formula.steps)

      refute Enum.any?(
               norm(general.formula.steps),
               &match?({["Attire", " — invoice " | _], _}, &1)
             )

      assert_money(general.amount, eur(9_750 - 3_100 + 2_500), "General")
      assert_exact(rows, overall, "target")
    end

    test "a pick beaten by unlinked invoices: the invoices → General, none of the pick's lines" do
      %{snapshot: snapshot, categories: %{"Flowers" => flowers}} = BudgetSnapshots.branches()
      snapshot = put_invoice(snapshot, 40, flowers.id, nil, "Big bouquet", eur(2_000))
      {rows, overall} = rows(snapshot, likely())

      assert Enum.find(overall.categories, &(&1.category.id == flowers.id)).fallback_winner ==
               :unlinked_invoices

      dinner = row(rows, "Dinner")
      assert_money(dinner.amount, eur(7_376), "Dinner")
      assert by_category(dinner) == [{"Venue", e(7_376)}]

      flowers_steps =
        row(rows, :general).formula.steps
        |> norm()
        |> Enum.filter(&match?({["Flowers" | _], _}, &1))

      assert flowers_steps == [
               {["Flowers", " — invoice ", "Florist deposit"], {:money, e(300)}},
               {["Flowers", " — invoice ", "Big bouquet"], {:money, e(2_000)}}
             ]

      assert_exact(rows, overall, "pick loses")
    end

    test "unlinked invoices beside confirmed offers → General, after the offers" do
      %{snapshot: snapshot, categories: %{"Photography" => photography}} =
        BudgetSnapshots.branches()

      snapshot = put_invoice(snapshot, 41, photography.id, nil, "Prints", eur(75))
      {rows, overall} = rows(snapshot, likely())

      photography_steps =
        row(rows, :general).formula.steps
        |> norm()
        |> Enum.filter(&match?({["Photography" | _], _}, &1))

      assert photography_steps == [
               {["Photography", " — ", "Photographer P", " — invoiced total"],
                {:money, e(1_800)}},
               {["Photography", " — invoice ", "Prints"], {:money, e(75)}}
             ]

      assert_money(row(rows, :general).amount, eur(9_750 + 75), "General")
      assert_exact(rows, overall, "unlinked beside confirmed")
    end
  end

  # -- 5. ad hoc per-person line (DR-73, W12 Q3) ------------------------------------------------

  describe "an ad hoc per-person line (DR-73, W12 Q3)" do
    test "goes to its event, like a service line — not to General" do
      %{snapshot: snapshot, offer: venue_a} = BudgetSnapshots.b1()
      [dinner_event] = snapshot.events

      snapshot =
        put_line(
          snapshot,
          ad_hoc_per_attendee(260, venue_a, "Service charge", dinner_event.id, eur(5))
        )

      {rows, overall} = rows(snapshot, likely())
      dinner = row(rows, "Dinner")

      assert_money(dinner.amount, eur(7_376 + 390), "Dinner")

      assert List.last(norm(dinner.formula.steps)) ==
               {[
                  "Venue",
                  " — ",
                  "Venue A",
                  " — ",
                  "Service charge",
                  " — ",
                  {:count, 78},
                  " attendees at Dinner × ",
                  {:money, e(5)}
                ], {:money, e(390)}}

      assert norm(row(rows, :general).formula.steps) == venue_general_steps()
      assert_exact(rows, overall, "ad hoc per-person")
    end
  end

  # -- 6. invalid line ------------------------------------------------------------------------

  describe "an invalid line (XC-42)" do
    test "contributes nothing — no step in any row" do
      %{snapshot: snapshot, offer: venue_a} = BudgetSnapshots.b1()
      {plain, _overall} = rows(snapshot, likely())

      snapshot = put_line(snapshot, ad_hoc_per_attendee(270, venue_a, "Ghost", nil, eur(5)))
      {rows, overall} = rows(snapshot, likely())

      # Not vacuous: the budget does count the line, as invalid.
      [%{confirmed_offers: [contribution]}] = overall.categories
      assert Enum.any?(contribution.breakdown.lines, &(&1.invalid and &1.name == "Ghost"))

      assert rows == plain
      assert_exact(rows, overall, "invalid")
    end
  end

  # -- 7. rows --------------------------------------------------------------------------------

  describe "rows" do
    test "every event in snapshot.events (EVT-04) order even at €0, General last; by_category non-zero only" do
      %{snapshot: snapshot, offers: %{"Venue A" => venue_a}} = BudgetSnapshots.branches()
      [dinner_event] = snapshot.events
      ceremony = %Event{id: 2, name: "Ceremony", sort_order: 0}
      party = %Event{id: 3, name: "Party", sort_order: 2}

      snapshot =
        %{snapshot | events: [ceremony, %{dinner_event | sort_order: 1}, party]}
        |> put_line(ad_hoc_per_attendee(280, venue_a, "Party snack", party.id, eur(5)))

      {rows, overall} = rows(snapshot, likely())

      assert labels(rows) == ["Ceremony", "Dinner", "Party", "General"]

      ceremony_row = row(rows, "Ceremony")
      assert ceremony_row.event == ceremony
      assert_money(ceremony_row.amount, eur(0), "Ceremony")
      assert ceremony_row.formula.steps == []
      assert ceremony_row.by_category == []

      # A €0 contribution is a step, but not a by_category entry.
      party_row = row(rows, "Party")
      assert_money(party_row.amount, eur(0), "Party")

      assert norm(party_row.formula.steps) == [
               preset_step("Likely"),
               {[
                  "Venue",
                  " — ",
                  "Venue A",
                  " — ",
                  "Party snack",
                  " — ",
                  {:count, 0},
                  " attendees at Party × ",
                  {:money, e(5)}
                ], {:money, e(0)}}
             ]

      assert party_row.by_category == []

      assert by_category(row(rows, "Dinner")) == [{"Venue", e(7_376)}, {"Flowers", e(780)}]

      assert by_category(row(rows, :general)) == [
               {"Venue", e(4_350)},
               {"Photography", e(1_800)},
               {"Flowers", e(500)},
               {"Attire", e(3_100)}
             ]

      assert_exact(rows, overall, "rows")
    end

    test "no events: only General, carrying the whole forecast" do
      %{snapshot: snapshot} = BudgetSnapshots.b3()
      {rows, overall} = rows(snapshot, likely())

      assert [%{event: :general} = general] = rows
      assert norm(general.formula.steps) == [{["Attire", " — target"], {:money, e(2_500)}}]
      assert_exact(rows, overall, "B3")
    end
  end

  # -- 8. per guest ---------------------------------------------------------------------------

  defp per_guest_steps(preset, forecast, persons) do
    [
      preset_step(preset),
      {"Forecast", {:money, norm(forecast)}},
      {"Distinct persons counted (all events)", {:count, persons}}
    ]
  end

  describe "per guest (DR-74, HC-03, HC-08)" do
    test "B1 Likely: 78 distinct persons; €11,726 ÷ 78 unrounded; formula steps exact" do
      %{snapshot: snapshot} = BudgetSnapshots.b1()
      overall = Budget.overall(snapshot, likely())
      result = BudgetBreakdowns.per_guest(snapshot, overall)

      assert result.preset == likely()
      assert result.persons == 78

      assert {:ok, %Formula{label: "Per guest"} = formula} = result.overall
      expected = Money.div!(eur(11_726), 78)
      assert Money.equal?(money(formula), expected)
      refute Money.equal?(money(formula), Money.round(expected))
      assert norm(formula.steps) == per_guest_steps("Likely", eur(11_726), 78)

      assert [%{category: %Category{name: "Venue"}, figure: {:ok, venue}}] = result.categories
      assert Money.equal?(money(venue), expected)
      assert norm(venue.steps) == per_guest_steps("Likely", eur(11_726), 78)
    end

    test "a person counted for two events counts once (not one event's count, not the sum)" do
      %{snapshot: snapshot} = BudgetSnapshots.b1()
      [dinner] = snapshot.events
      ceremony = %Event{id: 2, name: "Ceremony", sort_order: 1}

      newcomer = %Person{
        id: 5000,
        first_name: "Only",
        last_name: "Ceremony",
        certainty: :certain,
        age_category: :adult,
        want_tier: :yes
      }

      # Ten shared Dinner guests also at the Ceremony, plus one person only at the Ceremony:
      # Dinner 78, Ceremony 11, sum 89, distinct 79.
      ceremony_invitations =
        for person_id <- Enum.to_list(1001..1010) ++ [5000] do
          %Invitation{id: person_id + 10_000, person_id: person_id, event_id: 2, status: :invited}
        end

      snapshot = %{
        snapshot
        | events: [dinner, ceremony],
          persons: snapshot.persons ++ [newcomer],
          invitations: snapshot.invitations ++ ceremony_invitations
      }

      overall = Budget.overall(snapshot, likely())
      result = BudgetBreakdowns.per_guest(snapshot, overall)

      assert result.persons == 79
      assert {:ok, formula} = result.overall
      assert Money.equal?(money(formula), Money.div!(money(overall.forecast), 79))
      assert norm(formula.steps) == per_guest_steps("Likely", money(overall.forecast), 79)
    end

    test "nobody counted → :no_guests, overall and for every category" do
      %{snapshot: snapshot} = BudgetSnapshots.branches()
      snapshot = %{snapshot | persons: [], invitations: []}
      overall = Budget.overall(snapshot, minimum())
      result = BudgetBreakdowns.per_guest(snapshot, overall)

      assert result.preset == minimum()
      assert result.persons == 0
      assert result.overall == :no_guests
      assert length(result.categories) == 5
      assert Enum.all?(result.categories, &(&1.figure == :no_guests))
    end

    test "the divisor follows the preset overall was computed with" do
      %{snapshot: snapshot} = BudgetSnapshots.b1()
      overall = Budget.overall(snapshot, minimum())
      result = BudgetBreakdowns.per_guest(snapshot, overall)

      assert result.persons == 64
      assert {:ok, formula} = result.overall
      assert Money.equal?(money(formula), Money.div!(money(overall.forecast), 64))
      assert norm(formula.steps) == per_guest_steps("Minimum", money(overall.forecast), 64)
    end
  end

  # -- 9. property ----------------------------------------------------------------------------

  @runs 300

  describe "property: exact attribution" do
    test "Σ by_event == overall forecast exactly, every row ≥ €0, for every default preset" do
      seen =
        for run <- 1..@runs, reduce: MapSet.new() do
          seen ->
            %{snapshot: snapshot, spec: spec} = random_case()
            context = "run #{run}: #{inspect(spec, limit: :infinity)}"

            for preset <- Preset.defaults(), reduce: seen do
              seen ->
                overall = Budget.overall(snapshot, preset)
                rows = BudgetBreakdowns.by_event(snapshot, overall)
                context = "#{context} / #{preset.name}"

                assert length(rows) == length(snapshot.events) + 1, context

                assert WeddingPlanner.Money.compare(sum_rows(rows), money(overall.forecast)) ==
                         :eq,
                       context

                for row <- rows do
                  assert WeddingPlanner.Money.compare(row.amount, eur(0)) != :lt, context
                  assert row.formula.total == {:money, row.amount}, context

                  by_cat = row.by_category |> Enum.map(& &1.amount) |> WeddingPlanner.Money.sum()
                  assert WeddingPlanner.Money.compare(by_cat, row.amount) == :eq, context
                end

                seen
                |> MapSet.union(outcomes(overall))
                |> then(fn s ->
                  if Enum.any?(
                       rows,
                       &(&1.event != :general and
                           WeddingPlanner.Money.compare(&1.amount, eur(0)) == :gt)
                     ),
                     do: MapSet.put(s, :event_row_non_zero),
                     else: s
                end)
            end
        end

      for outcome <- [
            :confirmed,
            :planning_pick,
            :target,
            :no_target,
            :unlinked_invoices,
            :committed,
            :invoiced,
            :invoicing_complete,
            :minimum_spend_applied,
            :minimum_charge_applied,
            :invalid_line,
            :event_row_non_zero
          ] do
        assert outcome in seen, "#{inspect(outcome)} never generated in #{@runs} runs"
      end
    end
  end

  defp outcomes(overall) do
    for layers <- overall.categories, reduce: MapSet.new() do
      acc ->
        breakdowns =
          Enum.map(layers.confirmed_offers, & &1.breakdown) ++
            if(layers.planning_pick, do: [layers.planning_pick.breakdown], else: [])

        lines = Enum.flat_map(breakdowns, & &1.lines)

        acc
        |> MapSet.put(layers.branch)
        |> MapSet.put(layers.fallback_winner)
        |> MapSet.union(MapSet.new(layers.confirmed_offers, & &1.source))
        |> put_if(Enum.any?(breakdowns, & &1.minimum_spend_applied), :minimum_spend_applied)
        |> put_if(Enum.any?(lines, & &1.minimum_charge_applied), :minimum_charge_applied)
        |> put_if(Enum.any?(lines, & &1.invalid), :invalid_line)
    end
  end

  defp put_if(set, true, value), do: MapSet.put(set, value)
  defp put_if(set, false, _value), do: set

  # A random case: 1–2 events; 0–6 persons, each invited to each event with a random status
  # (or not invited); 0–4 categories with 0–2 services; 0–3 offers of 0–4 lines each —
  # flat or per-person (per adult / child / attendee on a random event, sometimes on no
  # event = invalid), service or ad hoc, mandatory or optional, with random included
  # quantities and minimum charges; offers VAT inclusive or exclusive (random default and
  # line rates), a random minimum spend, random status and invoicing complete; at most one
  # planning pick where nothing is confirmed; 0–3 invoices linked to a confirmed offer or
  # unlinked; a random target. Confirmed offers carry `Selection.freeze/2`'s rows.
  defp random_case do
    events = for n <- 1..Enum.random(1..2), do: %{id: n}

    persons =
      for p <- 1..Enum.random(0..6)//1 do
        %{
          id: p,
          certainty: Enum.random([:certain, :likely, :uncertain]),
          age: Enum.random([:adult, :adult, :child]),
          invitations:
            Enum.flat_map(events, fn ev ->
              case Enum.random([nil, :planned, :invited, :accepted, :declined]) do
                nil -> []
                status -> [{ev.id, status}]
              end
            end)
        }
      end

    categories =
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
            id = c * 100 + o

            %{
              id: id,
              status: status,
              complete: status == :confirmed and :rand.uniform(3) == 1,
              pick: false,
              vat: Enum.random([:inclusive, :exclusive]),
              minimum_spend: if(:rand.uniform(3) == 1, do: Enum.random(0..600_000)),
              lines:
                for(l <- 1..Enum.random(0..4)//1, do: random_line(id * 10 + l, services, events))
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
          for i <- 1..Enum.random(0..3)//1 do
            %{
              id: c * 100 + i,
              offer_id:
                if(confirmed_ids != [] and :rand.uniform(3) > 1, do: Enum.random(confirmed_ids)),
              cents: Enum.random(0..400_000)
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

    spec = %{events: events, persons: persons, categories: categories}
    %{snapshot: build_snapshot(spec), spec: spec}
  end

  defp random_line(id, services, events) do
    basis = Enum.random([:flat, :flat, :per_adult, :per_child, :per_attendee])
    service_id = if services != [] and :rand.uniform(2) == 1, do: Enum.random(services).id

    event_id =
      cond do
        basis == :flat -> nil
        :rand.uniform(8) == 1 -> nil
        true -> Enum.random(events).id
      end

    %{
      id: id,
      service_id: service_id,
      state: Enum.random([:mandatory, :mandatory, :optional]),
      enabled: :rand.uniform(2) == 1,
      basis: basis,
      event_id: event_id,
      cents: Enum.random(0..20_000),
      included: if(basis != :flat and :rand.uniform(2) == 1, do: Enum.random(0..3)),
      minimum_charge: if(:rand.uniform(3) == 1, do: Enum.random(0..100_000)),
      vat_bp: Enum.random([nil, 600, 1200, 2100])
    }
  end

  defp build_snapshot(spec) do
    events =
      for ev <- spec.events, do: %Event{id: ev.id, name: "Event #{ev.id}", sort_order: ev.id}

    persons =
      for p <- spec.persons do
        %Person{
          id: p.id,
          first_name: "P#{p.id}",
          certainty: p.certainty,
          age_category: p.age,
          want_tier: :yes
        }
      end

    invitations =
      for p <- spec.persons, {event_id, status} <- p.invitations do
        %Invitation{
          id: p.id * 10 + event_id,
          person_id: p.id,
          event_id: event_id,
          status: status
        }
      end

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
          vat_basis: o.vat,
          vat_rate_bp: if(o.vat == :exclusive, do: 2100),
          minimum_spend: o.minimum_spend && from_cents(o.minimum_spend)
        }
      end

    lines =
      for c <- spec.categories, o <- c.offers, l <- o.lines do
        %OfferLine{
          id: l.id,
          offer_id: o.id,
          service_id: l.service_id,
          label: if(is_nil(l.service_id), do: "Line #{l.id}"),
          state: l.state,
          enabled: l.enabled,
          basis: l.basis,
          event_id: l.event_id,
          amount: from_cents(l.cents),
          included_quantity: l.included,
          minimum_charge: l.minimum_charge && from_cents(l.minimum_charge),
          vat_rate_bp: l.vat_bp
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
            invoice_date: ~D[2027-01-01]
          }

          line = %InvoiceLine{
            id: i.id * 10,
            invoice_id: i.id,
            label: "L",
            amount: from_cents(i.cents)
          }

          {invoices ++ [invoice], invoice_lines ++ [line]}
      end

    snapshot = %Snapshot{
      events: events,
      persons: persons,
      invitations: invitations,
      categories: categories,
      services: services,
      offers: offers,
      offer_lines: lines,
      invoices: invoices,
      invoice_lines: invoice_lines,
      headcount_presets: Preset.defaults(),
      settings: %Settings{}
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

  defp from_cents(c), do: WeddingPlanner.Money.new(Decimal.new(1, c, -2))
end
