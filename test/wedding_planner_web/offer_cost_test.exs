defmodule WeddingPlannerWeb.OfferCostTest do
  @moduledoc """
  `WeddingPlannerWeb.OfferCost.build/3` (task 57/60, `DR-51`, `DR-54`) over in-memory
  snapshots — no database, the same style `WeddingPlanner.Valuation.OfferTest`/
  `HeadcountTest` use for the pure engines this module composes. Exercises the
  **production** headcount path (real `Person`/`Invitation` rows, no `headcount:` seam)
  together with `WeddingPlanner.Valuation.Offer.total/3` and
  `WeddingPlanner.Valuation.Gaps.for_offer/2`, so this is also the one place proving the
  three actually compose correctly.

  Presets are found by **id**, never by name (`DR-54`, `WeddingPlanner.Valuation.PresetChoice`)
  — the fixture presets below carry explicit ids for that reason (`WeddingPlanner.Valuation.Preset.defaults/0`
  itself leaves `id: nil`, since it describes the table, not stored rows).
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

  @dinner %Event{couple_attends: false, id: 1, name: "Dinner", sort_order: 0}

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

  defp nbsp, do: <<0xA0::utf8>>
  defp eur(str), do: "€#{nbsp()}#{str}"

  # Stored presets, carrying explicit ids (DR-54's lookup key) — otherwise
  # `Preset.defaults/0`'s three entries, roles included.
  @minimum_preset %{Enum.at(Preset.defaults(), 0) | id: 1}
  @likely_preset %{Enum.at(Preset.defaults(), 1) | id: 2}
  @maximum_preset %{Enum.at(Preset.defaults(), 2) | id: 3}
  @all_presets [@minimum_preset, @likely_preset, @maximum_preset]

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

  defp base_snapshot(headcount_presets \\ @all_presets) do
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
      cost = OfferCost.build(snapshot, 100, @likely_preset.id)

      assert cost.range == %{minimum: eur("200,00"), maximum: eur("400,00")}
    end

    test "a nil selected id defaults to the likely-role preset (€ 300,00)", %{
      snapshot: snapshot
    } do
      cost = OfferCost.build(snapshot, 100, nil)

      assert cost.selected.id == @likely_preset.id
      assert cost.selected.name == "Likely"
      assert cost.selected.formula_assigns.total == eur("300,00")
    end

    test "selecting by id changes the selected total (Minimum: € 200,00)", %{
      snapshot: snapshot
    } do
      cost = OfferCost.build(snapshot, 100, @minimum_preset.id)

      assert cost.selected.id == @minimum_preset.id
      assert cost.selected.name == "Minimum"
      assert cost.selected.formula_assigns.total == eur("200,00")
    end

    test "selecting by the id's string form (as a radio submits it) works the same", %{
      snapshot: snapshot
    } do
      cost = OfferCost.build(snapshot, 100, to_string(@minimum_preset.id))

      assert cost.selected.name == "Minimum"
    end

    test "a stale selected id falls back to the default (Likely)", %{snapshot: snapshot} do
      cost = OfferCost.build(snapshot, 100, 999)

      assert cost.selected.name == "Likely"
    end

    test "presets lists every stored preset by id and name", %{snapshot: snapshot} do
      cost = OfferCost.build(snapshot, 100, nil)

      assert cost.presets == [
               %{id: 1, name: "Minimum"},
               %{id: 2, name: "Likely"},
               %{id: 3, name: "Maximum"}
             ]
    end

    test "gaps: must-have no-line (prominent), nice-to-have not-offered (subtle), unknown (ask the vendor), in service order",
         %{snapshot: snapshot} do
      cost = OfferCost.build(snapshot, 100, nil)

      assert [
               %{service: %{name: "Catering"}, severity: :must_have, reason: :no_line},
               %{service: %{name: "Music"}, severity: :nice_to_have, reason: :not_offered},
               %{service: %{name: "DJ"}, severity: :unknown, reason: :unknown}
             ] = cost.gaps
    end

    test "the providing Venue service is not among the gaps", %{snapshot: snapshot} do
      cost = OfferCost.build(snapshot, 100, nil)

      refute Enum.any?(cost.gaps, &(&1.service.name == "Venue rental"))
    end
  end

  describe "no stored presets at all" do
    test "no presets, no selected figure, no range, but gaps still render" do
      snapshot = base_snapshot([])

      cost = OfferCost.build(snapshot, 100, nil)

      assert cost.presets == []
      assert cost.selected == nil
      assert cost.range == nil
      assert length(cost.gaps) == 3
    end
  end

  describe "a role unassigned (DR-54)" do
    test "no maximum-role preset: no range, but the selected figure still shows" do
      # Only Minimum and Likely carry their role — as if the Maximum-role preset had
      # been deleted (HC-06: every preset, role holders included, is deletable).
      presets = [@minimum_preset, @likely_preset]
      snapshot = base_snapshot(presets)

      cost = OfferCost.build(snapshot, 100, nil)

      assert cost.range == nil
      assert cost.selected.name == "Likely"
      assert cost.selected.formula_assigns.total == eur("300,00")
    end
  end

  test "raises for an offer id not in the snapshot" do
    snapshot = base_snapshot()

    assert_raise ArgumentError, fn ->
      OfferCost.build(snapshot, 999, nil)
    end
  end
end
