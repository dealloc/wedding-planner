defmodule WeddingPlanner.NormativeSnapshotsTest do
  @moduledoc """
  Self-check of `WeddingPlanner.NormativeSnapshots`: the structs it builds mirror
  `WeddingPlanner.NormativeExamples`' frozen maps field by field, so a mapping slip
  (a wrong service, a dropped modifier, a rate off by 100×) fails here instead of
  silently becoming the cost engine's input. A transcription check, not an example:
  tagged `:normative_fixture`, never `example:`.
  """
  use ExUnit.Case, async: true

  @moduletag :normative_fixture

  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeSnapshots
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine

  defp same_money?(nil, nil), do: true

  defp same_money?(%Money{} = built, %Money{} = frozen) do
    Money.equal?(built, frozen) and
      Decimal.to_string(built.amount, :raw) == Decimal.to_string(frozen.amount, :raw)
  end

  defp same_money?(_built, _frozen), do: false

  defp same_rate?(nil, nil), do: true
  defp same_rate?(%Decimal{} = built, %Decimal{} = frozen), do: Decimal.equal?(built, frozen)
  defp same_rate?(_built, _frozen), do: false

  defp assert_category(built, category_map) do
    services = Enum.sort_by(built.snapshot.services, & &1.sort_order)
    offer = built.offer

    assert Enum.map(services, &{&1.name, &1.wanted_priority}) ==
             Enum.map(category_map.services, &{&1.name, &1.priority})

    assert Enum.map(services, & &1.sort_order) == Enum.to_list(0..(length(services) - 1))
    assert Enum.all?(services, &(&1.category_id == offer.category_id))
    assert [%{id: category_id, name: name}] = built.snapshot.categories
    assert category_id == offer.category_id
    assert name == category_map.name
    assert Map.keys(built.services) |> Enum.sort() == Enum.map(services, & &1.name) |> Enum.sort()
    assert [%{name: "Dinner"} = event] = built.snapshot.events
    assert event == built.event
    assert built.snapshot.offers == [offer]
    assert built.snapshot.overrides == []
  end

  defp assert_offer(built, offer_map, vendor) do
    offer = built.offer
    assert %Offer{} = offer
    assert offer.vendor_name == vendor
    assert offer.vat_basis == offer_map.vat_basis
    assert same_rate?(Offer.vat_rate(offer), offer_map.default_vat_rate)
    assert same_money?(offer.minimum_spend, offer_map.minimum_spend)
  end

  defp assert_lines(built, line_maps) do
    service_names = Map.new(built.services, fn {name, service} -> {service.id, name} end)

    assert built.snapshot.offer_lines |> Enum.map(& &1.id) |> Enum.sort() ==
             line_maps |> Enum.map(& &1.number) |> Enum.sort()

    assert Map.new(built.snapshot.offer_lines, &{&1.id, &1}) == built.lines

    for map <- line_maps do
      line = Map.fetch!(built.lines, map.number)
      where = "line #{map.number} of #{built.offer.vendor_name}"

      assert %OfferLine{} = line
      assert line.offer_id == built.offer.id, where
      assert service_names[line.service_id] == map.service, where

      if map.service,
        do: assert(is_nil(line.label), where),
        else: assert(line.label == map.label, where)

      assert line.state == map.state, where
      assert line.basis == map.basis, where
      assert line.event_id == if(map.event, do: built.event.id), where
      assert same_money?(line.amount, map.amount), where
      assert line.included_quantity == map.included, where
      assert same_money?(line.minimum_charge, map.minimum_charge), where
      assert same_rate?(OfferLine.vat_rate(line), map.vat_rate), where
      assert line.enabled == false, where
    end
  end

  test "Venue A mirrors the frozen category and its eight lines" do
    built = NormativeSnapshots.snapshot(:venue_a)
    offer_map = NE.venue_a()

    assert_category(built, NE.venue_category())
    assert_offer(built, offer_map, "Venue A")
    assert_lines(built, offer_map.lines)
  end

  test "Caterer C mirrors the frozen category and its four lines (rates in basis points)" do
    built = NormativeSnapshots.snapshot(:caterer_c)
    offer_map = NE.caterer_c()

    assert_category(built, NE.catering_category())
    assert_offer(built, offer_map, "Caterer C")
    assert_lines(built, offer_map.lines)

    assert built.offer.vat_rate_bp == 2100
    assert built.lines[1].vat_rate_bp == 1200
    assert built.lines[2].vat_rate_bp == 1200
    assert built.lines[3].vat_rate_bp == nil
    assert built.lines[4].vat_rate_bp == nil
  end

  test "Venue B (no line) is Venue A without its two Catering lines" do
    built = NormativeSnapshots.snapshot({:venue_b, :no_line})
    venue_a = NE.venue_a()

    assert_category(built, NE.venue_category())
    assert_offer(built, venue_a, NE.venue_b().vendor)
    assert_lines(built, Enum.reject(venue_a.lines, &(&1.number in [3, 4])))
    assert built.offer.id != NormativeSnapshots.snapshot(:venue_a).offer.id
  end

  test "Venue B (not offered line) adds one not-offered Catering line and nothing else" do
    built = NormativeSnapshots.snapshot({:venue_b, :not_offered_line})
    venue_a = NE.venue_a()
    id = NormativeSnapshots.venue_b_not_offered_line_id()

    assert_category(built, NE.venue_category())
    assert_offer(built, venue_a, NE.venue_b().vendor)

    assert_lines(
      built,
      Enum.reject(venue_a.lines, &(&1.number in [3, 4]))
      |> Enum.concat([
        %{
          number: id,
          label: "Catering",
          service: "Catering",
          state: :not_offered,
          basis: nil,
          event: nil,
          amount: nil,
          included: nil,
          minimum_charge: nil,
          vat_rate: nil
        }
      ])
    )
  end
end
