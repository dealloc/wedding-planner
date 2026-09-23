defmodule WeddingPlannerWeb.OfferCostTest do
  @moduledoc """
  `WeddingPlannerWeb.OfferCost.build/3` (task 57, DR-51) over in-memory snapshots — no
  database, the same style `WeddingPlanner.Valuation.OfferTest`/`HeadcountTest` use for
  the pure engines this module composes. Exercises the **production** headcount path
  (real `Person`/`Invitation` rows, no `headcount:` seam) together with
  `WeddingPlanner.Valuation.Offer.total/3` and `WeddingPlanner.Valuation.Gaps.for_offer/2`,
  so this is also the one place proving the three actually compose correctly.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.OfferCost

  @dinner %Event{id: 1, name: "Dinner", sort_order: 0}

  # Four invited adults at Dinner: two *certain*, one *likely*, one *uncertain* — so
  # Minimum (2), Likely (3) and Maximum (4) are three genuinely different headcounts
  # (fail-proof 3 needs Maximum != Likely; a fixture with no *uncertain* person, like
  # `WeddingPlanner.NormativeGuests.shared_dinner!/2`, would make that assertion vacuous).
  @persons [
    %Person{id: 1, certainty: :certain},
    %Person{id: 2, certainty: :certain},
    %Person{id: 3, certainty: :likely},
    %Person{id: 4, certainty: :uncertain}
  ]

  @invitations for p <- @persons,
                   do: %Invitation{id: p.id, person_id: p.id, event_id: 1, status: :invited}

  # Must-have, providing (no gap) — the line under test.
  @venue %Service{
    id: 10,
    category_id: 1,
    name: "Venue rental",
    wanted_priority: :must_have,
    sort_order: 0
  }
  # Must-have, no line at all — DR-52's provisional prominent gap.
  @catering %Service{
    id: 11,
    category_id: 1,
    name: "Catering",
    wanted_priority: :must_have,
    sort_order: 1
  }
  # Nice-to-have, a `:not_offered` line — subtle gap.
  @music %Service{
    id: 12,
    category_id: 1,
    name: "Music",
    wanted_priority: :nice_to_have,
    sort_order: 2
  }
  # Nice-to-have, only an `:unknown` line — "ask the vendor" gap.
  @dj %Service{id: 13, category_id: 1, name: "DJ", wanted_priority: :nice_to_have, sort_order: 3}

  @services [@venue, @catering, @music, @dj]

  defp offer(attrs \\ %{}) do
    struct!(
      %Offer{
        id: 100,
        category_id: 1,
        vendor_name: "Test vendor",
        status: :considering,
        vat_basis: :inclusive
      },
      attrs
    )
  end

  # Venue rental: €100 per adult, no included quantity, no minimum charge.
  defp venue_line,
    do: %OfferLine{
      id: 1,
      offer_id: 100,
      service_id: 10,
      state: :mandatory,
      basis: :per_adult,
      amount: WeddingPlanner.Money.new(100),
      event_id: 1,
      enabled: false
    }

  defp music_line,
    do: %OfferLine{id: 2, offer_id: 100, service_id: 12, state: :not_offered, enabled: false}

  defp dj_line,
    do: %OfferLine{id: 3, offer_id: 100, service_id: 13, state: :unknown, enabled: false}

  defp base_snapshot(headcount_presets \\ Preset.defaults()) do
    %Snapshot{
      events: [@dinner],
      persons: @persons,
      invitations: @invitations,
      headcount_presets: headcount_presets,
      services: @services,
      offers: [offer()],
      offer_lines: [venue_line(), music_line(), dj_line()]
    }
  end

  describe "presets present" do
    setup do
      %{snapshot: base_snapshot()}
    end

    test "the range is Minimum..Maximum (€ 200,00 .. € 400,00)", %{snapshot: snapshot} do
      cost = OfferCost.build(snapshot, 100, "Likely")

      assert cost.presets_present?
      assert cost.range == %{minimum: "€ 200,00", maximum: "€ 400,00"}
    end

    test "the selected total is under the requested preset (Likely: € 300,00)", %{
      snapshot: snapshot
    } do
      cost = OfferCost.build(snapshot, 100, "Likely")

      assert cost.selected.name == "Likely"
      assert cost.selected.formula_assigns.total == "€ 300,00"
    end

    test "switching the requested preset changes the selected total (Minimum: € 200,00)", %{
      snapshot: snapshot
    } do
      cost = OfferCost.build(snapshot, 100, "Minimum")

      assert cost.selected.name == "Minimum"
      assert cost.selected.formula_assigns.total == "€ 200,00"
    end

    test "gaps: must-have no-line (prominent), nice-to-have not-offered (subtle), unknown (ask the vendor), in service order",
         %{snapshot: snapshot} do
      cost = OfferCost.build(snapshot, 100, "Likely")

      assert [
               %{service: %{name: "Catering"}, severity: :must_have, reason: :no_line},
               %{service: %{name: "Music"}, severity: :nice_to_have, reason: :not_offered},
               %{service: %{name: "DJ"}, severity: :unknown, reason: :unknown}
             ] = cost.gaps
    end

    test "the providing Venue service is not among the gaps", %{snapshot: snapshot} do
      cost = OfferCost.build(snapshot, 100, "Likely")

      refute Enum.any?(cost.gaps, &(&1.service.name == "Venue rental"))
    end
  end

  describe "a missing stored preset" do
    test "presets_present? is false, no range or selected total, but gaps still render" do
      # Only Minimum and Likely are "stored" — Maximum is missing, as it would be if its
      # row had been deleted out from under a saved preset (W9 has no CRUD to do this
      # through, so this is the only way it can happen).
      presets = Enum.reject(Preset.defaults(), &(&1.name == "Maximum"))
      snapshot = base_snapshot(presets)

      cost = OfferCost.build(snapshot, 100, "Likely")

      refute cost.presets_present?
      assert cost.range == nil
      assert cost.selected == nil
      assert length(cost.gaps) == 3
    end
  end

  test "raises for an offer id not in the snapshot" do
    snapshot = base_snapshot()

    assert_raise ArgumentError, fn ->
      OfferCost.build(snapshot, 999, "Likely")
    end
  end
end
