defmodule WeddingPlanner.Valuation.SelectionOverrideDbTest do
  @moduledoc """
  `WeddingPlanner.Offers.toggle_override/3` over **real database rows**, read back with
  `WeddingPlanner.Valuation.Snapshot.load/1` (`CST-24`, `DR-49`, `DR-56`): a stored row
  changes `Valuation.Selection.effectively_wanted?/3`'s answer, and so
  `Valuation.Gaps.for_offer/2`'s gaps, through the loader — the round trip the pure
  `WeddingPlanner.Valuation.SelectionTest` cannot exercise (it never touches the
  database).
  """
  use WeddingPlanner.DataCase, async: true

  import WeddingPlanner.OfferFixtures, only: [scope_fixture: 0]

  alias WeddingPlanner.NormativeExamples
  alias WeddingPlanner.NormativeOfferRows, as: Rows
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Valuation.Gaps
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Snapshot

  setup do
    scope = scope_fixture()
    %{scope: scope, dinner: Rows.dinner!(scope)}
  end

  defp loaded_offer(snapshot, %{offer: %{id: id}}), do: Enum.find(snapshot.offers, &(&1.id == id))

  @tag :real_path
  test "Venue A with Late-night snack turned off: Selection reflects the row, Gaps.for_offer/2 no longer lists it",
       %{scope: scope, dinner: dinner} do
    {venue, services} = Rows.category!(scope, NormativeExamples.venue_category())
    venue_a = Rows.offer!(scope, :venue_a, venue, services, dinner)
    snack = Map.fetch!(services, "Late-night snack")

    baseline = Snapshot.load(Repo)
    offer = loaded_offer(baseline, venue_a)

    assert Selection.effectively_wanted?(baseline, offer, snack)

    assert Enum.any?(Gaps.for_offer(baseline, offer), fn gap ->
             gap.service.id == snack.id and gap.severity == :unknown and gap.reason == :unknown
           end)

    assert {:ok, %{wanted: false}} = Offers.toggle_override(scope, offer, snack)

    snapshot = Snapshot.load(Repo)
    offer = loaded_offer(snapshot, venue_a)

    assert [%{offer_id: offer_id, service_id: service_id, wanted: false}] = snapshot.overrides
    assert offer_id == offer.id
    assert service_id == snack.id

    refute Selection.effectively_wanted?(snapshot, offer, snack)
    refute Enum.any?(Gaps.for_offer(snapshot, offer), &(&1.service.id == snack.id))
  end
end
