defmodule WeddingPlanner.Valuation.Nfr33SmokeTest do
  @moduledoc """
  `NFR-33` smoke test: at the documented maximum data size — ~150 persons, ~10 events,
  ~100 offers (`docs/05-non-functional.md`) — every offer total under every default
  preset and every headcount recomputes in well under a second.

  Pure (`NFR-41`): an in-memory `WeddingPlanner.Valuation.Snapshot`, no database. The
  data is synthetic and deterministic; it is shaped to exercise every branch the engines
  have at that size (+1s possible and confirmed, opt-outs, all four statuses, all bases,
  included quantities, minimum charges, VAT-exclusive offers with line rates and minimum
  spends), not to mean anything.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Invitations.PlusOneOptOut
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Valuation.Comparison
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Offer, as: OfferEngine
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot

  @hosts 130
  @plus_ones 20
  @events 10
  @categories 10
  @services_per_category 6
  @offers 100
  @lines_per_offer 6

  @bound_us 1_000_000

  # -- the snapshot ---------------------------------------------------------------------------

  defp snapshot do
    events = for e <- 1..@events, do: %Event{id: e, name: "Event #{e}", sort_order: e}

    hosts =
      for p <- 1..@hosts do
        %Person{
          id: p,
          first_name: "Guest #{p}",
          age_category: Enum.at([:adult, :adult, :adult, :child], rem(p, 4)),
          want_tier: Enum.at(Person.want_tiers(), rem(p, 4)),
          certainty: Enum.at(Person.certainties(), rem(p, 3))
        }
      end

    plus_ones =
      for n <- 1..@plus_ones do
        host = Enum.at(hosts, n - 1)

        %Person{
          id: @hosts + n,
          host_id: host.id,
          plus_one_status: if(rem(n, 2) == 0, do: :confirmed, else: :possible),
          age_category: if(rem(n, 5) == 0, do: :child, else: :adult),
          want_tier: host.want_tier,
          certainty: host.certainty
        }
      end

    # An invitation for most host × event pairs (every seventh pair is not invited).
    invitations =
      for p <- 1..@hosts, e <- 1..@events, rem(p + e, 7) != 0 do
        %Invitation{
          id: p * 100 + e,
          person_id: p,
          event_id: e,
          status: Enum.at(Invitation.statuses(), rem(p * e, 4))
        }
      end

    opt_outs =
      for n <- 1..@plus_ones, rem(n, 4) == 0 do
        %PlusOneOptOut{id: n, person_id: @hosts + n, event_id: rem(n, @events) + 1}
      end

    categories =
      for c <- 1..@categories, do: %Category{id: c, name: "Category #{c}", sort_order: c}

    services =
      for c <- 1..@categories, s <- 1..@services_per_category do
        %Service{
          id: c * 100 + s,
          category_id: c,
          name: "Service #{c}.#{s}",
          wanted_priority: Enum.at([:must_have, :nice_to_have, :not_wanted], rem(c + s, 3)),
          sort_order: s
        }
      end

    offers =
      for o <- 1..@offers do
        exclusive? = rem(o, 2) == 0

        %Offer{
          id: o,
          category_id: rem(o, @categories) + 1,
          vendor_name: "Vendor #{o}",
          status: :considering,
          vat_basis: if(exclusive?, do: :exclusive, else: :inclusive),
          vat_rate_bp: if(exclusive?, do: 2100),
          minimum_spend: if(rem(o, 3) == 0, do: eur(5_000))
        }
      end

    lines = Enum.flat_map(offers, &lines/1)

    %Snapshot{
      events: events,
      persons: hosts ++ plus_ones,
      invitations: invitations,
      plus_one_opt_outs: opt_outs,
      categories: categories,
      services: services,
      offers: offers,
      offer_lines: lines
    }
  end

  @bases [:flat, :per_adult, :per_child, :per_attendee, :per_attendee, :per_adult]
  @states [:mandatory, :optional, :mandatory, :optional, :included, :mandatory]

  # Six lines per offer: five service lines of the offer's category plus one ad hoc line,
  # mixing bases, events, included quantities, minimum charges and line rates.
  defp lines(%Offer{id: o, category_id: c}) do
    for l <- 1..@lines_per_offer do
      basis = Enum.at(@bases, l - 1)
      per_person? = basis != :flat

      %OfferLine{
        id: o * 10 + l,
        offer_id: o,
        service_id: if(l < @lines_per_offer, do: c * 100 + l),
        label: if(l == @lines_per_offer, do: "Ad hoc #{o}"),
        state: Enum.at(@states, l - 1),
        basis: basis,
        event_id: if(per_person?, do: rem(o + l, @events) + 1),
        amount: eur(10 + rem(o * l, 90)),
        included_quantity: if(per_person? and rem(o, 4) == 0, do: 20),
        minimum_charge: if(rem(o + l, 5) == 0, do: eur(800)),
        vat_rate_bp: if(rem(l, 2) == 0, do: 1200),
        enabled: rem(o, 2) == 1
      }
    end
  end

  defp eur(amount), do: WeddingPlanner.Money.new(amount)

  # -- the test -------------------------------------------------------------------------------

  @tag :real_path
  test "every offer total under every default preset, and every headcount, in < 1 s" do
    snapshot = snapshot()
    presets = Preset.defaults()

    assert length(snapshot.persons) == @hosts + @plus_ones
    assert length(snapshot.events) == @events
    assert length(snapshot.offers) == @offers
    assert length(snapshot.offer_lines) == @offers * @lines_per_offer

    {elapsed_us, {totals, headcounts}} =
      :timer.tc(fn ->
        totals =
          for offer <- snapshot.offers, preset <- presets do
            OfferEngine.total(snapshot, offer, preset)
          end

        headcounts =
          for event <- snapshot.events ++ [:all_events], preset <- presets do
            Headcount.evaluate(snapshot, preset, event)
          end

        {totals, headcounts}
      end)

    # The work was real: every total is money, and the guest list is not empty.
    assert length(totals) == @offers * length(presets)
    assert Enum.all?(totals, &match?(%Formula{total: {:money, %Money{}}}, &1))
    assert length(headcounts) == (@events + 1) * length(presets)
    assert Enum.any?(headcounts, &(&1.total > 0))

    assert elapsed_us < @bound_us,
           "NFR-33: #{elapsed_us} µs for the whole run, bound #{@bound_us} µs"
  end

  @tag :real_path
  test "every category's comparison matrix under each of the three default presets, in < 1 s" do
    snapshot = snapshot()
    [minimum, _likely, maximum] = presets = Preset.defaults()

    # Some override rows too (DR-49), so the matrix reads them at size: every fifth
    # offer × service pair of the offer's own category.
    overrides =
      for offer <- snapshot.offers,
          s <- 1..@services_per_category,
          rem(offer.id + s, 5) == 0 do
        %{offer_id: offer.id, service_id: offer.category_id * 100 + s, wanted: rem(s, 2) == 0}
      end

    snapshot = %{snapshot | overrides: overrides}

    {elapsed_us, matrices} =
      :timer.tc(fn ->
        for category <- snapshot.categories, preset <- presets do
          Comparison.build(snapshot, category.id, preset, {minimum, maximum})
        end
      end)

    IO.puts("\nNFR-33 comparison: #{length(matrices)} matrices in #{elapsed_us} µs")

    # The work was real: every category has its ten offers as columns, each with a total
    # and a range.
    assert length(matrices) == @categories * length(presets)

    for matrix <- matrices do
      assert length(matrix.columns) == div(@offers, @categories)

      assert Enum.all?(
               matrix.columns,
               &match?(%{total: %Formula{}, range: {%Money{}, %Money{}}}, &1)
             )
    end

    assert elapsed_us < @bound_us,
           "NFR-33: #{elapsed_us} µs for every comparison matrix, bound #{@bound_us} µs"
  end
end
