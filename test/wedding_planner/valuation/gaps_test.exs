defmodule WeddingPlanner.Valuation.GapsTest do
  @moduledoc """
  `WeddingPlanner.Valuation.Gaps` (`CST-25`, `DR-49`, `DR-52`) on the normative offers
  (`WeddingPlanner.NormativeSnapshots`), including example **O3**'s engine half. The
  random-input oracle for gaps lives with the selection oracle in
  `WeddingPlanner.Valuation.SelectionTest`. Pure: no database.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.NormativeSnapshots, as: NS
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Valuation.Gaps
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Snapshot

  defp gaps(built) do
    for gap <- Gaps.for_offer(built.snapshot, built.offer),
        do: {gap.service.name, gap.severity, gap.reason}
  end

  defp line(id, state, service) do
    priced? = state in [:mandatory, :optional]

    %OfferLine{
      id: id,
      service_id: service.id,
      state: state,
      basis: if(priced?, do: :flat),
      amount: if(priced?, do: WeddingPlanner.Money.new(100)),
      enabled: false
    }
  end

  defp without_lines(built, numbers) do
    changes = for n <- numbers, do: {:delete, :offer_lines, n}

    %{
      built
      | snapshot: Snapshot.apply(built.snapshot, changes),
        lines: Map.drop(built.lines, numbers)
    }
  end

  test "Venue A: the only gap is Late-night snack, ask the vendor" do
    built = NS.snapshot(:venue_a)
    assert gaps(built) == [{"Late-night snack", :unknown, :unknown}]

    assert [%{service: %Service{} = service}] = Gaps.for_offer(built.snapshot, built.offer)
    assert service == built.services["Late-night snack"]
  end

  test "Caterer C has no gaps" do
    built = NS.snapshot(:caterer_c)
    assert gaps(built) == []
  end

  @tag example: "O3"
  test "O3: Venue B without Catering (no line, or a not-offered line) has a prominent must-have gap and no counted Catering line" do
    for {variant, reason} <- [no_line: :no_line, not_offered_line: :not_offered] do
      built = NS.snapshot({:venue_b, variant})
      catering = built.services["Catering"]

      assert gaps(built) == [
               {"Catering", :must_have, reason},
               {"Late-night snack", :unknown, :unknown}
             ],
             "variant #{variant}"

      counted = Selection.counted_lines(built.snapshot, built.offer)
      refute Enum.any?(counted, &(&1.service_id == catering.id)), "variant #{variant}"
      assert Enum.map(counted, & &1.id) == [2, 1, 7], "variant #{variant}"
    end
  end

  test "DR-52 (provisional): must-have with no line is prominent; nice-to-have with no line and must-have with only unknown lines ask the vendor" do
    # Must-have (Catering), no line at all → prominent (O3 wins over CST-25's wording).
    must_no_line = NS.snapshot({:venue_b, :no_line})
    assert {"Catering", :must_have, :no_line} in gaps(must_no_line)

    # Nice-to-have (Seating), no line at all → "ask the vendor" (CST-25).
    nice_no_line = NS.snapshot(:venue_a) |> without_lines([2])
    assert {"Seating", :unknown, :no_line} in gaps(nice_no_line)

    # Must-have (Catering) with only unknown lines → "ask the vendor" (CST-25).
    catering = must_no_line.services["Catering"]
    must_unknown = NS.put_line(must_no_line, line(9, :unknown, catering))
    assert {"Catering", :unknown, :unknown} in gaps(must_unknown)
  end

  describe "severity by priority (CST-25)" do
    test "must-have + not offered → prominent; nice-to-have + not offered → subtle" do
      built = NS.snapshot(:venue_a)

      built =
        built
        |> without_lines([3, 4])
        |> NS.put_line(line(3, :not_offered, built.services["Catering"]))
        |> NS.put_line(line(2, :not_offered, built.services["Seating"]))

      assert gaps(built) == [
               {"Seating", :nice_to_have, :not_offered},
               {"Catering", :must_have, :not_offered},
               {"Late-night snack", :unknown, :unknown}
             ]
    end
  end

  describe "CST-24 overrides" do
    test "an off override on a wanted service removes its gap" do
      built = NS.snapshot(:venue_a) |> NS.with_overrides([{"Late-night snack", false}])
      assert gaps(built) == []

      venue_b =
        NS.snapshot({:venue_b, :not_offered_line}) |> NS.with_overrides([{"Catering", false}])

      assert gaps(venue_b) == [{"Late-night snack", :unknown, :unknown}]
    end

    test "an on override on a not-wanted service with a not-offered line gives a subtle gap" do
      built = NS.snapshot(:venue_a)

      built =
        built
        |> NS.put_line(line(6, :not_offered, built.services["Garden ceremony"]))
        |> NS.with_overrides([{"Garden ceremony", true}])

      assert gaps(built) == [
               {"Garden ceremony", :nice_to_have, :not_offered},
               {"Late-night snack", :unknown, :unknown}
             ]
    end

    test "a not-wanted service gets no gap without an override" do
      built = NS.snapshot(:venue_a)
      built = NS.put_line(built, line(6, :not_offered, built.services["Garden ceremony"]))

      assert gaps(built) == [{"Late-night snack", :unknown, :unknown}]
    end

    test "a not-wanted service switched on with no line asks the vendor" do
      built =
        NS.snapshot(:venue_a)
        |> without_lines([6])
        |> NS.with_overrides([{"Garden ceremony", true}])

      assert gaps(built) == [
               {"Garden ceremony", :unknown, :no_line},
               {"Late-night snack", :unknown, :unknown}
             ]
    end

    test "overrides of another offer have no effect" do
      built = NS.snapshot({:venue_b, :not_offered_line})
      catering = built.services["Catering"]

      snapshot = %{
        built.snapshot
        | overrides: [%{offer_id: built.offer.id + 100, service_id: catering.id, wanted: false}]
      }

      assert [%{service: ^catering, severity: :must_have}, _] =
               Gaps.for_offer(snapshot, built.offer)
    end
  end

  describe "mixed lines for one service (DR-49)" do
    setup do
      built = NS.snapshot(:venue_a) |> without_lines([3, 4])
      %{built: built, catering: built.services["Catering"]}
    end

    test "a not-offered and an included line → no gap", %{built: built, catering: catering} do
      built =
        built
        |> NS.put_line(line(3, :not_offered, catering))
        |> NS.put_line(line(4, :included, catering))

      assert gaps(built) == [{"Late-night snack", :unknown, :unknown}]
    end

    test "an unknown and a not-offered line → reason not offered", %{
      built: built,
      catering: catering
    } do
      built =
        built
        |> NS.put_line(line(3, :unknown, catering))
        |> NS.put_line(line(4, :not_offered, catering))

      assert {"Catering", :must_have, :not_offered} in gaps(built)
    end

    test "an optional line that is not selected still provides (no gap)", %{
      built: built,
      catering: catering
    } do
      built =
        built
        |> NS.put_line(line(3, :not_offered, catering))
        |> NS.put_line(line(4, :optional, catering))

      refute Enum.any?(gaps(built), &match?({"Catering", _, _}, &1))
    end

    test "an invalid optional line (per-person, event deleted) is counted and prevents a gap",
         %{built: built, catering: catering} do
      invalid = %{line(3, :optional, catering) | basis: :per_adult, event_id: nil}
      assert OfferLine.invalid?(invalid)
      built = NS.put_line(built, invalid)

      assert Selection.inclusion(built.snapshot, built.offer, built.lines[3]) == :counted
      assert gaps(built) == [{"Late-night snack", :unknown, :unknown}]
    end
  end

  test "gaps come in service order and only for the offer's category" do
    offer = %Offer{id: 1, category_id: :c}

    services = [
      %Service{id: 1, category_id: :c, name: "late", sort_order: 9, wanted_priority: :must_have},
      %Service{
        id: 50,
        category_id: :c,
        name: "early",
        sort_order: 0,
        wanted_priority: :nice_to_have
      },
      %Service{id: 7, category_id: :c, name: "mid-b", sort_order: 4, wanted_priority: :must_have},
      %Service{
        id: 3,
        category_id: :c,
        name: "mid-a",
        sort_order: 4,
        wanted_priority: :nice_to_have
      },
      %Service{
        id: 2,
        category_id: :other,
        name: "elsewhere",
        sort_order: 0,
        wanted_priority: :nice_to_have
      }
    ]

    [late, _early, mid_b | _] = services

    lines =
      for {id, state, service} <- [{1, :not_offered, late}, {2, :unknown, mid_b}],
          do: %{line(id, state, service) | offer_id: offer.id}

    snapshot = %Snapshot{services: Enum.reverse(services), offers: [offer], offer_lines: lines}

    assert gaps(%{snapshot: snapshot, offer: offer}) == [
             {"early", :unknown, :no_line},
             {"mid-a", :unknown, :no_line},
             {"mid-b", :unknown, :unknown},
             {"late", :must_have, :not_offered}
           ]
  end
end
