defmodule WeddingPlanner.Valuation.ComparisonTest do
  @moduledoc """
  `WeddingPlanner.Valuation.Comparison.build/4` — the comparison matrix view model
  (`CST-50`…`CST-55`, `XC-42`, `DR-49`, `DR-56`, `DR-57`). Pure: in-memory snapshots, no
  database, no headcount seam — the guests are real `Person`/`Invitation` structs that
  `WeddingPlanner.Valuation.Headcount.evaluate/3` counts.

  The example-driven tests run over `WeddingPlanner.NormativeMatrix` (Venue A and Venue B
  as two columns of the worked example's Venue category). They are deliberately **not**
  tagged `example: "O3"`: task 55 owns O3's engine tag and task 65 its visual tag.

  The property tests (fixed `:rand` seeds, no StreamData) check that the matrix is only a
  view of the C3 engines — totals, gaps, the line partition and the line-sum — and hold an
  **independent oracle** for `CST-24`'s effective-wanted rule, `DR-56`'s "deviates", each
  line's inclusion (`CST-21`, `CST-22`) and — for the generated *confirmed* offers, which
  carry a random frozen selection — `DR-61`/`DR-63`/`DR-64`'s frozen rule (scope,
  `:outside_scope`, dormant overrides), sharing no code with
  `WeddingPlanner.Valuation.Selection`.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeMatrix
  alias WeddingPlanner.Offers.FrozenService
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Valuation.Comparison
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Gaps
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Offer, as: OfferEngine
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot

  # -- helpers --------------------------------------------------------------------------------

  defp eur(amount), do: WeddingPlanner.Money.new(amount)

  defp money_of(%Formula{total: {:money, %Money{} = money}}), do: money

  defp build(
         %{snapshot: snapshot, category_id: category_id, presets: presets},
         selected \\ "Likely"
       ) do
    Comparison.build(
      snapshot,
      category_id,
      selected && Map.fetch!(presets, selected),
      {Map.fetch!(presets, "Minimum"), Map.fetch!(presets, "Maximum")}
    )
  end

  defp column(matrix, %Offer{id: id}), do: Enum.find(matrix.columns, &(&1.offer.id == id))

  defp band(matrix, priority), do: Enum.find(matrix.bands, &(&1.priority == priority))

  defp cell(matrix, %Service{id: service_id}, %Offer{id: offer_id}) do
    matrix.bands
    |> Enum.flat_map(& &1.rows)
    |> Enum.find(&(&1.service.id == service_id))
    |> Map.fetch!(:cells)
    |> Map.fetch!(offer_id)
  end

  defp total_of(built, which, preset_name) do
    OfferEngine.total(
      built.snapshot,
      Map.fetch!(built.offers, which),
      Map.fetch!(built.presets, preset_name)
    )
  end

  # -- the fixture ----------------------------------------------------------------------------

  describe "NormativeMatrix (fixture self-check)" do
    @describetag :normative_fixture

    test "Venue B's lines are Venue A's non-Catering lines under distinct ids" do
      built = NormativeMatrix.snapshot(:no_line)
      venue_a = built.offers.venue_a
      venue_b = built.offers.venue_b

      catering_numbers =
        for %{service: "Catering", number: number} <- NE.venue_a().lines, do: number

      expected_b =
        for {number, line} <- built.lines.venue_a, number not in catering_numbers, into: %{} do
          {number, %{line | id: NormativeMatrix.venue_b_line_id(number), offer_id: venue_b.id}}
        end

      assert built.lines.venue_b == expected_b
      assert map_size(built.lines.venue_a) == length(NE.venue_a().lines)

      ids = Enum.map(built.snapshot.offer_lines, & &1.id)
      assert ids == Enum.uniq(ids)
      assert length(ids) == map_size(built.lines.venue_a) + map_size(built.lines.venue_b)

      assert venue_a.vendor_name == NE.venue_a().vendor
      assert venue_b.vendor_name == NE.venue_b().vendor
      assert venue_a.category_id == built.category_id
      assert venue_b.category_id == built.category_id
      assert venue_a.id != venue_b.id
    end

    test "the category's services are the docs' names and priorities, in order" do
      built = NormativeMatrix.snapshot()

      services =
        built.snapshot.services
        |> Enum.sort_by(& &1.sort_order)
        |> Enum.map(&%{name: &1.name, priority: &1.wanted_priority})

      assert services == NE.venue_category().services
    end

    test "the guests evaluate to the shared headcount; the presets are the stored defaults" do
      built = NormativeMatrix.snapshot()

      for {name, counts} <- NE.shared_headcount()["Dinner"] do
        assert Headcount.evaluate(built.snapshot, Map.fetch!(built.presets, name), built.event) ==
                 counts
      end

      assert Enum.map(built.snapshot.headcount_presets, &%{&1 | id: nil}) == Preset.defaults()
      assert Enum.map(built.snapshot.headcount_presets, & &1.id) == [1, 2, 3]
    end
  end

  # -- Venue A and Venue B as two columns -----------------------------------------------------

  describe "Venue A and Venue B" do
    test "Venue A's column: total under Likely €11,726, range {€11,478, Maximum's total}" do
      built = NormativeMatrix.snapshot()
      matrix = build(built)
      a = column(matrix, built.offers.venue_a)

      assert matrix.category.id == built.category_id
      assert Enum.map(matrix.columns, & &1.offer.id) == [1, 2]

      assert %Formula{} = a.total
      assert Money.equal?(money_of(a.total), eur(11_726))
      assert a.total == total_of(built, :venue_a, "Likely")

      {low, high} = a.range
      assert Money.equal?(low, eur(11_478))
      assert Money.equal?(high, money_of(total_of(built, :venue_a, "Maximum")))

      assert a.gaps |> Enum.map(&{&1.service.name, &1.severity}) == [
               {"Late-night snack", :unknown}
             ]

      assert a.gap_counts == %{must_have: 0, nice_to_have: 0, unknown: 1}
      assert a.like_for_like? == false
      assert a.needs_attention? == false
      assert a.needs_attention? == OfferEngine.needs_attention?(built.snapshot, a.offer)
      assert a.rejected? == false
    end

    test "Venue B's column: a must-have Catering gap, not like-for-like, total excludes catering" do
      for variant <- [:no_line, :not_offered_line] do
        built = NormativeMatrix.snapshot(variant)
        matrix = build(built)
        a = column(matrix, built.offers.venue_a)
        b = column(matrix, built.offers.venue_b)
        catering = Map.fetch!(built.services, "Catering")

        assert b.gap_counts.must_have == 1, "variant #{variant}"
        assert b.gap_counts == %{must_have: 1, nice_to_have: 0, unknown: 1}
        assert b.like_for_like? == false

        catering_cell = cell(matrix, catering, built.offers.venue_b)
        assert catering_cell.gap.severity == :must_have
        assert catering_cell.gap.service == catering
        assert catering_cell.effectively_wanted? == true

        # Its total is the engine's, and the engine's is Venue A's minus A's Catering lines.
        assert b.total == total_of(built, :venue_b, "Likely")

        a_catering_totals =
          for entry <- cell(matrix, catering, built.offers.venue_a).lines, do: entry.total

        assert length(a_catering_totals) == 2

        expected_b =
          Enum.reduce(a_catering_totals, money_of(a.total), &Money.sub!(&2, &1))

        assert Money.equal?(money_of(b.total), expected_b)
        assert Money.equal?(money_of(b.total), eur(4_686))
      end
    end

    test "bands: three, in CST-51 order, services in category order" do
      built = NormativeMatrix.snapshot()
      matrix = build(built)

      assert Enum.map(matrix.bands, & &1.priority) == [:must_have, :nice_to_have, :not_wanted]

      names = fn priority ->
        for row <- band(matrix, priority).rows, do: row.service.name
      end

      assert names.(:must_have) == ["Catering"]
      assert names.(:nice_to_have) == ["Seating", "Sound", "Late-night snack"]
      assert names.(:not_wanted) == ["Garden ceremony"]

      for band <- matrix.bands, row <- band.rows do
        assert Map.keys(row.cells) |> Enum.sort() == [1, 2]
      end

      garden = cell(matrix, Map.fetch!(built.services, "Garden ceremony"), built.offers.venue_a)
      assert garden.effectively_wanted? == false
      assert garden.override == nil
      assert garden.gap == nil

      assert [%{line: %OfferLine{id: 6}, inclusion: :not_selected, total: nil, invalid: false}] =
               garden.lines
    end

    test "cells carry each line's inclusion and breakdown total (Catering, Seating, Sound)" do
      built = NormativeMatrix.snapshot()
      matrix = build(built)
      venue_a = built.offers.venue_a

      catering = cell(matrix, Map.fetch!(built.services, "Catering"), venue_a)

      assert [
               %{line: %OfferLine{id: 3}, inclusion: :counted, invalid: false} = adults,
               %{line: %OfferLine{id: 4}, inclusion: :counted} = children
             ] = catering.lines

      assert Money.equal?(adults.total, eur(6_800))
      assert Money.equal?(children.total, eur(240))

      seating = cell(matrix, Map.fetch!(built.services, "Seating"), venue_a)
      assert [%{line: %OfferLine{id: 2}, inclusion: :counted, total: seat_total}] = seating.lines
      assert Money.equal?(seat_total, eur(336))

      sound = cell(matrix, Map.fetch!(built.services, "Sound"), venue_a)
      assert [%{line: %OfferLine{id: 5}, inclusion: :no_charge, total: nil}] = sound.lines
      assert sound.gap == nil
    end

    test "other charges: Venue A lists Base price and Cleaning fee, counted, €4,000 / €350" do
      built = NormativeMatrix.snapshot()
      matrix = build(built)

      assert Map.keys(matrix.other_charges) |> Enum.sort() == [1, 2]

      assert [
               %{line: %OfferLine{label: "Base price"}, inclusion: :counted, invalid: false} =
                 base,
               %{line: %OfferLine{label: "Cleaning fee"}, inclusion: :counted} = cleaning
             ] = Map.fetch!(matrix.other_charges, built.offers.venue_a.id)

      assert Money.equal?(base.total, eur(4_000))
      assert Money.equal?(cleaning.total, eur(350))
    end
  end

  # -- overrides (DR-49, DR-56) ---------------------------------------------------------------

  describe "overrides" do
    test "turning Late-night snack off for Venue A: a deviating override, no gap, one unknown fewer" do
      built = NormativeMatrix.snapshot()
      snack = Map.fetch!(built.services, "Late-night snack")

      before = column(build(built), built.offers.venue_a)

      overridden = NormativeMatrix.with_overrides(built, :venue_a, [{"Late-night snack", false}])
      matrix = build(overridden)
      after_ = column(matrix, built.offers.venue_a)
      snack_cell = cell(matrix, snack, built.offers.venue_a)

      assert snack_cell.override == %{wanted: false, deviates?: true}
      assert snack_cell.effectively_wanted? == false
      assert snack_cell.gap == nil
      assert after_.gap_counts.unknown == before.gap_counts.unknown - 1
      assert after_.like_for_like? == true

      # Venue B is untouched by Venue A's override.
      assert cell(matrix, snack, built.offers.venue_b).override == nil
      assert cell(matrix, snack, built.offers.venue_b).gap.severity == :unknown
    end

    test "an override equal to the priority's default does not deviate" do
      built =
        NormativeMatrix.snapshot()
        |> NormativeMatrix.with_overrides(:venue_a, [
          {"Late-night snack", true},
          {"Garden ceremony", false}
        ])

      matrix = build(built)

      snack = cell(matrix, Map.fetch!(built.services, "Late-night snack"), built.offers.venue_a)
      assert snack.override == %{wanted: true, deviates?: false}

      garden = cell(matrix, Map.fetch!(built.services, "Garden ceremony"), built.offers.venue_a)
      assert garden.override == %{wanted: false, deviates?: false}
    end

    test "turning Garden ceremony on for Venue A deviates and counts its optional line" do
      built =
        NormativeMatrix.snapshot()
        |> NormativeMatrix.with_overrides(:venue_a, [{"Garden ceremony", true}])

      matrix = build(built)
      garden = cell(matrix, Map.fetch!(built.services, "Garden ceremony"), built.offers.venue_a)

      assert garden.override == %{wanted: true, deviates?: true}
      assert garden.effectively_wanted? == true
      assert [%{inclusion: :counted, total: total}] = garden.lines
      assert Money.equal?(total, eur(500))

      assert Money.equal?(
               money_of(column(matrix, built.offers.venue_a).total),
               eur(12_226)
             )
    end
  end

  # -- invalid lines (XC-42) ------------------------------------------------------------------

  describe "invalid lines" do
    test "an invalid, not selected optional line: needs attention, flagged, total unchanged" do
      built = NormativeMatrix.snapshot()
      garden = Map.fetch!(built.services, "Garden ceremony")

      invalid = %OfferLine{
        id: 50,
        service_id: garden.id,
        state: :optional,
        basis: :per_adult,
        event_id: nil,
        amount: eur(10),
        enabled: false
      }

      built = NormativeMatrix.put_line(built, :venue_a, invalid)
      matrix = build(built)
      a = column(matrix, built.offers.venue_a)

      assert a.needs_attention? == true
      assert a.needs_attention? == OfferEngine.needs_attention?(built.snapshot, a.offer)
      assert column(matrix, built.offers.venue_b).needs_attention? == false

      entry = Enum.find(cell(matrix, garden, built.offers.venue_a).lines, &(&1.line.id == 50))
      assert %{inclusion: :not_selected, invalid: true, total: nil} = entry

      assert Money.equal?(money_of(a.total), eur(11_726))
    end

    test "an invalid counted line: needs attention, flagged €0, total unaffected beyond it" do
      built = NormativeMatrix.snapshot()
      seating = Map.fetch!(built.services, "Seating")

      invalid = %OfferLine{
        id: 51,
        service_id: seating.id,
        state: :mandatory,
        basis: :per_attendee,
        event_id: nil,
        amount: eur(99),
        enabled: false
      }

      built = NormativeMatrix.put_line(built, :venue_a, invalid)
      matrix = build(built)
      a = column(matrix, built.offers.venue_a)

      assert a.needs_attention? == true
      assert a.needs_attention? == OfferEngine.needs_attention?(built.snapshot, a.offer)

      entry = Enum.find(cell(matrix, seating, built.offers.venue_a).lines, &(&1.line.id == 51))
      assert %{inclusion: :counted, invalid: true, total: zero} = entry
      assert Money.equal?(zero, eur(0))

      assert a.total == total_of(built, :venue_a, "Likely")
      assert Money.equal?(money_of(a.total), eur(11_726))
    end
  end

  # -- status and presets ---------------------------------------------------------------------

  describe "status and presets" do
    test "a rejected offer is a column with rejected?: true and still has a total" do
      built =
        NormativeMatrix.snapshot()
        |> NormativeMatrix.update_offer(:venue_b, &%{&1 | status: :rejected})

      matrix = build(built)
      b = column(matrix, built.offers.venue_b)

      assert b.rejected? == true
      assert column(matrix, built.offers.venue_a).rejected? == false
      assert b.total == total_of(built, :venue_b, "Likely")
      assert {%Money{}, %Money{}} = b.range
    end

    test "no selected preset: totals and line totals nil; no range presets: ranges nil" do
      built = NormativeMatrix.snapshot()

      no_selection = build(built, nil)
      assert Enum.all?(no_selection.columns, &is_nil(&1.total))
      assert Enum.all?(no_selection.columns, &match?({%Money{}, %Money{}}, &1.range))

      for band <- no_selection.bands,
          row <- band.rows,
          {_, cell} <- row.cells,
          entry <- cell.lines do
        assert entry.total == nil
      end

      for {_, entries} <- no_selection.other_charges, entry <- entries do
        assert entry.total == nil
      end

      no_range =
        Comparison.build(
          built.snapshot,
          built.category_id,
          Map.fetch!(built.presets, "Likely"),
          nil
        )

      assert Enum.all?(no_range.columns, &is_nil(&1.range))
      assert Enum.all?(no_range.columns, &match?(%Formula{}, &1.total))
    end

    test "a range whose presets come in the other order still reads low–high" do
      built = NormativeMatrix.snapshot()

      matrix =
        Comparison.build(
          built.snapshot,
          built.category_id,
          nil,
          {Map.fetch!(built.presets, "Maximum"), Map.fetch!(built.presets, "Minimum")}
        )

      {low, high} = column(matrix, built.offers.venue_a).range
      assert Money.equal?(low, eur(11_478))
      assert Money.equal?(high, eur(11_726))
    end

    test "a category with no offers: no columns, bands still there, no other charges" do
      built = NormativeMatrix.snapshot()
      snapshot = %{built.snapshot | offers: [], offer_lines: []}
      matrix = Comparison.build(snapshot, built.category_id, nil, nil)

      assert matrix.columns == []
      assert matrix.other_charges == %{}
      assert Enum.map(matrix.bands, &length(&1.rows)) == [1, 3, 1]
      assert Enum.all?(matrix.bands, fn band -> Enum.all?(band.rows, &(&1.cells == %{})) end)
    end

    test "an unknown category raises" do
      built = NormativeMatrix.snapshot()

      assert_raise ArgumentError, ~r/category 999/, fn ->
        Comparison.build(built.snapshot, 999, nil, nil)
      end
    end
  end

  # -- property tests -------------------------------------------------------------------------

  describe "property: random categories" do
    @describetag :property

    test "column totals are Offer.total/3's, 300 cases" do
      for_each_case({11, 12, 13}, 300, fn %{snapshot: snapshot, matrix: matrix} = c ->
        for column <- matrix.columns do
          case c.selected do
            nil ->
              assert column.total == nil

            preset ->
              expected = OfferEngine.total(snapshot, column.offer, preset)
              assert Money.equal?(money_of(column.total), money_of(expected))
              assert column.total == expected
          end
        end
      end)
    end

    test "gap counts tally Gaps.for_offer/2; each gap sits in exactly its service's cell, 300 cases" do
      for_each_case({21, 22, 23}, 300, fn %{snapshot: snapshot, matrix: matrix} ->
        for column <- matrix.columns do
          gaps = Gaps.for_offer(snapshot, column.offer)
          tallies = Enum.frequencies_by(gaps, & &1.severity)

          assert column.gaps == gaps
          assert column.like_for_like? == (gaps == [])

          assert column.gap_counts == %{
                   must_have: Map.get(tallies, :must_have, 0),
                   nice_to_have: Map.get(tallies, :nice_to_have, 0),
                   unknown: Map.get(tallies, :unknown, 0)
                 }

          cells_with_gap =
            for band <- matrix.bands,
                row <- band.rows,
                cell = Map.fetch!(row.cells, column.offer.id),
                cell.gap != nil,
                do: {row.service, cell.gap}

          assert length(cells_with_gap) == length(gaps)

          for gap <- gaps do
            assert Enum.count(cells_with_gap, fn {_, cell_gap} -> cell_gap == gap end) == 1
            assert {gap.service, gap} in cells_with_gap
          end
        end
      end)
    end

    test "partition: every line of every offer appears exactly once, 300 cases" do
      for_each_case({31, 32, 33}, 300, fn %{snapshot: snapshot, matrix: matrix} = c ->
        category_offers =
          snapshot.offers
          |> Enum.filter(&(&1.category_id == c.category_id))
          |> Enum.sort_by(& &1.id)

        assert Enum.map(matrix.columns, & &1.offer) == category_offers
        assert Map.keys(matrix.other_charges) |> Enum.sort() == Enum.map(category_offers, & &1.id)

        for offer <- category_offers do
          in_cells =
            for band <- matrix.bands,
                row <- band.rows,
                entry <- Map.fetch!(row.cells, offer.id).lines do
              assert entry.line.service_id == row.service.id
              entry.line.id
            end

          in_other =
            for entry <- Map.fetch!(matrix.other_charges, offer.id) do
              assert entry.line.service_id == nil
              entry.line.id
            end

          shown = in_cells ++ in_other
          expected = for line <- snapshot.offer_lines, line.offer_id == offer.id, do: line.id

          assert Enum.sort(shown) == Enum.sort(expected)
          assert length(shown) == length(Enum.uniq(shown))
        end
      end)
    end

    test "counted line totals shown sum to Offer.breakdown/3's line_sum, 300 cases" do
      for_each_case({41, 42, 43}, 300, fn %{snapshot: snapshot, matrix: matrix} = c ->
        for column <- matrix.columns do
          entries = column_entries(matrix, column.offer)

          for entry <- entries, entry.inclusion != :counted, do: assert(entry.total == nil)

          case c.selected do
            nil ->
              assert Enum.all?(entries, &is_nil(&1.total))

            preset ->
              counted = Enum.filter(entries, &(&1.inclusion == :counted))
              assert Enum.all?(counted, &match?(%Money{}, &1.total))

              shown_sum = counted |> Enum.map(& &1.total) |> WeddingPlanner.Money.sum()
              breakdown = OfferEngine.breakdown(snapshot, column.offer, preset)

              assert Money.equal?(shown_sum, breakdown.line_sum)
          end
        end
      end)
    end

    test "range is low ≤ high and each end is one of the two presets' totals, 300 cases" do
      for_each_case({51, 52, 53}, 300, fn %{snapshot: snapshot, matrix: matrix} = c ->
        for column <- matrix.columns do
          case c.range do
            nil ->
              assert column.range == nil

            {p, q} ->
              {low, high} = column.range
              assert Money.compare!(low, high) in [:lt, :eq]

              totals = [
                money_of(OfferEngine.total(snapshot, column.offer, p)),
                money_of(OfferEngine.total(snapshot, column.offer, q))
              ]

              assert Enum.any?(totals, &Money.equal?(&1, low))
              assert Enum.any?(totals, &Money.equal?(&1, high))
              [t1, t2] = totals
              assert Money.equal?(Money.add!(low, high), Money.add!(t1, t2))
          end
        end
      end)
    end

    test "independent oracle: effective wanted (CST-24), deviates (DR-56), needs attention (XC-42), 300 cases" do
      for_each_case({61, 62, 63}, 300, fn %{snapshot: snapshot, matrix: matrix} ->
        for column <- matrix.columns do
          offer = column.offer

          assert column.needs_attention? ==
                   Enum.any?(
                     snapshot.offer_lines,
                     &(&1.offer_id == offer.id and oracle_invalid?(&1))
                   )

          assert column.needs_attention? == OfferEngine.needs_attention?(snapshot, offer)

          for entry <- column_entries(matrix, offer) do
            assert entry.invalid == oracle_invalid?(entry.line)
          end

          for band <- matrix.bands, row <- band.rows do
            service = row.service
            cell = Map.fetch!(row.cells, offer.id)
            assert service.wanted_priority == band.priority

            rows =
              for r <- snapshot.overrides,
                  r.offer_id == offer.id and r.service_id == service.id,
                  do: r

            by_priority = oracle_priority_wanted?(service.wanted_priority)

            case {offer.status, rows} do
              # DR-61/DR-64: a confirmed offer answers from its frozen rows alone; its
              # override rows are dormant and every cell shows its scope.
              {:confirmed, _rows} ->
                frozen? = oracle_frozen?(snapshot, offer, service)
                assert cell.effectively_wanted? == frozen?
                assert cell.override == nil
                assert cell.scope == if(frozen?, do: :in, else: :out)

              {_status, []} ->
                assert cell.effectively_wanted? == by_priority
                assert cell.override == nil
                assert cell.scope == nil

              {_status, [%{wanted: wanted}]} ->
                assert cell.effectively_wanted? == wanted
                assert cell.override == %{wanted: wanted, deviates?: wanted != by_priority}
                assert cell.scope == nil
            end
          end
        end
      end)
    end

    test "independent oracle: every line's inclusion (CST-21, CST-22, DR-61, DR-63), 300 cases" do
      seen =
        for_each_case({71, 72, 73}, 300, fn %{snapshot: snapshot, matrix: matrix} ->
          for column <- matrix.columns,
              entry <- column_entries(matrix, column.offer) do
            expected = oracle_inclusion(snapshot, column.offer, entry.line)
            assert entry.inclusion == expected
            {column.offer.status, entry.line.state, expected}
          end
        end)
        |> List.flatten()
        |> MapSet.new()

      # Not vacuous: the frozen rule's outcomes all occurred.
      for outcome <- [
            {:confirmed, :optional, :counted},
            {:confirmed, :optional, :outside_scope},
            {:confirmed, :optional, :not_selected},
            {:confirmed, :mandatory, :counted},
            {:shortlisted, :optional, :not_selected}
          ] do
        assert outcome in seen, "#{inspect(outcome)} never generated"
      end
    end
  end

  # -- property-test helpers ------------------------------------------------------------------

  # The oracle's own rules, written from the docs and sharing no code with `Selection`:
  # CST-03/CST-24 — must-have and nice-to-have are wanted, not wanted is not, and an
  # override row for the offer × service replaces that; XC-41 — a per-person line with no
  # event is invalid.
  defp oracle_priority_wanted?(:must_have), do: true
  defp oracle_priority_wanted?(:nice_to_have), do: true
  defp oracle_priority_wanted?(:not_wanted), do: false

  defp oracle_invalid?(%OfferLine{basis: basis, event_id: event_id}),
    do: basis in [:per_adult, :per_child, :per_attendee] and event_id == nil

  # DR-61: a frozen row counts only on a confirmed offer.
  defp oracle_frozen?(snapshot, offer, service) do
    offer.status == :confirmed and
      Enum.any?(
        snapshot.frozen_services,
        &(&1.offer_id == offer.id and &1.service_id == service.id)
      )
  end

  # CST-24 for a non-confirmed offer; DR-61's frozen set for a confirmed one.
  defp oracle_wanted?(snapshot, offer, service) do
    if offer.status == :confirmed do
      oracle_frozen?(snapshot, offer, service)
    else
      rows =
        for r <- snapshot.overrides,
            r.offer_id == offer.id and r.service_id == service.id,
            do: r

      case rows do
        [] -> oracle_priority_wanted?(service.wanted_priority)
        [%{wanted: wanted}] -> wanted
      end
    end
  end

  # CST-21/CST-22 plus DR-61 (optional service lines outside a confirmed offer's frozen
  # set are :outside_scope) and DR-63 (mandatory always counts, confirmed or not).
  defp oracle_inclusion(_snapshot, _offer, %OfferLine{state: :mandatory}), do: :counted

  defp oracle_inclusion(_snapshot, _offer, %OfferLine{state: state})
       when state in [:included, :not_offered, :unknown],
       do: :no_charge

  defp oracle_inclusion(_snapshot, _offer, %OfferLine{state: :optional, service_id: nil} = l),
    do: if(l.enabled, do: :counted, else: :not_selected)

  defp oracle_inclusion(snapshot, offer, %OfferLine{state: :optional, service_id: id}) do
    service = Enum.find(snapshot.services, &(&1.id == id))

    cond do
      oracle_wanted?(snapshot, offer, service) -> :counted
      offer.status == :confirmed -> :outside_scope
      true -> :not_selected
    end
  end

  defp column_entries(matrix, offer) do
    cells =
      for band <- matrix.bands,
          row <- band.rows,
          entry <- Map.fetch!(row.cells, offer.id).lines,
          do: entry

    cells ++ Map.fetch!(matrix.other_charges, offer.id)
  end

  # Runs `fun` over `n` random cases from a fixed seed; on failure, names the seed, the
  # iteration and the input. Returns `fun`'s results.
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
                category_id: c.category_id,
                selected: c.selected,
                range: c.range,
                services: c.snapshot.services,
                offers: c.snapshot.offers,
                offer_lines: c.snapshot.offer_lines,
                overrides: c.snapshot.overrides,
                frozen_services: c.snapshot.frozen_services,
                persons: length(c.snapshot.persons),
                events: c.snapshot.events
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

  @category_id 1
  @noise_category_id 2
  @priorities [:must_have, :nice_to_have, :not_wanted]
  @states [:included, :optional, :mandatory, :not_offered, :unknown]
  @bases [:flat, :per_adult, :per_child, :per_attendee]

  # One random category (0–6 services, 0–4 offers with 0–7 lines in every state and basis,
  # ad hoc and invalid lines included, random overrides, a random frozen selection on each
  # confirmed offer and stray frozen rows on others) plus a noise category the matrix must
  # ignore, random guests over 1–3 events, and a random preset choice.
  defp random_case do
    events =
      for e <- 1..:rand.uniform(3),
          do: %Event{couple_attends: false, id: e, name: "Event #{e}", sort_order: e}

    {persons, invitations} = random_guests(events)

    services =
      random_services(@category_id, 1..(:rand.uniform(7) - 1)//1, 10) ++
        random_services(@noise_category_id, 1..2, 90)

    {offers, lines} = random_offers(services, events)
    overrides = random_overrides(offers, services)
    frozen_services = random_frozen_services(offers, services)

    snapshot = %Snapshot{
      events: events,
      persons: persons,
      invitations: invitations,
      headcount_presets: Preset.defaults(),
      categories: [
        %Category{id: @category_id, name: "Category", sort_order: 0},
        %Category{id: @noise_category_id, name: "Noise", sort_order: 1}
      ],
      services: services,
      offers: offers,
      offer_lines: lines,
      overrides: overrides,
      frozen_services: frozen_services
    }

    [minimum, likely, maximum] = Preset.defaults()
    adults_only = %Preset{name: "Adults only", age_categories: MapSet.new([:adult])}

    selected = Enum.random([nil, minimum, likely, likely, maximum, adults_only])

    range =
      Enum.random([
        nil,
        {minimum, maximum},
        {minimum, maximum},
        {maximum, minimum},
        {likely, adults_only}
      ])

    %{
      snapshot: snapshot,
      category_id: @category_id,
      selected: selected,
      range: range,
      matrix: Comparison.build(snapshot, @category_id, selected, range)
    }
  end

  defp random_guests(events) do
    persons =
      for id <- 1..(:rand.uniform(17) - 1)//1 do
        %Person{
          id: id,
          first_name: "Guest #{id}",
          age_category: Enum.random([:adult, :adult, :child]),
          certainty: Enum.random(Person.certainties()),
          want_tier: Enum.random(Person.want_tiers())
        }
      end

    invitations =
      for person <- persons, event <- events, :rand.uniform(4) > 1 do
        %Invitation{
          id: person.id * 10 + event.id,
          person_id: person.id,
          event_id: event.id,
          status: Enum.random(Invitation.statuses())
        }
      end

    {persons, invitations}
  end

  # Services with random priorities; sort orders collide on purpose (id breaks ties).
  defp random_services(category_id, range, first_id) do
    for n <- range do
      %Service{
        id: first_id + n,
        category_id: category_id,
        name: "Service #{first_id + n}",
        wanted_priority: Enum.random(@priorities),
        sort_order: :rand.uniform(4)
      }
    end
  end

  defp random_offers(services, events) do
    offer_specs =
      for id <- Enum.to_list(1..(:rand.uniform(5) - 1)//1), do: {id, @category_id}

    noise_specs = [{100, @noise_category_id}]

    Enum.reduce(offer_specs ++ noise_specs, {[], []}, fn {id, category_id}, {offers, lines} ->
      exclusive? = :rand.uniform(2) == 1

      offer = %Offer{
        id: id,
        category_id: category_id,
        vendor_name: "Vendor #{id}",
        status: Enum.random([:considering, :shortlisted, :rejected, :confirmed]),
        vat_basis: if(exclusive?, do: :exclusive, else: :inclusive),
        vat_rate_bp: if(exclusive?, do: Enum.random([600, 2100])),
        minimum_spend:
          Enum.random([nil, nil, eur(:rand.uniform(300)), eur(2_000 + :rand.uniform(8_000))])
      }

      category_services = Enum.filter(services, &(&1.category_id == category_id))

      offer_lines =
        for n <- 1..(:rand.uniform(8) - 1)//1 do
          random_line(id * 100 + n, offer, category_services, events)
        end

      {offers ++ [offer], lines ++ offer_lines}
    end)
  end

  defp random_line(id, offer, services, events) do
    service = if services != [] and :rand.uniform(3) > 1, do: Enum.random(services)

    state =
      if service,
        do: Enum.random(@states),
        else: Enum.random([:mandatory, :optional])

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
          # One per-person line in six is invalid (its event was deleted — XC-41).
          event_id: if(per_person? and :rand.uniform(6) > 1, do: Enum.random(events).id),
          amount: eur(:rand.uniform(200)),
          included_quantity: if(per_person? and :rand.uniform(3) == 1, do: :rand.uniform(5) - 1),
          minimum_charge: if(:rand.uniform(4) == 1, do: eur(:rand.uniform(1_000))),
          vat_rate_bp: if(offer.vat_basis == :exclusive and :rand.uniform(3) == 1, do: 1200)
      }
    else
      base
    end
  end

  # At most one row per offer × service (C4's unique index, DR-56), for any offer and any
  # service — rows for another category's service, or for the noise offer, must be ignored.
  defp random_overrides(offers, services) do
    for offer <- offers, service <- services, :rand.uniform(4) == 1 do
      %{offer_id: offer.id, service_id: service.id, wanted: :rand.uniform(2) == 1}
    end
  end

  # DR-61: a confirmed offer's frozen selection is a random subset of its category's
  # services (deliberately *not* `Selection.freeze/2`, so the frozen set disagrees with
  # the priorities and overrides often); other offers get the odd stray row, which must be
  # ignored. One row per offer × service (the unique index).
  defp random_frozen_services(offers, services) do
    rows =
      for offer <- offers,
          service <- services,
          service.category_id == offer.category_id,
          :rand.uniform(if(offer.status == :confirmed, do: 2, else: 6)) == 1,
          do: {offer.id, service.id}

    rows
    |> Enum.with_index(1)
    |> Enum.map(fn {{offer_id, service_id}, id} ->
      %FrozenService{id: id, offer_id: offer_id, service_id: service_id}
    end)
  end
end
