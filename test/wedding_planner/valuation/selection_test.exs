defmodule WeddingPlanner.Valuation.SelectionTest do
  @moduledoc """
  `WeddingPlanner.Valuation.Selection`: which lines count (`CST-21`, `CST-22`), effective
  selection with overrides (`CST-24`, `DR-49`) and `DR-41` order — on the normative
  offers (`WeddingPlanner.NormativeSnapshots`) and against a brute-force oracle over
  random offers. Pure: no database.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.NormativeSnapshots, as: NS
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Valuation.Gaps
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Snapshot

  defp ids(lines), do: Enum.map(lines, & &1.id)

  defp inclusion(built, number),
    do: Selection.inclusion(built.snapshot, built.offer, Map.fetch!(built.lines, number))

  defp counted(built), do: built.snapshot |> Selection.counted_lines(built.offer) |> ids()

  defp flat(id, state, opts) do
    %OfferLine{
      id: id,
      service_id: Keyword.get(opts, :service_id),
      label: Keyword.get(opts, :label),
      state: state,
      basis: if(state in [:mandatory, :optional], do: :flat),
      amount: if(state in [:mandatory, :optional], do: WeddingPlanner.Money.new(100)),
      enabled: Keyword.get(opts, :enabled, false)
    }
  end

  describe "Venue A (worked example)" do
    setup do: %{built: NS.snapshot(:venue_a)}

    test "lines come in DR-41 order: services in category order, then ad hoc by id", %{
      built: built
    } do
      assert built.snapshot |> Selection.lines(built.offer) |> ids() == [2, 3, 4, 5, 6, 8, 1, 7]
    end

    test "counted lines are Seating, Catering adult, Catering child, Base price, Cleaning fee",
         %{built: built} do
      assert counted(built) == [2, 3, 4, 1, 7]
    end

    test "Sound (included) and Late-night snack (unknown) are no-charge; Garden ceremony is not selected",
         %{built: built} do
      assert inclusion(built, 5) == :no_charge
      assert inclusion(built, 6) == :not_selected
      assert inclusion(built, 8) == :no_charge
      for n <- [1, 2, 3, 4, 7], do: assert(inclusion(built, n) == :counted)
    end

    test "effectively wanted follows the wanted priority without overrides (CST-24)", %{
      built: built
    } do
      wanted =
        for {name, service} <- built.services,
            Selection.effectively_wanted?(built.snapshot, built.offer, service),
            do: name

      assert Enum.sort(wanted) == ["Catering", "Late-night snack", "Seating", "Sound"]
    end
  end

  test "Caterer C: all four lines count (Drinks is optional and nice-to-have)" do
    built = NS.snapshot(:caterer_c)
    assert counted(built) == [1, 2, 3, 4]
    assert inclusion(built, 3) == :counted
  end

  describe "CST-24 overrides (DR-49 rows)" do
    setup do: %{built: NS.snapshot(:venue_a)}

    test "an off override on a wanted service drops its optional lines", %{built: built} do
      built = NS.with_overrides(built, [{"Catering", false}])

      refute Selection.effectively_wanted?(
               built.snapshot,
               built.offer,
               built.services["Catering"]
             )

      assert inclusion(built, 3) == :not_selected
      assert inclusion(built, 4) == :not_selected
      assert counted(built) == [2, 1, 7]
    end

    test "an on override on a not-wanted service adds its optional lines (Garden ceremony)", %{
      built: built
    } do
      built = NS.with_overrides(built, [{"Garden ceremony", true}])

      assert Selection.effectively_wanted?(
               built.snapshot,
               built.offer,
               built.services["Garden ceremony"]
             )

      assert inclusion(built, 6) == :counted
      assert counted(built) == [2, 3, 4, 6, 1, 7]
    end

    test "overrides of another offer have no effect", %{built: built} do
      catering = built.services["Catering"]
      garden = built.services["Garden ceremony"]

      snapshot = %{
        built.snapshot
        | overrides: [
            %{offer_id: built.offer.id + 100, service_id: catering.id, wanted: false},
            %{offer_id: built.offer.id + 100, service_id: garden.id, wanted: true}
          ]
      }

      assert Selection.counted_lines(snapshot, built.offer) |> ids() == [2, 3, 4, 1, 7]
      assert Selection.effectively_wanted?(snapshot, built.offer, catering)
      refute Selection.effectively_wanted?(snapshot, built.offer, garden)
    end

    test "a mandatory line on an overridden-off service still counts", %{built: built} do
      built = NS.with_overrides(built, [{"Seating", false}])

      refute Selection.effectively_wanted?(built.snapshot, built.offer, built.services["Seating"])
      assert inclusion(built, 2) == :counted
      assert counted(built) == [2, 3, 4, 1, 7]
    end

    test "a mandatory line on a not-wanted service counts (worked example)", %{built: built} do
      garden = built.services["Garden ceremony"]
      built = NS.put_line(built, flat(6, :mandatory, service_id: garden.id))

      assert inclusion(built, 6) == :counted
    end

    test "an override repeating the priority changes nothing", %{built: built} do
      built = NS.with_overrides(built, [{"Catering", true}, {"Garden ceremony", false}])
      assert counted(built) == [2, 3, 4, 1, 7]
    end

    test "if several rows match, the last one wins (documented, not guarded)", %{built: built} do
      off_then_on = NS.with_overrides(built, [{"Catering", false}, {"Catering", true}])
      on_then_off = NS.with_overrides(built, [{"Catering", true}, {"Catering", false}])

      assert inclusion(off_then_on, 3) == :counted
      assert inclusion(on_then_off, 3) == :not_selected
    end

    test "override rows may be structs with the DR-49 fields", %{built: built} do
      row = %{__struct__: FutureOverride, offer_id: built.offer.id, wanted: false}
      row = Map.put(row, :service_id, built.services["Catering"].id)
      snapshot = %{built.snapshot | overrides: [row]}

      assert Selection.inclusion(snapshot, built.offer, built.lines[3]) == :not_selected
    end
  end

  describe "CST-22 ad hoc lines" do
    setup do: %{built: NS.snapshot(:venue_a)}

    test "an optional ad hoc line counts iff its toggle is on", %{built: built} do
      off = NS.put_line(built, flat(10, :optional, label: "Fireworks", enabled: false))
      on = NS.put_line(built, flat(10, :optional, label: "Fireworks", enabled: true))

      assert inclusion(off, 10) == :not_selected
      assert counted(off) == [2, 3, 4, 1, 7]
      assert inclusion(on, 10) == :counted
      assert counted(on) == [2, 3, 4, 1, 7, 10]
    end

    test "a mandatory ad hoc line counts whatever its toggle", %{built: built} do
      assert built.lines[1].enabled == false
      assert inclusion(built, 1) == :counted
    end

    test "overrides never touch an ad hoc line's toggle", %{built: built} do
      built =
        built
        |> NS.put_line(flat(10, :optional, label: "Fireworks", enabled: true))
        |> NS.with_overrides(for name <- Map.keys(built.services), do: {name, false})

      assert inclusion(built, 10) == :counted
    end
  end

  describe "validity and state" do
    setup do: %{built: NS.snapshot(:venue_a)}

    test "an invalid optional line (per-person, event deleted) on a wanted service is counted",
         %{built: built} do
      line = %{built.lines[4] | event_id: nil}
      assert OfferLine.invalid?(line)
      built = NS.put_line(built, line)

      assert inclusion(built, 4) == :counted
    end

    test "not-offered is no-charge even for a wanted service", %{built: built} do
      built = NS.put_line(built, flat(3, :not_offered, service_id: built.services["Catering"].id))
      assert inclusion(built, 3) == :no_charge
    end
  end

  describe "DR-41 order" do
    test "services by sort_order then id, lines of one service by id, ad hoc by id — whatever the snapshot's list order" do
      [r1, r2, r3, r4] = for _ <- 1..4, do: make_ref()
      [l1, l2, l3, l4, l5, l6] = Enum.sort(for _ <- 1..6, do: make_ref())

      # `early` has the larger id but sorts first; `tie_a`/`tie_b` share a sort_order.
      late = %Service{id: 1, category_id: :c, sort_order: 5, wanted_priority: :must_have}
      early = %Service{id: 99, category_id: :c, sort_order: 0, wanted_priority: :must_have}
      [tie_a_id, tie_b_id] = Enum.sort([r1, r2])
      tie_a = %Service{id: tie_a_id, category_id: :c, sort_order: 3, wanted_priority: :must_have}
      tie_b = %Service{id: tie_b_id, category_id: :c, sort_order: 3, wanted_priority: :must_have}
      offer = %Offer{id: r3, category_id: :c}

      lines =
        for {id, service} <- [
              {l6, nil},
              {l2, late},
              {l5, tie_b},
              {l1, late},
              {l4, nil},
              {l3, early}
            ] do
          opts = if service, do: [service_id: service.id], else: [label: "ad hoc"]
          %{flat(id, :mandatory, opts) | offer_id: offer.id}
        end

      other = %{flat(make_ref(), :mandatory, service_id: early.id) | offer_id: r4}

      snapshot = %Snapshot{
        services: [tie_b, late, early, tie_a],
        offers: [offer],
        offer_lines: Enum.shuffle([other | lines])
      }

      assert Selection.lines(snapshot, offer) |> ids() == [l3, l5, l1, l2, l4, l6]
      assert Selection.services(snapshot, offer) == [early, tie_a, tie_b, late]

      # A what-if `:put` appends; the order still follows the rule.
      appended = %{flat(make_ref(), :mandatory, service_id: tie_a.id) | offer_id: offer.id}
      snapshot = Snapshot.apply(snapshot, {:put, :offer_lines, appended})

      assert Selection.lines(snapshot, offer) |> ids() == [l3, appended.id, l5, l1, l2, l4, l6]
    end

    test "a line whose service is missing from the snapshot raises" do
      offer = %Offer{id: 1, category_id: 1}
      line = %{flat(1, :optional, service_id: 42) | offer_id: 1}
      snapshot = %Snapshot{offers: [offer], offer_lines: [line]}

      assert_raise ArgumentError, ~r/service 42/, fn -> Selection.lines(snapshot, offer) end

      assert_raise ArgumentError, ~r/service 42/, fn ->
        Selection.inclusion(snapshot, offer, line)
      end
    end
  end

  # -- property tests against a brute-force oracle ------------------------------------------

  describe "property: random offers against a brute-force oracle" do
    @describetag :property

    @seed {55, 24, 25}
    @iterations 400

    test "inclusion/3, lines/2 and Gaps.for_offer/2 equal the oracle; invariants hold (400 cases)" do
      :rand.seed(:exsss, @seed)

      for iteration <- 1..@iterations do
        input = random_case()

        try do
          check_case(input)
        rescue
          error in ExUnit.AssertionError ->
            message =
              "seed #{inspect(@seed)}, iteration #{iteration}\n#{error.message}\ninput: " <>
                inspect(input, pretty: true, limit: :infinity)

            reraise %{error | message: message}, __STACKTRACE__
        end
      end
    end
  end

  defp check_case(%{snapshot: snapshot, offer: offer}) do
    own_lines = Enum.filter(snapshot.offer_lines, &(&1.offer_id == offer.id))

    # lines/2: the oracle's order.
    assert Selection.lines(snapshot, offer) |> ids() == oracle_order(snapshot, offer),
           "lines/2 order"

    # inclusion/3 per line.
    for line <- own_lines do
      assert Selection.inclusion(snapshot, offer, line) == oracle_inclusion(snapshot, offer, line),
             "inclusion of line #{inspect(line.id)}"
    end

    # counted_lines/2 is lines/2 filtered.
    assert Selection.counted_lines(snapshot, offer) |> ids() ==
             Enum.filter(
               oracle_order(snapshot, offer),
               fn id ->
                 line = Enum.find(own_lines, &(&1.id == id))
                 oracle_inclusion(snapshot, offer, line) == :counted
               end
             ),
           "counted_lines/2"

    # Gaps.for_offer/2.
    gaps = Gaps.for_offer(snapshot, offer)

    assert Enum.map(gaps, &{&1.service.id, &1.severity, &1.reason}) ==
             oracle_gaps(snapshot, offer),
           "gaps"

    for gap <- gaps, do: assert(gap.service in snapshot.services)

    # Invariant: a counted line is never in an unpriced state.
    for line <- Selection.counted_lines(snapshot, offer),
        do: assert(line.state in [:mandatory, :optional], "counted unpriced line")

    # Invariant: a service with a gap has no line in a providing state.
    for gap <- gaps, line <- own_lines, line.service_id == gap.service.id do
      refute line.state in [:included, :optional, :mandatory], "gap despite a providing line"
    end

    # Invariant: overrides never change a mandatory line's counting, nor the gap of a
    # service no override row names for this offer.
    bare = %{snapshot | overrides: []}

    for line <- own_lines, line.state == :mandatory do
      assert Selection.inclusion(snapshot, offer, line) == :counted
      assert Selection.inclusion(bare, offer, line) == :counted
    end

    overridden =
      for row <- snapshot.overrides,
          row.offer_id == offer.id,
          into: MapSet.new(),
          do: row.service_id

    untouched = fn gap_list ->
      Enum.reject(gap_list, &MapSet.member?(overridden, &1.service.id))
    end

    assert untouched.(gaps) == untouched.(Gaps.for_offer(bare, offer)), "overrides leaked"
  end

  # The oracle below shares no code with `Selection`/`Gaps`: it is written from the rule
  # text of CST-21, CST-22, CST-24, CST-25 and DR-41/DR-49/DR-52 directly.

  # CST-24, literally: wanted if nice-to-have or must-have, "unless an override for that
  # offer turns it off, or it is not wanted and an override turns it on". DR-49: several
  # rows → the last wins.
  defp oracle_wanted?(snapshot, offer, service) do
    by_priority = service.wanted_priority != :not_wanted

    override =
      Enum.reduce(snapshot.overrides, :none, fn row, acc ->
        if row.offer_id == offer.id and row.service_id == service.id, do: row.wanted, else: acc
      end)

    cond do
      by_priority and override == false -> false
      not by_priority and override == true -> true
      true -> by_priority
    end
  end

  # CST-21 table + CST-22 + the worked example's "Mandatory lines count regardless".
  defp oracle_inclusion(snapshot, offer, line) do
    case {line.state, line.service_id} do
      {:mandatory, _} ->
        :counted

      {:optional, nil} ->
        if line.enabled, do: :counted, else: :not_selected

      {:optional, service_id} ->
        service = Enum.find(snapshot.services, &(&1.id == service_id))
        if oracle_wanted?(snapshot, offer, service), do: :counted, else: :not_selected

      {state, _} when state in [:included, :not_offered, :unknown] ->
        :no_charge
    end
  end

  # CST-02 service order, grouped rather than sorted by a compound key.
  defp oracle_services(snapshot, offer) do
    snapshot.services
    |> Enum.filter(&(&1.category_id == offer.category_id))
    |> Enum.group_by(& &1.sort_order)
    |> Enum.sort_by(fn {sort_order, _} -> sort_order end)
    |> Enum.flat_map(fn {_, services} -> Enum.sort_by(services, & &1.id) end)
  end

  # DR-41: per service in order, its lines by id; then ad hoc lines by id.
  defp oracle_order(snapshot, offer) do
    own = Enum.filter(snapshot.offer_lines, &(&1.offer_id == offer.id))

    by_service =
      for service <- oracle_services(snapshot, offer),
          line <- own |> Enum.filter(&(&1.service_id == service.id)) |> Enum.sort_by(& &1.id),
          do: line.id

    ad_hoc = for line <- Enum.sort_by(own, & &1.id), is_nil(line.service_id), do: line.id
    by_service ++ ad_hoc
  end

  # CST-25 with DR-49's reading and DR-52's provisional must-have/no-line case.
  defp oracle_gaps(snapshot, offer) do
    own = Enum.filter(snapshot.offer_lines, &(&1.offer_id == offer.id))

    for service <- oracle_services(snapshot, offer),
        oracle_wanted?(snapshot, offer, service),
        states = for(l <- own, l.service_id == service.id, do: l.state),
        not Enum.any?(states, &(&1 in [:included, :optional, :mandatory])) do
      must? = service.wanted_priority == :must_have

      cond do
        :not_offered in states ->
          {service.id, if(must?, do: :must_have, else: :nice_to_have), :not_offered}

        states != [] ->
          {service.id, :unknown, :unknown}

        # DR-52 (provisional, open user question): must-have with no line → prominent.
        # If the user sides with CST-25, delete this clause along with Gaps' one.
        must? ->
          {service.id, :must_have, :no_line}

        true ->
          {service.id, :unknown, :no_line}
      end
    end
  end

  # -- random input -------------------------------------------------------------------------

  @priorities [:not_wanted, :nice_to_have, :must_have]
  @states [:included, :optional, :mandatory, :not_offered, :unknown]
  @bases [:flat, :per_adult, :per_child, :per_attendee]

  defp pick(list), do: Enum.at(list, :rand.uniform(length(list)) - 1)

  defp unique_ids(count, range), do: range |> Enum.take_random(count)

  defp random_case do
    n = :rand.uniform(8)
    other_n = :rand.uniform(3) - 1
    service_ids = unique_ids(n + other_n, 1..60)
    {own_ids, other_ids} = Enum.split(service_ids, n)

    services =
      for id <- own_ids do
        %Service{
          id: id,
          category_id: :cat,
          name: "S#{id}",
          wanted_priority: pick(@priorities),
          sort_order: :rand.uniform(4)
        }
      end

    other_services =
      for id <- other_ids do
        %Service{
          id: id,
          category_id: :other_cat,
          name: "O#{id}",
          wanted_priority: pick(@priorities),
          sort_order: 0
        }
      end

    offer = %Offer{id: :offer, category_id: :cat}
    other_offer = %Offer{id: :other_offer, category_id: :cat}

    line_count = :rand.uniform(13) - 1
    other_count = :rand.uniform(4) - 1
    line_ids = unique_ids(line_count + other_count, 1..500)
    {own_line_ids, other_line_ids} = Enum.split(line_ids, line_count)

    lines =
      for id <- own_line_ids, do: random_line(id, offer.id, own_ids)

    other_lines =
      for id <- other_line_ids, do: random_line(id, other_offer.id, own_ids)

    overrides =
      for _ <- 1..(:rand.uniform(7) - 1)//1 do
        %{
          offer_id: pick([offer.id, offer.id, other_offer.id]),
          service_id: pick(service_ids),
          wanted: pick([true, false])
        }
      end

    snapshot = %Snapshot{
      services: Enum.shuffle(services ++ other_services),
      offers: [offer, other_offer],
      offer_lines: Enum.shuffle(lines ++ other_lines),
      overrides: overrides
    }

    %{snapshot: snapshot, offer: offer}
  end

  defp random_line(id, offer_id, service_ids) do
    ad_hoc? = :rand.uniform(4) == 1
    state = if ad_hoc?, do: pick([:mandatory, :optional]), else: pick(@states)
    priced? = state in [:mandatory, :optional]
    basis = if priced?, do: pick(@bases)

    %OfferLine{
      id: id,
      offer_id: offer_id,
      service_id: if(ad_hoc?, do: nil, else: pick(service_ids)),
      label: if(ad_hoc?, do: "ad hoc #{id}"),
      state: state,
      basis: basis,
      # A per-person line without an event is invalid (XC-41); selection ignores it.
      event_id: if(basis not in [nil, :flat] and :rand.uniform(3) > 1, do: 1),
      amount: if(priced?, do: WeddingPlanner.Money.new(:rand.uniform(500))),
      enabled: pick([true, false])
    }
  end
end
