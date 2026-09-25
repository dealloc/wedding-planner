defmodule WeddingPlanner.Valuation.SelectionFrozenTest do
  @moduledoc """
  A confirmed offer's **frozen selection** in `WeddingPlanner.Valuation.Selection`
  (`docs/modules/offers-and-comparison.md` `CST-40`, `CST-41`, `CST-43`; `D-27`;
  `DR-49`, `DR-61`, `DR-63`, `DR-64`): what `freeze/2` captures, that confirming changes
  nothing at that moment, that nothing elsewhere in the category moves a confirmed total
  afterwards, and `CST-43`'s four cases.

  Pure: in-memory snapshots built on `WeddingPlanner.NormativeSnapshots.snapshot(:venue_a)`
  with the shared Dinner guests (`WeddingPlanner.NormativeInvoices.shared_guests/0`), so
  totals come from the real headcount and cost engines. Confirming is done as C5 does it —
  the offer's status plus one `%FrozenService{}` per id `Selection.freeze/2` gives on the
  pre-confirmation snapshot. The property tests use a hand-rolled generator with fixed
  `:rand` seeds (the `WeddingPlanner.Valuation.ComparisonTest` style, no StreamData).

  The O1/O2 figures after confirmation are deliberately **not** tagged `example:` (slice C3
  owns O1/O2's tags).
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.NormativeInvoices
  alias WeddingPlanner.NormativeSnapshots, as: NS
  alias WeddingPlanner.Offers.FrozenService
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Offers.Override
  alias WeddingPlanner.Valuation.Comparison
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Gaps
  alias WeddingPlanner.Valuation.Offer, as: OfferEngine
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Format

  @nbsp <<0xA0::utf8>>

  # -- helpers --------------------------------------------------------------------------------

  defp eur(amount), do: WeddingPlanner.Money.new(amount)

  # Venue A over the shared Dinner guests (Likely 72 + 6, Minimum 60 + 4) and the default
  # presets.
  defp venue_a do
    built = NS.snapshot(:venue_a)
    {persons, invitations} = NormativeInvoices.shared_guests()

    snapshot = %{
      built.snapshot
      | persons: persons,
        invitations: invitations,
        headcount_presets: Preset.defaults()
    }

    %{built | snapshot: snapshot}
  end

  defp preset(name), do: NormativeInvoices.preset(name)

  defp total(snapshot, offer, preset_name) do
    %Formula{total: {:money, %Money{} = money}} =
      OfferEngine.total(snapshot, offer, preset(preset_name))

    money
  end

  defp formatted(snapshot, offer, preset_name),
    do: snapshot |> total(offer, preset_name) |> Format.money()

  defp service_ids(built, names), do: Enum.map(names, &Map.fetch!(built.services, &1).id)

  # CST-40: confirming as C5 does it — the status and one frozen row per `freeze/2` id,
  # computed on the snapshot *before* the confirmation.
  defp confirm(snapshot, offer) do
    confirmed = %{offer | status: :confirmed}

    frozen_row_puts =
      for service_id <- Selection.freeze(snapshot, offer) do
        {:put, :frozen_services,
         %FrozenService{id: make_ref(), offer_id: offer.id, service_id: service_id}}
      end

    {Snapshot.apply(snapshot, [{:put, :offers, confirmed}] ++ frozen_row_puts), confirmed}
  end

  defp confirmed_venue_a do
    built = venue_a()
    {snapshot, offer} = confirm(built.snapshot, built.offer)
    %{built | snapshot: snapshot, offer: offer}
  end

  defp put_line(snapshot, %OfferLine{} = line),
    do: Snapshot.apply(snapshot, {:put, :offer_lines, line})

  defp flat_line(offer, attrs) do
    struct!(
      %OfferLine{
        id: make_ref(),
        offer_id: offer.id,
        basis: :flat,
        enabled: false
      },
      attrs
    )
  end

  defp assert_grew_by(before, later, amount) do
    assert Money.equal?(Money.sub!(later, before), amount),
           "expected #{Format.money(before)} + #{Format.money(amount)}, got #{Format.money(later)}"
  end

  # -- 1. what a confirmation captures -------------------------------------------------------

  describe "freeze/2 (CST-40, DR-61)" do
    test "Venue A freezes Seating, Catering, Sound and Late-night snack, in service order" do
      built = venue_a()

      assert Selection.freeze(built.snapshot, built.offer) ==
               service_ids(built, ["Seating", "Catering", "Sound", "Late-night snack"])
    end

    test "an override turning Sound off leaves Sound out" do
      built = NS.with_overrides(venue_a(), [{"Sound", false}])

      assert Selection.freeze(built.snapshot, built.offer) ==
               service_ids(built, ["Seating", "Catering", "Late-night snack"])
    end

    test "an override turning Garden ceremony on takes it in" do
      built = NS.with_overrides(venue_a(), [{"Garden ceremony", true}])

      assert Selection.freeze(built.snapshot, built.offer) ==
               service_ids(built, [
                 "Seating",
                 "Catering",
                 "Sound",
                 "Garden ceremony",
                 "Late-night snack"
               ])
    end

    test "follows the priority + override rule whatever the offer's status (its frozen rows are not consulted)" do
      built = confirmed_venue_a()
      # Drop every frozen row: the confirmed offer's scope is now empty, but freeze/2
      # still answers the priority + override rule.
      snapshot = %{built.snapshot | frozen_services: []}

      assert Selection.freeze(snapshot, built.offer) ==
               service_ids(built, ["Seating", "Catering", "Sound", "Late-night snack"])
    end
  end

  # -- 2. / 3. properties ---------------------------------------------------------------------

  describe "property: confirming (CST-40)" do
    @describetag :property

    test "confirming changes nothing at that moment: totals (Likely, Minimum) and gaps, 300 cases" do
      flags =
        for_each_case({101, 102, 103}, 300, fn %{snapshot: snapshot, offer: offer} ->
          {after_snapshot, confirmed} = confirm(snapshot, offer)

          for name <- ["Likely", "Minimum"] do
            assert OfferEngine.total(after_snapshot, confirmed, preset(name)) ==
                     OfferEngine.total(snapshot, offer, preset(name))
          end

          assert Gaps.for_offer(after_snapshot, confirmed) == Gaps.for_offer(snapshot, offer)

          case_flags(snapshot, offer)
        end)
        |> List.flatten()
        |> MapSet.new()

      # Not vacuous: the cases that could break the rule were all generated.
      for flag <- [
            :mandatory_line_of_unwanted_service,
            :optional_line_of_unwanted_service,
            :optional_line_of_wanted_service,
            :ad_hoc_on,
            :ad_hoc_off,
            :deviating_override
          ] do
        assert flag in flags, "#{inspect(flag)} never generated"
      end
    end

    test "nothing elsewhere in the category moves a confirmed total: priority changes and override puts/deletes, 300 cases" do
      changed_unconfirmed =
        for_each_case({111, 112, 113}, 300, fn %{snapshot: snapshot, offer: offer} ->
          {confirmed_snapshot, confirmed} = confirm(snapshot, offer)
          changes = random_changes(snapshot, offer)

          moved_confirmed = Snapshot.apply(confirmed_snapshot, changes)
          moved_unconfirmed = Snapshot.apply(snapshot, changes)

          for name <- ["Likely", "Minimum"] do
            assert Money.equal?(
                     total(moved_confirmed, confirmed, name),
                     total(confirmed_snapshot, confirmed, name)
                   ),
                   "#{name} moved after #{inspect(changes)}"
          end

          not Money.equal?(
            total(moved_unconfirmed, offer, "Likely"),
            total(snapshot, offer, "Likely")
          )
        end)
        |> Enum.count(& &1)

      # Guards a vacuous test: the same changes do move an unconfirmed copy's total.
      assert changed_unconfirmed > 0
    end
  end

  # -- 4. CST-41 --------------------------------------------------------------------------------

  describe "CST-41: the committed total still follows the guest list" do
    test "O1/O2 still hold after confirmation" do
      built = confirmed_venue_a()

      assert formatted(built.snapshot, built.offer, "Likely") == "€#{@nbsp}11.726,00"
      assert formatted(built.snapshot, built.offer, "Minimum") == "€#{@nbsp}11.478,00"
    end
  end

  # -- 5.–8. CST-43 -----------------------------------------------------------------------------

  describe "CST-43: lines stay editable on a confirmed offer" do
    test "case 1: a new optional line for a frozen-in service counts immediately" do
      built = confirmed_venue_a()
      before = total(built.snapshot, built.offer, "Likely")

      line =
        flat_line(built.offer,
          service_id: Map.fetch!(built.services, "Sound").id,
          state: :optional,
          amount: eur(275)
        )

      snapshot = put_line(built.snapshot, line)

      assert Selection.inclusion(snapshot, built.offer, line) == :counted
      assert_grew_by(before, total(snapshot, built.offer, "Likely"), eur(275))
    end

    test "case 2: a new optional line for a frozen-out service is :outside_scope, total unchanged" do
      built = confirmed_venue_a()
      before = total(built.snapshot, built.offer, "Likely")
      garden = Map.fetch!(built.services, "Garden ceremony")

      # Venue A's own Garden ceremony line (6) is outside the scope too.
      assert Selection.inclusion(built.snapshot, built.offer, Map.fetch!(built.lines, 6)) ==
               :outside_scope

      line = flat_line(built.offer, service_id: garden.id, state: :optional, amount: eur(900))
      snapshot = put_line(built.snapshot, line)

      assert Selection.inclusion(snapshot, built.offer, line) == :outside_scope
      refute Selection.effectively_wanted?(snapshot, built.offer, garden)
      assert Money.equal?(total(snapshot, built.offer, "Likely"), before)
    end

    test "case 2: a service created after the confirmation behaves the same" do
      built = confirmed_venue_a()
      before = total(built.snapshot, built.offer, "Likely")

      service = %Service{
        id: make_ref(),
        category_id: built.offer.category_id,
        name: "Fireworks",
        wanted_priority: :must_have,
        sort_order: 9
      }

      line = flat_line(built.offer, service_id: service.id, state: :optional, amount: eur(1200))

      snapshot =
        Snapshot.apply(built.snapshot, [
          {:put, :services, service},
          {:put, :offer_lines, line}
        ])

      assert Selection.inclusion(snapshot, built.offer, line) == :outside_scope
      refute Selection.effectively_wanted?(snapshot, built.offer, service)
      refute Selection.in_confirmed_scope?(snapshot, built.offer, service)
      assert Money.equal?(total(snapshot, built.offer, "Likely"), before)
    end

    test "case 3: a new optional ad hoc line starts off (:not_selected); turned on, it counts" do
      built = confirmed_venue_a()
      before = total(built.snapshot, built.offer, "Likely")

      off = flat_line(built.offer, label: "Corkage fee", state: :optional, amount: eur(180))
      snapshot = put_line(built.snapshot, off)

      assert Selection.inclusion(snapshot, built.offer, off) == :not_selected
      assert Money.equal?(total(snapshot, built.offer, "Likely"), before)

      on = %{off | enabled: true}
      snapshot = put_line(snapshot, on)

      assert Selection.inclusion(snapshot, built.offer, on) == :counted
      assert_grew_by(before, total(snapshot, built.offer, "Likely"), eur(180))
    end

    test "case 4: removing every line of a frozen-in service leaves it in scope, with a gap" do
      built = confirmed_venue_a()
      catering = Map.fetch!(built.services, "Catering")
      sound = Map.fetch!(built.services, "Sound")

      # Catering (must-have): lines 3 and 4. Sound (nice-to-have): line 5.
      snapshot =
        Snapshot.apply(built.snapshot, [
          {:delete, :offer_lines, 3},
          {:delete, :offer_lines, 4},
          {:delete, :offer_lines, 5}
        ])

      assert Selection.effectively_wanted?(snapshot, built.offer, catering)
      assert Selection.effectively_wanted?(snapshot, built.offer, sound)

      gaps = Gaps.for_offer(snapshot, built.offer)

      assert Enum.find(gaps, &(&1.service.id == catering.id)) ==
               %{service: catering, severity: :must_have, reason: :no_line}

      assert Enum.find(gaps, &(&1.service.id == sound.id)) ==
               %{service: sound, severity: :unknown, reason: :no_line}
    end
  end

  # -- 9. DR-63 ---------------------------------------------------------------------------------

  describe "DR-63 (decided by the user)" do
    # A mandatory charge added to a confirmed offer, for a service outside its confirmed
    # scope, counts straight away (CST-21 "Always") — the user, 2026-09-25.
    test "a mandatory line of a frozen-out service counts" do
      built = confirmed_venue_a()
      before = total(built.snapshot, built.offer, "Likely")
      garden = Map.fetch!(built.services, "Garden ceremony")

      line = flat_line(built.offer, service_id: garden.id, state: :mandatory, amount: eur(320))
      snapshot = put_line(built.snapshot, line)

      refute Selection.in_confirmed_scope?(snapshot, built.offer, garden)
      assert Selection.inclusion(snapshot, built.offer, line) == :counted
      assert_grew_by(before, total(snapshot, built.offer, "Likely"), eur(320))
    end
  end

  # -- 10. overrides dormant (DR-64) ------------------------------------------------------------

  describe "DR-64: a confirmed offer's overrides are dormant" do
    test "an override contradicting the frozen set loses; the matrix shows no override, and the scope" do
      built = confirmed_venue_a()
      before = total(built.snapshot, built.offer, "Likely")
      %{"Sound" => sound, "Garden ceremony" => garden} = built.services

      # Sound is frozen-in, Garden ceremony frozen-out; the rows say the opposite.
      contradicting = NS.with_overrides(built, [{"Sound", false}, {"Garden ceremony", true}])
      snapshot = contradicting.snapshot

      assert Selection.effectively_wanted?(snapshot, built.offer, sound)
      refute Selection.effectively_wanted?(snapshot, built.offer, garden)

      assert Selection.inclusion(snapshot, built.offer, Map.fetch!(built.lines, 6)) ==
               :outside_scope

      assert Money.equal?(total(snapshot, built.offer, "Likely"), before)

      matrix = Comparison.build(snapshot, built.offer.category_id, preset("Likely"), nil)
      cells = cells_by_service(matrix, built.offer)

      assert %{override: nil, scope: :in, effectively_wanted?: true} = cells[sound.id]
      assert %{override: nil, scope: :out, effectively_wanted?: false} = cells[garden.id]

      for {_id, cell} <- cells, do: assert(cell.override == nil)
    end
  end

  # -- 11. stray rows -------------------------------------------------------------------------

  describe "frozen rows on an offer that is not confirmed" do
    test "are ignored: a shortlisted offer with a stray row for Seating only behaves as without rows" do
      built = venue_a()
      offer = %{built.offer | status: :shortlisted}
      plain = Snapshot.apply(built.snapshot, {:put, :offers, offer})

      stray =
        Snapshot.apply(
          plain,
          {:put, :frozen_services,
           %FrozenService{
             id: make_ref(),
             offer_id: offer.id,
             service_id: Map.fetch!(built.services, "Seating").id
           }}
        )

      for service <- Selection.services(stray, offer) do
        assert Selection.effectively_wanted?(stray, offer, service) ==
                 Selection.effectively_wanted?(plain, offer, service)

        refute Selection.in_confirmed_scope?(stray, offer, service)
      end

      for line <- Selection.lines(stray, offer) do
        assert Selection.inclusion(stray, offer, line) == Selection.inclusion(plain, offer, line)
      end

      assert Money.equal?(total(stray, offer, "Likely"), total(plain, offer, "Likely"))
      assert Gaps.for_offer(stray, offer) == Gaps.for_offer(plain, offer)

      matrix = Comparison.build(stray, offer.category_id, preset("Likely"), nil)
      for {_id, cell} <- cells_by_service(matrix, offer), do: assert(cell.scope == nil)
    end
  end

  # -- 12. the snapshot collection ------------------------------------------------------------

  describe "Snapshot.apply/2 and :frozen_services" do
    test "a :put inserts or replaces in place, a :delete removes" do
      built = venue_a()
      a = %FrozenService{id: 1, offer_id: built.offer.id, service_id: 101}
      b = %FrozenService{id: 2, offer_id: built.offer.id, service_id: 102}

      snapshot =
        Snapshot.apply(built.snapshot, [{:put, :frozen_services, a}, {:put, :frozen_services, b}])

      assert snapshot.frozen_services == [a, b]

      moved = %{a | service_id: 103}
      snapshot = Snapshot.apply(snapshot, {:put, :frozen_services, moved})
      assert snapshot.frozen_services == [moved, b]

      snapshot = Snapshot.apply(snapshot, {:delete, :frozen_services, 1})
      assert snapshot.frozen_services == [b]

      assert built.snapshot.frozen_services == []
    end
  end

  # -- property-test helpers ------------------------------------------------------------------

  defp cells_by_service(matrix, offer) do
    for band <- matrix.bands, row <- band.rows, into: %{} do
      {row.service.id, Map.fetch!(row.cells, offer.id)}
    end
  end

  # Runs `fun` over `n` random cases from a fixed seed and returns its results; on failure,
  # names the seed, the iteration and the input.
  defp for_each_case(seed, n, fun) do
    :rand.seed(:exsss, seed)

    for iteration <- 1..n do
      c = random_case()

      try do
        fun.(c)
      rescue
        error in ExUnit.AssertionError ->
          input =
            inspect(
              %{
                offer: c.offer,
                services: c.snapshot.services,
                offer_lines: c.snapshot.offer_lines,
                overrides: c.snapshot.overrides
              },
              pretty: true,
              limit: :infinity
            )

          message =
            "#{error.message}\n\nseed #{inspect(seed)}, iteration #{iteration} of #{n}\ninput:\n#{input}"

          reraise %{error | message: message}, __STACKTRACE__
      end
    end
  end

  @priorities [:must_have, :nice_to_have, :not_wanted]
  @states [:included, :optional, :mandatory, :not_offered, :unknown]
  @bases [:flat, :per_adult, :per_child, :per_attendee]

  # Venue A's category, Dinner and guests, with 1–6 random services (random priorities,
  # colliding sort orders), one non-confirmed offer with 0–9 random lines in every state
  # (ad hoc lines on and off, mandatory lines of any service), random overrides and an
  # optional minimum spend.
  defp random_case do
    built = venue_a()
    category_id = built.offer.category_id

    services =
      for n <- 1..:rand.uniform(6) do
        %Service{
          id: 300 + n,
          category_id: category_id,
          name: "Service #{n}",
          wanted_priority: Enum.random(@priorities),
          sort_order: :rand.uniform(4)
        }
      end

    offer = %{
      built.offer
      | status: Enum.random([:considering, :shortlisted, :rejected]),
        minimum_spend: Enum.random([nil, nil, eur(2_000 + :rand.uniform(8_000))])
    }

    lines =
      for n <- 1..(:rand.uniform(10) - 1)//1, do: random_line(n, offer, services, built.event)

    overrides =
      for service <- services, :rand.uniform(3) == 1 do
        override(offer, service, :rand.uniform(2) == 1)
      end

    snapshot = %{
      built.snapshot
      | services: services,
        offers: [offer],
        offer_lines: lines,
        overrides: overrides
    }

    %{snapshot: snapshot, offer: offer}
  end

  defp random_line(id, offer, services, event) do
    service = if :rand.uniform(4) > 1, do: Enum.random(services)
    state = if service, do: Enum.random(@states), else: Enum.random([:mandatory, :optional])

    base = %OfferLine{
      id: id,
      offer_id: offer.id,
      service_id: service && service.id,
      label: if(service, do: nil, else: "Ad hoc #{id}"),
      state: state,
      enabled: service == nil and state == :optional and :rand.uniform(2) == 1
    }

    if OfferLine.priced_state?(state) do
      basis = Enum.random(@bases)
      per_person? = basis != :flat

      %{
        base
        | basis: basis,
          event_id: if(per_person?, do: event.id),
          amount: eur(:rand.uniform(300)),
          included_quantity: if(per_person? and :rand.uniform(3) == 1, do: :rand.uniform(20)),
          minimum_charge: if(:rand.uniform(4) == 1, do: eur(:rand.uniform(2_000)))
      }
    else
      base
    end
  end

  # One row per offer × service: the id is derived from the pair, so a :put replaces.
  defp override(offer, service, wanted) do
    %Override{
      id: {:override, offer.id, service.id},
      offer_id: offer.id,
      service_id: service.id,
      wanted: wanted
    }
  end

  # 1–6 changes made "elsewhere in the category": a service's priority moves, or an override
  # for the offer is put or deleted. Deletes name only rows present at that point.
  defp random_changes(snapshot, offer) do
    present = MapSet.new(snapshot.overrides, & &1.id)

    {changes, _present} =
      Enum.map_reduce(1..:rand.uniform(6), present, fn _, present ->
        service = Enum.random(snapshot.services)
        row = override(offer, service, :rand.uniform(2) == 1)

        case :rand.uniform(3) do
          1 ->
            {{:put, :services, %{service | wanted_priority: Enum.random(@priorities)}}, present}

          2 ->
            {{:put, :overrides, row}, MapSet.put(present, row.id)}

          3 ->
            if MapSet.member?(present, row.id),
              do: {{:delete, :overrides, row.id}, MapSet.delete(present, row.id)},
              else: {{:put, :overrides, row}, MapSet.put(present, row.id)}
        end
      end)

    changes
  end

  # What a case contains, for the non-vacuity check (read through the engine: these are
  # statistics about the input, not assertions).
  defp case_flags(snapshot, offer) do
    wanted? = fn line ->
      service = Enum.find(snapshot.services, &(&1.id == line.service_id))
      Selection.effectively_wanted?(snapshot, offer, service)
    end

    line_flags =
      for line <- Selection.lines(snapshot, offer) do
        cond do
          line.service_id == nil and line.state == :optional and line.enabled -> :ad_hoc_on
          line.service_id == nil and line.state == :optional -> :ad_hoc_off
          line.service_id == nil -> nil
          line.state == :mandatory and not wanted?.(line) -> :mandatory_line_of_unwanted_service
          line.state == :optional and not wanted?.(line) -> :optional_line_of_unwanted_service
          line.state == :optional -> :optional_line_of_wanted_service
          true -> nil
        end
      end

    override_flags =
      for row <- snapshot.overrides,
          service = Enum.find(snapshot.services, &(&1.id == row.service_id)),
          row.wanted != service.wanted_priority in [:must_have, :nice_to_have],
          do: :deviating_override

    line_flags ++ override_flags
  end
end
