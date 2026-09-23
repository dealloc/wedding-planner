defmodule WeddingPlanner.Valuation.OfferDbTest do
  @moduledoc """
  The offer cost engine over **real database rows** (`CST-36`, `DR-50`): the frozen
  normative offers entered through the contexts (`WeddingPlanner.NormativeOfferRows`,
  typed values only — `DR-18`, `DR-46`), read back with
  `WeddingPlanner.Valuation.Snapshot.load/1`, then priced by
  `WeddingPlanner.Valuation.Offer.total/4` through the `headcount:` test seam.

  Not tagged `example:` — the pure tests in `WeddingPlanner.Valuation.OfferTest` carry the
  O1–O6 tags; these prove the same figures survive storage and the loader.
  """
  use WeddingPlanner.DataCase, async: true

  import WeddingPlanner.OfferFixtures, only: [scope_fixture: 0]

  alias WeddingPlanner.NormativeExamples
  alias WeddingPlanner.NormativeOfferRows, as: Rows
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Offer
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot

  setup do
    scope = scope_fixture()
    %{scope: scope, dinner: Rows.dinner!(scope)}
  end

  defp preset(name), do: Enum.find(Preset.defaults(), &(&1.name == name))

  defp loaded_offer(snapshot, %{offer: %{id: id}}), do: Enum.find(snapshot.offers, &(&1.id == id))

  defp total!(snapshot, entered, preset_name) do
    %Formula{total: {:money, money}} =
      Offer.total(snapshot, loaded_offer(snapshot, entered), preset(preset_name),
        headcount: WeddingPlanner.NormativeExamples.fixed_headcount()
      )

    money
  end

  defp assert_money(actual, expected, what) do
    assert Money.equal?(actual, expected),
           "#{what}: expected #{Money.to_string!(expected)}, got #{Money.to_string!(actual)}"
  end

  @tag :real_path
  test "Venue A and Caterer C as rows: € 11.726 / € 11.478 / € 7.641,50 / € 7.000,00",
       %{scope: scope, dinner: dinner} do
    {venue, venue_services} = Rows.category!(scope, NormativeExamples.venue_category())
    {catering, catering_services} = Rows.category!(scope, NormativeExamples.catering_category())

    venue_a = Rows.offer!(scope, :venue_a, venue, venue_services, dinner)
    caterer_c = Rows.offer!(scope, :caterer_c, catering, catering_services, dinner)

    snapshot = Snapshot.load(Repo)

    assert_money(
      total!(snapshot, venue_a, "Likely"),
      NormativeExamples.expected("O1").total,
      "O1"
    )

    assert_money(
      total!(snapshot, venue_a, "Minimum"),
      NormativeExamples.expected("O2").total,
      "O2"
    )

    assert_money(
      total!(snapshot, caterer_c, "Likely"),
      NormativeExamples.expected("O4").total,
      "O4"
    )

    assert_money(
      total!(snapshot, caterer_c, "Minimum"),
      NormativeExamples.expected("O5").total,
      "O5"
    )
  end

  @tag :real_path
  test "Venue B as rows (both variants): total(A) − the two Catering lines",
       %{scope: scope, dinner: dinner} do
    {venue, services} = Rows.category!(scope, NormativeExamples.venue_category())

    venue_a = Rows.offer!(scope, :venue_a, venue, services, dinner)
    no_line = Rows.offer!(scope, {:venue_b, :no_line}, venue, services, dinner)
    not_offered = Rows.offer!(scope, {:venue_b, :not_offered_line}, venue, services, dinner)

    snapshot = Snapshot.load(Repo)
    lines = NormativeExamples.venue_a().lines

    for preset_name <- ["Likely", "Minimum"], venue_b <- [no_line, not_offered] do
      catering =
        lines
        |> Enum.filter(&(&1.service == "Catering"))
        |> Enum.map(& &1.result[preset_name])
        |> Enum.reduce(&Money.add!/2)

      expected = Money.sub!(total!(snapshot, venue_a, preset_name), catering)
      assert_money(total!(snapshot, venue_b, preset_name), expected, "Venue B #{preset_name}")
    end
  end
end
