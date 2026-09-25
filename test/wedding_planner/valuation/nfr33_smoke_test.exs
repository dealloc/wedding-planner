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
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Invoices.InvoiceLine
  alias WeddingPlanner.Offers.FrozenService
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Settings
  alias WeddingPlanner.Valuation.Budget
  alias WeddingPlanner.Valuation.Comparison
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Offer, as: OfferEngine
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.PresetChoice
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Simulation
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

  # The same snapshot with budget data at size: the three default presets stored; in
  # categories 2–6 two confirmed offers each (offers 1–5 and 11–15, D-20) with their
  # frozen selections (`Selection.freeze/2` before confirming), every other one invoicing
  # complete; a planning pick in categories 7–9 (offers 6–8); targets on odd categories;
  # three invoices per category (linked to a confirmed offer where there is one, every
  # other one paid); an overall budget.
  defp budget_snapshot do
    base = snapshot()
    confirmed_ids = Enum.to_list(1..5) ++ Enum.to_list(11..15)
    pick_ids = [6, 7, 8]

    frozen =
      for offer <- base.offers,
          offer.id in confirmed_ids,
          service_id <- Selection.freeze(base, offer),
          do: %FrozenService{
            id: {offer.id, service_id},
            offer_id: offer.id,
            service_id: service_id
          }

    offers =
      Enum.map(base.offers, fn offer ->
        cond do
          offer.id in confirmed_ids ->
            %{offer | status: :confirmed, invoicing_complete: rem(offer.id, 2) == 0}

          offer.id in pick_ids ->
            %{offer | status: :shortlisted, planning_pick: true}

          true ->
            offer
        end
      end)

    categories =
      Enum.map(base.categories, fn category ->
        if rem(category.id, 2) == 1, do: %{category | target: eur(7_500)}, else: category
      end)

    invoices =
      for category <- categories, n <- 1..3 do
        linked =
          Enum.find(offers, &(&1.category_id == category.id and &1.status == :confirmed))

        %Invoice{
          id: category.id * 10 + n,
          category_id: category.id,
          offer_id: if(linked && n < 3, do: linked.id),
          label: "Invoice #{category.id}.#{n}",
          invoice_date: ~D[2027-01-01],
          paid_on: if(rem(n, 2) == 1, do: ~D[2027-02-01])
        }
      end

    invoice_lines =
      for invoice <- invoices,
          do: %InvoiceLine{id: invoice.id, invoice_id: invoice.id, label: "L", amount: eur(1_250)}

    %{
      base
      | offers: offers,
        categories: categories,
        frozen_services: frozen,
        invoices: invoices,
        invoice_lines: invoice_lines,
        headcount_presets: Preset.defaults(),
        settings: %Settings{overall_budget: eur(60_000)}
    }
  end

  @tag :real_path
  test "the budget under the three role presets plus one single-figure preset, in < 1 s" do
    snapshot = budget_snapshot()
    default = PresetChoice.default(snapshot.headcount_presets)

    {elapsed_us, {by_role, single}} =
      :timer.tc(fn ->
        {:ok, by_role} = Budget.for_roles(snapshot)
        {by_role, Budget.overall(snapshot, default)}
      end)

    IO.puts("\nNFR-33 budget: for_roles/1 + overall/2 in #{elapsed_us} µs")

    # The work was real: every category, every branch, a forecast formula per role.
    for overall <- [single | Map.values(by_role)] do
      assert length(overall.categories) == @categories
      assert match?(%Formula{total: {:money, %Money{}}}, overall.forecast)

      assert overall.categories |> Enum.map(& &1.branch) |> MapSet.new() ==
               MapSet.new([:confirmed, :planning_pick, :target, :no_target])
    end

    assert elapsed_us < @bound_us,
           "NFR-33: #{elapsed_us} µs for the budget under every role preset, bound #{@bound_us} µs"
  end

  @tag :real_path
  test "a what-if preview (10 persons × 3 events) and a host's marginal cost, each in < 1 s" do
    snapshot = budget_snapshot()
    default = PresetChoice.default(snapshot.headcount_presets)
    statuses = [:planned, :invited, :accepted, :declined, :not_invited]

    # Hosts 1–10 on events 1–3, cycling through every desired status (DR-80).
    draft =
      Map.new(1..10, fn p ->
        {p, Map.new(1..3, fn e -> {e, Enum.at(statuses, rem(p + e, length(statuses)))} end)}
      end)

    {preview_us, preview} =
      :timer.tc(fn ->
        {:ok, baseline} = Simulation.baseline(snapshot, default)
        Simulation.preview(baseline, draft)
      end)

    # Host 1 has the +1 131 (BUD-22: removed together).
    host_id = 1
    true = Enum.any?(snapshot.persons, &(&1.host_id == host_id))

    {marginal_us, {:ok, marginal}} =
      :timer.tc(fn -> Simulation.marginal_cost(snapshot, host_id) end)

    IO.puts(
      "\nNFR-33 simulation: baseline + preview in #{preview_us} µs, marginal cost in #{marginal_us} µs"
    )

    # The work was real: changed cells, every category and headcount row per role, and a
    # marginal cost with the host and their +1 removed.
    assert preview.cells != []

    for evaluation <- [preview.selected | Map.values(preview.roles)] do
      assert length(evaluation.categories) == @categories
      assert length(evaluation.headcounts) == @events + 1
      assert match?(%Formula{total: {:money, %Money{}}}, evaluation.overall.delta)
    end

    for %{formula: formula, removed: removed} <- Map.values(marginal) do
      assert match?(%Formula{total: {:money, %Money{}}}, formula)
      assert length(removed) == 2
    end

    assert preview_us < @bound_us,
           "NFR-33: #{preview_us} µs for baseline + preview, bound #{@bound_us} µs"

    assert marginal_us < @bound_us,
           "NFR-33: #{marginal_us} µs for a marginal cost, bound #{@bound_us} µs"
  end
end
