defmodule WeddingPlanner.Valuation.SimulationTest do
  @moduledoc """
  `WeddingPlanner.Valuation.Simulation` — the what-if preview (`BUD-20`, `BUD-21`), the
  marginal cost (`BUD-22`) and who each role preset counts (`INVT-04`), per `DR-80` and
  `DR-81` — over in-memory snapshots (`WeddingPlanner.BudgetSnapshots`,
  `WeddingPlanner.NormativeSnapshots`) through the **real** headcount, offer and budget
  engines: a fixed headcount would ignore the change, so no test here uses the offer
  engine's test seam.

  * `@tag example: "B4"` — normative example B4 (the recomputed Venue A total, never
    `2 × €85 + €40 + 3 × €12`).
  * The two properties use an oracle that builds the after-snapshot itself (editing the
    snapshot's lists directly, never through `Simulation.changes/2` or `removal/2`) and
    evaluates it with `Budget.overall/3` / `Headcount.evaluate/3`.

  Person ids `1001…1078` are the shared Dinner guests; this file's own persons are `3001…`.
  Amounts this file writes itself (the €11,802 after-total, the €76 delta, …) are derived
  by hand in the comments next to them; they are test construction, not normative data.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.BudgetSnapshots
  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Invitations.PlusOneOptOut
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Invoices.InvoiceLine
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeInvoices
  alias WeddingPlanner.NormativeSnapshots
  alias WeddingPlanner.Offers.FrozenService
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Settings
  alias WeddingPlanner.Valuation.Budget
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Formula.Step
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Simulation
  alias WeddingPlanner.Valuation.Snapshot

  @dinner_id 1
  @ceremony_id 2
  @roles [:minimum, :likely, :maximum]
  @statuses [:planned, :invited, :accepted, :declined, :not_invited]

  # -- helpers -------------------------------------------------------------------------------

  defp eur(amount), do: WeddingPlanner.Money.new(amount)
  defp dec(string), do: eur(Decimal.new(string))

  defp assert_money(actual, expected, what) do
    assert WeddingPlanner.Money.compare(actual, expected) == :eq,
           "#{what}: expected #{Money.to_string!(expected)}, got #{Money.to_string!(actual)}"
  end

  defp money(%Formula{total: {:money, %Money{} = money}}), do: money

  defp role_preset(role), do: Enum.find(Preset.defaults(), &(&1.role == role))
  defp likely, do: role_preset(:likely)
  defp minimum, do: role_preset(:minimum)

  # Steps with every %Money{} replaced by its normalised amount, so `€ 11726` and
  # `€ 11726.00` compare equal and a failure prints readable amounts.
  defp norm(%Money{amount: amount}),
    do: {:eur, amount |> Decimal.normalize() |> Decimal.to_string(:normal)}

  defp norm(%Step{label: label, value: value}), do: {norm(label), norm(value)}
  defp norm(list) when is_list(list), do: Enum.map(list, &norm/1)
  defp norm(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> norm() |> List.to_tuple()
  defp norm(other), do: other

  defp e(%Money{} = amount), do: norm(amount)
  defp e(amount) when is_integer(amount), do: norm(eur(amount))

  defp preview(snapshot, draft, selected \\ likely()) do
    {:ok, baseline} = Simulation.baseline(snapshot, selected)
    Simulation.preview(baseline, draft)
  end

  defp category(evaluation, name),
    do: Enum.find(evaluation.categories, &(&1.category.name == name))

  defp headcount_row(evaluation, :all_events),
    do: Enum.find(evaluation.headcounts, &(&1.event == :all_events))

  defp headcount_row(evaluation, name),
    do: Enum.find(evaluation.headcounts, &match?(%{event: %Event{name: ^name}}, &1))

  defp counts(adults, children),
    do: %{adults: adults, children: children, total: adults + children}

  defp b1, do: BudgetSnapshots.b1().snapshot

  defp venue_a_line(overall_result, line_id) do
    [%{breakdown: breakdown}] =
      Enum.find(overall_result.categories, &(&1.category.name == "Venue")).confirmed_offers

    Enum.find(breakdown.lines, &(&1.line.id == line_id))
  end

  # B4's household (`NE.given("B4")`: 2 adults + 1 child): persons 3001, 3002 (adults),
  # 3003 (child), want tier *maybe* (the B-list, INVT-04), no invitations.
  defp with_household(snapshot, certainty) do
    %{what_if: %{adds: %{adults: 2, children: 1}}} = NE.given("B4")

    household =
      for {id, age} <- [{3001, :adult}, {3002, :adult}, {3003, :child}] do
        %Person{
          id: id,
          first_name: "Hypo",
          last_name: Integer.to_string(id),
          age_category: age,
          certainty: certainty,
          want_tier: :maybe
        }
      end

    %{snapshot | persons: snapshot.persons ++ household}
  end

  defp household_draft(status \\ :invited),
    do: Map.new([3001, 3002, 3003], &{&1, %{@dinner_id => status}})

  defp ceremony, do: %Event{id: @ceremony_id, name: "Ceremony", sort_order: 1}

  defp with_ceremony(snapshot), do: %{snapshot | events: snapshot.events ++ [ceremony()]}

  defp plus_one(id, host_id, status, age \\ :adult),
    do: %Person{
      id: id,
      host_id: host_id,
      plus_one_status: status,
      age_category: age,
      want_tier: :yes,
      certainty: :certain
    }

  defp delta_steps(preset_name, after_, before),
    do: [
      {"Headcount preset", {:preset, preset_name}},
      {"Forecast with the change", {:money, e(after_)}},
      {"Forecast now", {:money, e(before)}}
    ]

  # -- 1. B4 ------------------------------------------------------------------------------------

  describe "normative example B4 (real engines, no seam)" do
    @tag example: "B4"
    test "B4: 2 adults + 1 child invited to Dinner → the recomputed Venue A total, not the per-person sum" do
      %{what_if: %{event: "Dinner", status: status}} = NE.given("B4")
      snapshot = with_household(b1(), :likely)
      preview = preview(snapshot, household_draft(status))
      venue_a_now = NE.expected("O1").total

      # Likely 72 + 6 → 74 + 7: seating (81 − 50) × €12 = €372 (+€36); adults 74 × €85 =
      # €6,290 stays at the €6,800 minimum charge (+€0); children 7 × €40 = €280 (+€40).
      venue_a_after = eur(11_802)
      likely = preview.roles.likely

      assert length(preview.cells) == 3
      assert Enum.all?(preview.cells, &(&1.from == :not_invited and &1.to == :invited))

      dinner = headcount_row(likely, "Dinner")
      assert dinner.before == counts(72, 6)
      assert dinner.after == counts(74, 7)

      venue = category(likely, "Venue")
      assert [%{role: :confirmed, offer: %Offer{vendor_name: "Venue A"}} = row] = venue.offers
      assert_money(row.before, venue_a_now, "Venue A now")
      assert_money(row.after, venue_a_after, "Venue A recomputed")

      assert_money(money(venue.delta), eur(76), "Venue delta")
      assert_money(money(likely.overall.delta), eur(76), "overall delta")

      refute WeddingPlanner.Money.compare(money(venue.delta), NE.expected("B4").naive_delta) ==
               :eq

      assert norm(venue.delta.steps) == delta_steps("Likely", venue_a_after, venue_a_now)
      assert venue.delta.label == "Change in forecast"
      assert norm(likely.overall.delta.steps) == delta_steps("Likely", venue_a_after, venue_a_now)

      # The line-level story, read from the budget engine's own breakdown on both sides.
      for {line_id, before, after_} <- [{2, 336, 372}, {3, 6_800, 6_800}, {4, 240, 280}] do
        assert_money(
          venue_a_line(likely.overall.before, line_id).total,
          eur(before),
          "line #{line_id} now"
        )

        assert_money(
          venue_a_line(likely.overall.after, line_id).total,
          eur(after_),
          "line #{line_id} after"
        )
      end

      assert venue_a_line(likely.overall.after, 3).minimum_charge_applied

      # A *likely* household is not counted by Minimum; Maximum counts every certainty.
      assert_money(money(preview.roles.minimum.overall.delta), eur(0), "Minimum delta")
      assert headcount_row(preview.roles.minimum, "Dinner").after == counts(60, 4)
      assert_money(money(preview.roles.maximum.overall.delta), eur(76), "Maximum delta")

      assert norm(preview.roles.minimum.overall.delta.steps) |> hd() ==
               {"Headcount preset", {:preset, "Minimum"}}
    end

    test "B4 with a certain household: Minimum 60 + 4 → 62 + 5, Venue A €11,478 → €11,554" do
      snapshot = with_household(b1(), :certain)
      preview = preview(snapshot, household_draft())
      minimum = preview.roles.minimum

      assert headcount_row(minimum, "Dinner").before == counts(60, 4)
      assert headcount_row(minimum, "Dinner").after == counts(62, 5)

      # Seating (67 − 50) × €12 = €204 (+€36); adults 62 × €85 = €5,270 held at €6,800;
      # children 5 × €40 = €200 (+€40).
      [row] = category(minimum, "Venue").offers
      assert_money(row.before, NE.expected("O2").total, "Venue A now (Minimum)")
      assert_money(row.after, eur(11_554), "Venue A after (Minimum)")
      assert_money(money(minimum.overall.delta), eur(76), "Minimum delta")

      for {line_id, before, after_} <- [{2, 168, 204}, {3, 6_800, 6_800}, {4, 160, 200}] do
        assert_money(
          venue_a_line(minimum.overall.before, line_id).total,
          eur(before),
          "line #{line_id} now"
        )

        assert_money(
          venue_a_line(minimum.overall.after, line_id).total,
          eur(after_),
          "line #{line_id} after"
        )
      end

      for role <- [:likely, :maximum] do
        assert_money(money(preview.roles[role].overall.delta), eur(76), "#{role} delta")
      end
    end
  end

  # -- 3. minimum spend ------------------------------------------------------------------------

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

  describe "minimum spend (BUD-21)" do
    test "Caterer C under Minimum: one more certain adult leaves the €7,000 minimum spend in force → €0" do
      snapshot = %{
        caterer_c_confirmed()
        | persons:
            caterer_c_confirmed().persons ++
              [
                %Person{
                  id: 3001,
                  first_name: "Hypo",
                  age_category: :adult,
                  certainty: :certain,
                  want_tier: :yes
                }
              ]
      }

      minimum = preview(snapshot, %{3001 => %{@dinner_id => :invited}}).roles.minimum
      catering = category(minimum, "Catering")

      assert [%{role: :confirmed} = row] = catering.offers
      assert_money(row.before, eur(7_000), "Caterer C now")
      assert_money(row.after, eur(7_000), "Caterer C after")
      assert_money(money(catering.delta), eur(0), "Catering delta")
      assert_money(money(minimum.overall.delta), eur(0), "overall delta")

      # The per-adult line did move — 61 × €60 × 1.12 — the minimum spend absorbs it.
      [%{breakdown: before}] = Enum.at(minimum.overall.before.categories, 0).confirmed_offers
      [%{breakdown: after_}] = Enum.at(minimum.overall.after.categories, 0).confirmed_offers

      assert_money(
        Enum.find(before.lines, &(&1.line.id == 1)).total,
        dec("4032.00"),
        "adults now"
      )

      assert_money(
        Enum.find(after_.lines, &(&1.line.id == 1)).total,
        dec("4099.20"),
        "adults after"
      )

      assert after_.minimum_spend_applied
    end
  end

  # -- 4. planning pick -------------------------------------------------------------------------

  describe "the planning-pick branch" do
    test "one more certain adult at Dinner: Flowers +€10 (Table flowers) under every role; others €0" do
      %{snapshot: snapshot, offers: %{"Florist F" => florist_f}} = BudgetSnapshots.branches()

      snapshot = %{
        snapshot
        | persons:
            snapshot.persons ++
              [
                %Person{
                  id: 3001,
                  first_name: "Hypo",
                  age_category: :adult,
                  certainty: :certain,
                  want_tier: :yes
                }
              ]
      }

      preview = preview(snapshot, %{3001 => %{@dinner_id => :invited}})

      for role <- @roles do
        evaluation = preview.roles[role]
        flowers = category(evaluation, "Flowers")

        assert_money(money(flowers.delta), eur(10), "#{role} Flowers delta")
        assert [%{role: :planning_pick, offer: offer} = row] = flowers.offers
        assert offer.id == florist_f.id

        assert_money(
          WeddingPlanner.Money.subtract(row.after, row.before),
          eur(10),
          "#{role} pick"
        )

        for name <- ["Photography", "Attire", "Church"] do
          assert_money(money(category(evaluation, name).delta), eur(0), "#{role} #{name} delta")
        end

        assert category(evaluation, "Attire").offers == []
        assert category(evaluation, "Church").offers == []

        # Seating +€12 at Venue A (adults' catering held by the minimum charge) + €10.
        assert_money(money(evaluation.overall.delta), eur(22), "#{role} overall delta")
      end
    end
  end

  # -- 5. changes/2 ------------------------------------------------------------------------------

  describe "changes/2" do
    test "replaces an existing row in place, deletes for :not_invited, inserts with the tuple id" do
      snapshot = with_household(b1(), :likely)
      row_1001 = Enum.find(snapshot.invitations, &(&1.person_id == 1001))
      row_1002 = Enum.find(snapshot.invitations, &(&1.person_id == 1002))

      assert Simulation.changes(snapshot, %{1001 => %{@dinner_id => :accepted}}) ==
               [{:put, :invitations, %{row_1001 | status: :accepted}}]

      replaced =
        Snapshot.apply(
          snapshot,
          Simulation.changes(snapshot, %{1001 => %{@dinner_id => :accepted}})
        )

      rows =
        Enum.filter(replaced.invitations, &(&1.person_id == 1001 and &1.event_id == @dinner_id))

      assert [%Invitation{id: id, status: :accepted}] = rows
      assert id == row_1001.id

      assert Enum.find_index(replaced.invitations, &(&1.id == row_1001.id)) ==
               Enum.find_index(snapshot.invitations, &(&1.id == row_1001.id))

      assert Simulation.changes(snapshot, %{1002 => %{@dinner_id => :not_invited}}) ==
               [{:delete, :invitations, row_1002.id}]

      assert Simulation.changes(snapshot, %{3001 => %{@dinner_id => :planned}}) == [
               {:put, :invitations,
                %Invitation{
                  id: {:what_if, 3001, @dinner_id},
                  person_id: 3001,
                  event_id: @dinner_id,
                  status: :planned
                }}
             ]
    end

    test "[] when every desired status equals the current one; raises for a +1 or an unknown id" do
      snapshot = with_household(b1(), :likely)

      assert Simulation.changes(snapshot, %{}) == []

      assert Simulation.changes(snapshot, %{
               1001 => %{@dinner_id => :invited},
               3001 => %{@dinner_id => :not_invited}
             }) == []

      snapshot = %{snapshot | persons: snapshot.persons ++ [plus_one(3101, 1001, :confirmed)]}

      for draft <- [
            %{3101 => %{@dinner_id => :invited}},
            %{9999 => %{@dinner_id => :invited}},
            %{1001 => %{99 => :invited}},
            %{1001 => %{@dinner_id => :maybe}}
          ] do
        assert_raise ArgumentError, fn -> Simulation.changes(snapshot, draft) end
        assert_raise ArgumentError, fn -> Simulation.changed_cells(snapshot, draft) end
      end
    end
  end

  # -- 6. prune/2 and changed_cells/2 ------------------------------------------------------------

  describe "prune/2 and changed_cells/2" do
    test "prune/2 drops a deleted person, a deleted event, a +1 and a person left with no events" do
      snapshot =
        b1()
        |> with_household(:likely)
        |> with_ceremony()
        |> Map.update!(:persons, &(&1 ++ [plus_one(3101, 1001, :confirmed)]))

      draft = %{
        1001 => %{@dinner_id => :accepted, @ceremony_id => :invited},
        3002 => %{@dinner_id => :invited},
        3003 => %{@ceremony_id => :invited},
        3101 => %{@dinner_id => :invited},
        1002 => %{@dinner_id => :bogus}
      }

      # Since the draft was made: person 3002 and the Ceremony were deleted.
      snapshot =
        Snapshot.apply(snapshot, [{:delete, :persons, 3002}, {:delete, :events, @ceremony_id}])

      assert Simulation.prune(snapshot, draft) == %{1001 => %{@dinner_id => :accepted}}
      assert Simulation.prune(snapshot, %{}) == %{}
      assert Simulation.prune(snapshot, %{1001 => :not_a_map}) == %{}
    end

    test "changed_cells/2: persons order then events order, with from/to; unchanged cells left out" do
      snapshot = b1() |> with_household(:likely) |> with_ceremony()

      draft = %{
        3003 => %{@ceremony_id => :invited, @dinner_id => :planned},
        1002 => %{@dinner_id => :invited},
        1001 => %{@ceremony_id => :invited, @dinner_id => :accepted}
      }

      cells =
        for cell <- Simulation.changed_cells(snapshot, draft),
            do: {cell.person.id, cell.event.id, cell.from, cell.to}

      assert cells == [
               {1001, @dinner_id, :invited, :accepted},
               {1001, @ceremony_id, :not_invited, :invited},
               {3003, @dinner_id, :not_invited, :planned},
               {3003, @ceremony_id, :not_invited, :invited}
             ]
    end
  end

  # -- 7. headcount rows -------------------------------------------------------------------------

  describe "headcount rows" do
    test "every event (EVT-04 order) then :all_events; distinct across events; after_explain traceable" do
      snapshot =
        b1()
        |> with_household(:likely)
        |> with_ceremony()
        |> Map.update!(:invitations, fn rows ->
          rows ++
            [%Invitation{id: 5001, person_id: 1001, event_id: @ceremony_id, status: :invited}]
        end)

      draft = %{3001 => %{@dinner_id => :invited, @ceremony_id => :invited}}
      likely = preview(snapshot, draft).roles.likely

      assert Enum.map(likely.headcounts, fn
               %{event: %Event{name: name}} -> name
               %{event: :all_events} -> :all_events
             end) == ["Dinner", "Ceremony", :all_events]

      assert headcount_row(likely, "Dinner").before == counts(72, 6)
      assert headcount_row(likely, "Dinner").after == counts(73, 6)
      assert headcount_row(likely, "Ceremony").before == counts(1, 0)
      assert headcount_row(likely, "Ceremony").after == counts(2, 0)
      # 1001 and 3001 are each counted for both events, once each (HC-03).
      assert headcount_row(likely, :all_events).before == counts(72, 6)
      assert headcount_row(likely, :all_events).after == counts(73, 6)

      # The oracle's after-snapshot, built by hand.
      after_snapshot = %{
        snapshot
        | invitations:
            snapshot.invitations ++
              for event_id <- [@dinner_id, @ceremony_id] do
                %Invitation{
                  id: {:oracle, event_id},
                  person_id: 3001,
                  event_id: event_id,
                  status: :invited
                }
              end
      }

      for row <- likely.headcounts do
        assert row.after_explain == Headcount.explain(after_snapshot, likely(), row.event)

        assert hd(row.after_explain.steps) == %Step{
                 label: "Headcount preset",
                 value: {:preset, "Likely"}
               }

        assert row.after_explain.total == {:count, row.after.total}
      end
    end
  end

  # -- 8. the selected preset --------------------------------------------------------------------

  describe "the selected preset (HC-08)" do
    test "a custom non-role preset is evaluated as itself; the Likely role preset reuses roles.likely" do
      snapshot = with_household(b1(), :likely)

      custom = %Preset{
        id: 77,
        name: "Accepted only",
        invitation_statuses: MapSet.new([:accepted])
      }

      draft = household_draft(:accepted)

      preview = preview(snapshot, draft, custom)
      selected = preview.selected

      assert selected.preset == custom

      # Nobody is accepted yet: Venue A at 0 guests = €4,000 + €6,800 (minimum charge) + €350.
      assert_money(money(selected.overall.before.forecast), eur(11_150), "custom now")

      # The household accepts: seating 3 ≤ 50 included, adults held at €6,800, one child €40.
      assert_money(money(selected.overall.delta), eur(40), "custom delta")

      assert hd(norm(selected.overall.delta.steps)) ==
               {"Headcount preset", {:preset, "Accepted only"}}

      assert headcount_row(selected, "Dinner").after == counts(2, 1)

      refute money(selected.overall.delta) == money(preview.roles.likely.overall.delta)
      assert_money(money(preview.roles.likely.overall.delta), eur(76), "Likely delta")

      assert preview(snapshot, draft, likely()).selected ==
               preview(snapshot, draft, likely()).roles.likely

      assert preview(snapshot, draft, minimum()).selected.preset == minimum()
    end
  end

  # -- 9. marginal cost --------------------------------------------------------------------------

  defp marginal(snapshot, person_id) do
    {:ok, result} = Simulation.marginal_cost(snapshot, person_id)
    result
  end

  defp marginal_steps(preset_name, with_label, now, without),
    do: [
      {"Headcount preset", {:preset, preset_name}},
      {with_label, {:money, e(now)}},
      {"Forecast without", {:money, e(without)}}
    ]

  describe "marginal cost (BUD-22, DR-81)" do
    test "a likely adult: €12 under Likely and Maximum, €0 under Minimum; formula steps exact" do
      snapshot = b1()
      result = marginal(snapshot, 1065)
      person = Enum.find(snapshot.persons, &(&1.id == 1065))

      assert_money(money(result.likely.formula), eur(12), "Likely")
      assert_money(money(result.maximum.formula), eur(12), "Maximum")
      assert_money(money(result.minimum.formula), eur(0), "Minimum")
      assert result.likely.removed == [person]
      assert result.likely.preset == likely()
      assert result.likely.formula.label == "Marginal cost"

      # Seating (77 − 50) × €12 without them; adults' catering held at the minimum charge.
      assert norm(result.likely.formula.steps) ==
               marginal_steps("Likely", ["Forecast with ", "Shared 65"], eur(11_726), eur(11_714))

      assert norm(result.minimum.formula.steps) ==
               marginal_steps(
                 "Minimum",
                 ["Forecast with ", "Shared 65"],
                 eur(11_478),
                 eur(11_478)
               )
    end

    test "a certain child: €52 (seating €12 + child €40) under every role" do
      result = marginal(b1(), 1061)

      for role <- @roles, do: assert_money(money(result[role].formula), eur(52), "#{role}")
    end

    test "a host with a confirmed +1: both removed, €24; the +1 alone €12; label names the +1" do
      snapshot = %{b1() | persons: b1().persons ++ [plus_one(3101, 1001, :confirmed)]}
      host = Enum.find(snapshot.persons, &(&1.id == 1001))
      guest = Enum.find(snapshot.persons, &(&1.id == 3101))

      result = marginal(snapshot, 1001)

      for role <- [:likely, :minimum] do
        assert_money(money(result[role].formula), eur(24), "host #{role}")
        assert result[role].removed == [host, guest]
      end

      # Likely 73 + 6 with the +1: seating 29 × €12 = €348 → 27 × €12 = €324.
      assert norm(result.likely.formula.steps) ==
               marginal_steps(
                 "Likely",
                 ["Forecast with ", "Shared 01", " and their +1"],
                 eur(11_738),
                 eur(11_714)
               )

      alone = marginal(snapshot, 3101)
      assert_money(money(alone.likely.formula), eur(12), "+1 alone")
      assert alone.likely.removed == [guest]

      assert norm(alone.likely.formula.steps) ==
               marginal_steps(
                 "Likely",
                 ["Forecast with ", "+1 of Shared 01"],
                 eur(11_738),
                 eur(11_726)
               )

      two = %{snapshot | persons: snapshot.persons ++ [plus_one(3102, 1001, :confirmed)]}

      assert [_, "Shared 01", " and their +1s"] =
               hd(tl(marginal(two, 1001).likely.formula.steps)).label
    end

    test "a person with no invitations costs €0 under every role" do
      result = marginal(with_household(b1(), :certain), 3001)

      for role <- @roles do
        assert_money(money(result[role].formula), eur(0), "#{role}")

        assert hd(norm(result[role].formula.steps)) ==
                 {"Headcount preset", {:preset, role_preset(role).name}}
      end
    end
  end

  # -- 10. removal/2 -----------------------------------------------------------------------------

  describe "removal/2" do
    test "deletes the host, its +1s and all their invitations and opt-outs; apply/2 is consistent" do
      snapshot =
        b1()
        |> with_ceremony()
        |> Map.update!(
          :persons,
          &(&1 ++ [plus_one(3101, 1001, :confirmed), plus_one(3102, 1001, :possible)])
        )
        |> Map.update!(:invitations, fn rows ->
          rows ++
            [%Invitation{id: 5001, person_id: 1001, event_id: @ceremony_id, status: :accepted}]
        end)
        |> Map.put(:plus_one_opt_outs, [
          %PlusOneOptOut{id: 6001, person_id: 3101, event_id: @ceremony_id},
          %PlusOneOptOut{id: 6002, person_id: 3102, event_id: @dinner_id}
        ])

      change = Simulation.removal(snapshot, 1001)

      assert MapSet.new(change) ==
               MapSet.new([
                 {:delete, :persons, 1001},
                 {:delete, :persons, 3101},
                 {:delete, :persons, 3102},
                 {:delete, :invitations, 2001},
                 {:delete, :invitations, 5001},
                 {:delete, :plus_one_opt_outs, 6001},
                 {:delete, :plus_one_opt_outs, 6002}
               ])

      removed = [1001, 3101, 3102]
      after_snapshot = Snapshot.apply(snapshot, change)
      refute Enum.any?(after_snapshot.persons, &(&1.id in removed or &1.host_id == 1001))
      refute Enum.any?(after_snapshot.invitations, &(&1.person_id in removed))
      refute Enum.any?(after_snapshot.plus_one_opt_outs, &(&1.person_id in removed))

      for preset <- Preset.defaults(), target <- after_snapshot.events ++ [:all_events] do
        Headcount.evaluate(after_snapshot, preset, target)
      end

      assert Simulation.removal(snapshot, 3101) ==
               [{:delete, :persons, 3101}, {:delete, :plus_one_opt_outs, 6001}]

      assert_raise ArgumentError, fn -> Simulation.removal(snapshot, 9999) end
      assert_raise ArgumentError, fn -> Simulation.marginal_cost(snapshot, 9999) end
    end
  end

  # -- 11. counted_roles/1 -----------------------------------------------------------------------

  describe "counted_roles/1 (INVT-04)" do
    test "certain adult → all three roles; likely adult → likely and maximum; uninvited B-list → []" do
      snapshot = with_household(b1(), :likely)
      {:ok, roles} = Simulation.counted_roles(snapshot)

      assert roles[1001] == [:minimum, :likely, :maximum]
      assert roles[1065] == [:likely, :maximum]
      assert roles[3001] == []

      assert Map.keys(roles) |> Enum.sort() ==
               snapshot.persons |> Enum.map(& &1.id) |> Enum.sort()
    end
  end

  # -- 12. :missing ------------------------------------------------------------------------------

  describe "an unassigned role preset" do
    test "baseline/2, marginal_cost/2 and counted_roles/1 return :missing" do
      snapshot = %{
        b1()
        | headcount_presets: Enum.reject(Preset.defaults(), &(&1.role == :maximum))
      }

      assert Simulation.baseline(snapshot, likely()) == :missing
      assert Simulation.marginal_cost(snapshot, 1001) == :missing
      assert Simulation.counted_roles(snapshot) == :missing
    end
  end

  # -- 13./14. properties ------------------------------------------------------------------------

  @runs 200

  describe "property — the preview equals an independent re-evaluation (BUD-21)" do
    test "after-forecasts, deltas, Σ category deltas = overall, headcounts, offer rows, changes" do
      seen =
        for run <- 1..@runs, reduce: MapSet.new() do
          seen ->
            %{snapshot: snapshot, spec: spec} = random_case()
            draft = random_draft(spec)
            context = "run #{run}: #{inspect({spec, draft}, limit: :infinity)}"

            assert Simulation.prune(snapshot, draft) == draft, context
            {:ok, baseline} = Simulation.baseline(snapshot, likely())
            preview = Simulation.preview(baseline, draft)
            oracle_after = oracle_apply(snapshot, draft)

            # The change itself: the same invitations as the oracle, one row per pair.
            applied = Snapshot.apply(snapshot, Simulation.changes(snapshot, draft))
            assert triples(applied) == triples(oracle_after), context
            pairs = Enum.map(applied.invitations, &{&1.person_id, &1.event_id})
            assert pairs == Enum.uniq(pairs), context

            seen =
              for role <- @roles, reduce: seen do
                seen ->
                  preset = role_preset(role)
                  evaluation = preview.roles[role]
                  now = Budget.overall(snapshot, preset)
                  oracle = Budget.overall(oracle_after, preset)

                  assert evaluation.preset == preset, context

                  assert_eq(
                    money(evaluation.overall.after.forecast),
                    money(oracle.forecast),
                    context
                  )

                  assert_eq(
                    money(evaluation.overall.before.forecast),
                    money(now.forecast),
                    context
                  )

                  overall_delta = money(evaluation.overall.delta)

                  assert_eq(
                    overall_delta,
                    WeddingPlanner.Money.subtract(money(oracle.forecast), money(now.forecast)),
                    context
                  )

                  Enum.zip_with([evaluation.categories, now.categories, oracle.categories], fn
                    [row, before, after_] ->
                      assert row.category == after_.category, context
                      assert_eq(money(row.after), money(after_.forecast), context)
                      assert_eq(money(row.before), money(before.forecast), context)

                      assert_eq(
                        money(row.delta),
                        WeddingPlanner.Money.subtract(money(row.after), money(row.before)),
                        context
                      )

                      assert Enum.map(row.offers, &{&1.role, &1.offer.id, cents(&1.after)}) ==
                               oracle_offer_rows(after_),
                             context
                  end)

                  category_deltas = Enum.map(evaluation.categories, &money(&1.delta))
                  assert_eq(WeddingPlanner.Money.sum(category_deltas), overall_delta, context)

                  for row <- evaluation.headcounts do
                    assert row.after == Headcount.evaluate(oracle_after, preset, row.event),
                           context

                    assert row.before == Headcount.evaluate(snapshot, preset, row.event), context
                  end

                  seen
                  |> MapSet.put(sign(overall_delta))
                  |> MapSet.union(MapSet.new(evaluation.categories, &sign(money(&1.delta))))
              end

            # An empty draft: nothing changes, every delta €0.
            empty = Simulation.preview(baseline, %{})
            assert empty.cells == [], context

            for role <- @roles, evaluation = empty.roles[role] do
              assert sign(money(evaluation.overall.delta)) == :zero, context
              assert Enum.all?(evaluation.categories, &(sign(money(&1.delta)) == :zero)), context
            end

            # A draft equal to the current statuses changes nothing.
            current = current_draft(snapshot, spec)
            assert Simulation.changes(snapshot, current) == [], context
            assert Simulation.changed_cells(snapshot, current) == [], context

            seen
            |> MapSet.union(MapSet.new(Simulation.changes(snapshot, draft), &change_kind/1))
        end

      for outcome <- [:positive, :negative, :zero, :replace, :insert, :delete] do
        assert outcome in seen, "#{inspect(outcome)} never generated in #{@runs} runs"
      end
    end
  end

  describe "property — marginal cost equals an independent removal (BUD-22, DR-81)" do
    test "≥ €0 under every role, and overall(snapshot) − overall(oracle without the person)" do
      seen =
        for run <- 1..@runs, reduce: MapSet.new() do
          seen ->
            %{snapshot: snapshot, spec: spec} = random_case()

            case snapshot.persons do
              [] ->
                seen

              persons ->
                person = Enum.random(persons)

                context =
                  "run #{run}, person #{inspect(person.id)}: #{inspect(spec, limit: :infinity)}"

                {:ok, result} = Simulation.marginal_cost(snapshot, person.id)
                {without, removed} = oracle_without(snapshot, person)

                for role <- @roles, reduce: seen do
                  seen ->
                    preset = role_preset(role)
                    %{formula: formula} = result[role]
                    cost = money(formula)

                    assert WeddingPlanner.Money.compare(cost, eur(0)) != :lt, context
                    assert result[role].removed == removed, context

                    assert_eq(
                      cost,
                      WeddingPlanner.Money.subtract(
                        money(Budget.overall(snapshot, preset).forecast),
                        money(Budget.overall(without, preset).forecast)
                      ),
                      context
                    )

                    seen
                    |> MapSet.put(sign(cost))
                    |> MapSet.put(if(person.host_id, do: :plus_one, else: :host))
                    |> MapSet.put({:removed, min(length(removed), 2)})
                end
            end
        end

      for outcome <- [:positive, :zero, :plus_one, :host, {:removed, 1}, {:removed, 2}] do
        assert outcome in seen, "#{inspect(outcome)} never generated in #{@runs} runs"
      end
    end
  end

  defp assert_eq(actual, expected, context) do
    assert WeddingPlanner.Money.compare(actual, expected) == :eq,
           "expected #{Money.to_string!(expected)}, got #{Money.to_string!(actual)} — #{context}"
  end

  defp sign(%Money{} = amount) do
    case WeddingPlanner.Money.compare(amount, eur(0)) do
      :gt -> :positive
      :lt -> :negative
      :eq -> :zero
    end
  end

  defp change_kind({:delete, :invitations, _}), do: :delete
  defp change_kind({:put, :invitations, %Invitation{id: {:what_if, _, _}}}), do: :insert
  defp change_kind({:put, :invitations, %Invitation{}}), do: :replace

  defp triples(snapshot),
    do: snapshot.invitations |> Enum.map(&{&1.person_id, &1.event_id, &1.status}) |> Enum.sort()

  defp cents(%Money{amount: amount}), do: amount |> Decimal.mult(100) |> Decimal.normalize()

  defp oracle_offer_rows(%{branch: :confirmed, confirmed_offers: offers}),
    do: for(o <- offers, do: {:confirmed, o.offer.id, cents(money(o.committed))})

  defp oracle_offer_rows(%{branch: :planning_pick, planning_pick: pick}),
    do: [{:planning_pick, pick.offer.id, cents(money(pick.total))}]

  defp oracle_offer_rows(_layers), do: []

  # The oracle's after-snapshot: edits `snapshot.invitations` directly, cell by cell.
  defp oracle_apply(snapshot, draft) do
    invitations =
      for {person_id, events} <- draft, {event_id, to} <- events, reduce: snapshot.invitations do
        rows ->
          others = Enum.reject(rows, &(&1.person_id == person_id and &1.event_id == event_id))

          case to do
            :not_invited ->
              others

            status ->
              others ++
                [
                  %Invitation{
                    id: {:oracle, person_id, event_id},
                    person_id: person_id,
                    event_id: event_id,
                    status: status
                  }
                ]
          end
      end

    %{snapshot | invitations: invitations}
  end

  # The oracle's snapshot without `person`: the person, a host's +1s, and their rows.
  defp oracle_without(snapshot, %Person{} = person) do
    removed =
      if person.host_id,
        do: [person],
        else: [person | Enum.filter(snapshot.persons, &(&1.host_id == person.id))]

    ids = Enum.map(removed, & &1.id)

    without = %{
      snapshot
      | persons: Enum.reject(snapshot.persons, &(&1.id in ids)),
        invitations: Enum.reject(snapshot.invitations, &(&1.person_id in ids)),
        plus_one_opt_outs: Enum.reject(snapshot.plus_one_opt_outs, &(&1.person_id in ids))
    }

    {without, removed}
  end

  # A random draft over the spec's non-+1 persons and events (every status, :not_invited
  # included); sometimes empty.
  defp random_draft(spec) do
    hosts = Enum.map(spec.persons, & &1.id)

    for person_id <- Enum.take_random(hosts, Enum.random(0..length(hosts))), into: %{} do
      events =
        case Enum.filter(spec.events, fn _ -> :rand.uniform(2) == 1 end) do
          [] -> [Enum.random(spec.events)]
          some -> some
        end

      {person_id, Map.new(events, &{&1.id, Enum.random(@statuses)})}
    end
  end

  # A draft of some persons' current statuses (`:not_invited` where there is no row).
  defp current_draft(snapshot, spec) do
    for %{id: person_id} <- Enum.take_random(spec.persons, 3), into: %{} do
      {person_id,
       Map.new(spec.events, fn %{id: event_id} ->
         row =
           Enum.find(
             snapshot.invitations,
             &(&1.person_id == person_id and &1.event_id == event_id)
           )

         {event_id, if(row, do: row.status, else: :not_invited)}
       end)}
    end
  end

  # A random case (after `budget_breakdowns_test.exs`'s): 1–2 events; 0–6 persons with a
  # random certainty, age and want tier, each invited to each event with a random status
  # (or not invited); 0–3 +1s of random hosts, possible or confirmed, with random opt-outs;
  # 0–4 categories with 0–2 services; 0–3 offers of 0–4 lines each — flat or per-person on
  # a random event (sometimes none = invalid), service or ad hoc, mandatory or optional,
  # random included quantities and minimum charges; VAT inclusive or exclusive, a random
  # minimum spend, random status and invoicing complete; at most one planning pick where
  # nothing is confirmed; 0–3 invoices linked to a confirmed offer or unlinked; a random
  # target; a random overall budget or none. Every amount ≥ €0. Confirmed offers carry
  # `Selection.freeze/2`'s rows.
  defp random_case do
    events = for n <- 1..Enum.random(1..2), do: %{id: n}

    persons =
      for p <- 1..Enum.random(0..6)//1 do
        %{
          id: p,
          certainty: Enum.random([:certain, :likely, :uncertain]),
          age: Enum.random([:adult, :adult, :child]),
          want_tier: Enum.random([:yes, :maybe, :no, :obligated]),
          invitations:
            Enum.flat_map(events, fn ev ->
              case Enum.random([nil, :planned, :invited, :accepted, :declined]) do
                nil -> []
                status -> [{ev.id, status}]
              end
            end)
        }
      end

    plus_ones =
      if persons == [] do
        []
      else
        for n <- 1..Enum.random(0..3)//1 do
          %{
            id: 100 + n,
            host_id: Enum.random(persons).id,
            status: Enum.random([:possible, :confirmed]),
            age: Enum.random([:adult, :child]),
            opt_outs: for(ev <- events, :rand.uniform(3) == 1, do: ev.id)
          }
        end
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

    spec = %{
      events: events,
      persons: persons,
      plus_ones: plus_ones,
      categories: categories,
      budget: if(:rand.uniform(3) > 1, do: Enum.random(0..3_000_000))
    }

    %{snapshot: build_snapshot(spec), spec: spec}
  end

  defp random_line(id, services, events) do
    basis = Enum.random([:flat, :per_adult, :per_child, :per_attendee, :per_attendee])
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

    hosts =
      for p <- spec.persons do
        %Person{
          id: p.id,
          first_name: "P#{p.id}",
          certainty: p.certainty,
          age_category: p.age,
          want_tier: p.want_tier
        }
      end

    plus_ones =
      for g <- spec.plus_ones do
        host = Enum.find(spec.persons, &(&1.id == g.host_id))

        %Person{
          id: g.id,
          host_id: g.host_id,
          plus_one_status: g.status,
          age_category: g.age,
          certainty: host.certainty,
          want_tier: host.want_tier
        }
      end

    invitations =
      for p <- spec.persons, {event_id, status} <- p.invitations do
        %Invitation{id: p.id * 10 + event_id, person_id: p.id, event_id: event_id, status: status}
      end

    opt_outs =
      for g <- spec.plus_ones, event_id <- g.opt_outs do
        %PlusOneOptOut{id: g.id * 10 + event_id, person_id: g.id, event_id: event_id}
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
      persons: hosts ++ plus_ones,
      invitations: invitations,
      plus_one_opt_outs: opt_outs,
      categories: categories,
      services: services,
      offers: offers,
      offer_lines: lines,
      invoices: invoices,
      invoice_lines: invoice_lines,
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

  defp from_cents(c), do: WeddingPlanner.Money.new(Decimal.new(1, c, -2))
end
