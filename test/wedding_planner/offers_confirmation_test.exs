defmodule WeddingPlanner.OffersConfirmationTest do
  @moduledoc """
  Slice C5's writes (`docs/modules/offers-and-comparison.md` `CST-04`, `CST-06`, `CST-40`
  through `CST-44`; `docs/modules/invoices-and-budget.md` `BIL-05`, `BIL-07`;
  `docs/04-cross-cutting.md` `XC-01`, `XC-10`, `XC-12`, `XC-40`; `DR-58`, `DR-61` through
  `DR-67`): `Offers.confirm_offer/2`, `unconfirm_offer/2` (refused while invoices link —
  `DR-65`, user-decided), `add_to_confirmed_scope/3`, the planning pick, the override
  refusal, line edits on a confirmed offer, offer deletion, and the frozen-service rules
  in `Categories.delete_service/2` / `merge_services/3`.

  Totals are read the way every screen reads them: `Valuation.Snapshot.load/1` then
  `Valuation.Offer.total/4` under the Likely preset. The concurrent confirm / planning
  pick races are in `WeddingPlanner.OffersConfirmationConcurrencyTest`.

  `async: false`: `delete_offer/2` purges reference files (`:uploads_dir`), same reason
  `WeddingPlanner.OffersTest` is `async: false`.
  """
  use WeddingPlanner.DataCase, async: false

  import WeddingPlanner.OfferFixtures

  alias WeddingPlanner.Categories
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeGuests
  alias WeddingPlanner.NormativeOfferRows, as: Rows
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Offers.FrozenService
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.Override
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Invoices, as: InvoiceFigures
  alias WeddingPlanner.Valuation.Offer, as: OfferEngine
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Snapshot

  @nbsp <<0xA0::utf8>>

  # -- helpers -------------------------------------------------------------------------------

  defp eur(amount), do: WeddingPlanner.Money.new(amount)

  defp assert_money(%Money{} = actual, expected, what) do
    expected = if is_integer(expected), do: eur(expected), else: expected

    assert Money.equal?(actual, expected),
           "#{what}: expected #{Money.to_string!(expected)}, got #{Money.to_string!(actual)}"
  end

  defp entry_count, do: Repo.aggregate(Entry, :count)

  defp entries_since(count) do
    from(e in Entry, order_by: e.id) |> Repo.all() |> Enum.drop(count)
  end

  # The one Log.action/3 written since `count`: its summary and its children, each child
  # as `{entity_type, entity_id, description}`.
  defp action_since(count) do
    [summary | children] = entries_since(count)
    assert is_nil(summary.parent_id)
    assert Enum.all?(children, &(&1.parent_id == summary.id))
    {summary.description, Enum.map(children, &{&1.entity_type, &1.entity_id, &1.description})}
  end

  defp frozen_ids(offer_id) do
    from(f in FrozenService, where: f.offer_id == ^offer_id, select: f.service_id)
    |> Repo.all()
    |> Enum.sort()
  end

  defp ids(services, names), do: names |> Enum.map(&Map.fetch!(services, &1).id) |> Enum.sort()

  defp loaded(offer_id) do
    snapshot = Snapshot.load(Repo)
    {snapshot, Enum.find(snapshot.offers, &(&1.id == offer_id))}
  end

  defp likely_total(offer_id) do
    {snapshot, offer} = loaded(offer_id)
    likely = Enum.find(snapshot.headcount_presets, &(&1.role == :likely))
    %Formula{total: {:money, money}} = OfferEngine.total(snapshot, offer, likely)
    money
  end

  # Venue A (O1) as real rows in the normative Venue category.
  defp venue_a!(scope, opts \\ []) do
    dinner = Rows.dinner!(scope)
    {venue, services} = Rows.category!(scope, NE.venue_category())

    %{offer: offer, line_ids_by_number: line_ids} =
      Rows.offer!(scope, :venue_a, venue, services, dinner)

    if Keyword.get(opts, :guests, false), do: NormativeGuests.shared_dinner!(scope, dinner)
    %{offer: offer, venue: venue, services: services, dinner: dinner, line_ids: line_ids}
  end

  defp invoice!(scope, category, offer, label, amount) do
    {:ok, invoice} =
      Invoices.create_invoice(
        scope,
        category,
        %{label: label, invoice_date: ~D[2027-01-15], offer_id: offer.id},
        %{label: label, amount: eur(amount)}
      )

    invoice
  end

  setup do
    %{scope: scope_fixture()}
  end

  # -- 1. confirm_offer/2 (CST-40, DR-61, DR-62) ------------------------------------------------

  describe "confirm_offer/2 (CST-40, DR-61, DR-62)" do
    test "freezes Selection.freeze/2 of the pre-confirmation snapshot, overrides included; logged and broadcast",
         %{scope: scope} do
      %{offer: offer, services: services} = venue_a!(scope, guests: true)
      # Overrides decide what is frozen (CST-24): Garden ceremony (not wanted) on,
      # Late-night snack (nice-to-have) off — the priorities alone would give the opposite.
      {:ok, _} = Offers.toggle_override(scope, offer, Map.fetch!(services, "Garden ceremony"))
      {:ok, _} = Offers.toggle_override(scope, offer, Map.fetch!(services, "Late-night snack"))

      {pre_snapshot, pre_offer} = loaded(offer.id)
      expected = Selection.freeze(pre_snapshot, pre_offer)

      assert Enum.sort(expected) ==
               ids(services, ["Seating", "Catering", "Sound", "Garden ceremony"])

      pre_total = likely_total(offer.id)
      assert_money(pre_total, 12_226, "pre-confirmation total (O1 + Garden ceremony)")

      Realtime.subscribe(:offer)
      Realtime.subscribe(:frozen_service)
      before = entry_count()

      assert {:ok, %Offer{status: :confirmed, planning_pick: false} = confirmed} =
               Offers.confirm_offer(scope, offer)

      assert frozen_ids(offer.id) == Enum.sort(expected)
      assert_money(likely_total(offer.id), pre_total, "total at the moment of confirmation")

      assert action_since(before) ==
               {"Wannes confirmed offer 'Venue A'",
                [
                  {"offer", offer.id,
                   "Wannes changed the status of offer 'Venue A': considering → confirmed"},
                  {"offer", offer.id,
                   "Wannes froze 4 services for offer 'Venue A': Seating, Catering, Sound, Garden ceremony"}
                ]}

      offer_id = offer.id
      assert_received {Realtime, :offer, {:updated, %Offer{id: ^offer_id, status: :confirmed}}}

      for _ <- 1..4 do
        assert_received {Realtime, :frozen_service,
                         {:created, %FrozenService{offer_id: ^offer_id}}}
      end

      refute_received {Realtime, :frozen_service, _}

      # Confirming again is refused — nothing written, nothing logged.
      before = entry_count()
      assert Offers.confirm_offer(scope, confirmed) == {:error, :already_confirmed}
      assert Offers.confirm_offer(scope, offer) == {:error, :already_confirmed}
      assert entry_count() == before
      assert frozen_ids(offer.id) == Enum.sort(expected)
    end

    test "an offer with nothing effectively wanted freezes no services", %{scope: scope} do
      category = category_fixture(scope)

      _garden =
        service_fixture(scope, category, %{"name" => "Garden", "wanted_priority" => "not_wanted"})

      offer = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})
      before = entry_count()

      assert {:ok, _} = Offers.confirm_offer(scope, offer)
      assert frozen_ids(offer.id) == []

      assert {_summary, [_status, {"offer", _, "Wannes froze no services for offer 'Venue A'"}]} =
               action_since(before)
    end
  end

  # -- 2. from every status; un-confirm → shortlisted (CST-42, DR-62) ---------------------------

  describe "confirm from any status, un-confirm to shortlisted (CST-42, DR-62)" do
    test "considering, shortlisted and rejected all confirm; un-confirming always gives shortlisted",
         %{scope: scope} do
      category = category_fixture(scope)
      _sound = service_fixture(scope, category)

      for status <- [:considering, :shortlisted, :rejected] do
        offer = offer_fixture(scope, category, %{"vendor_name" => "Offer #{status}"})

        offer =
          if status == :considering,
            do: offer,
            else:
              elem(Offers.update_offer(scope, offer, %{"status" => Atom.to_string(status)}), 1)

        assert offer.status == status
        before = entry_count()
        assert {:ok, %Offer{status: :confirmed} = confirmed} = Offers.confirm_offer(scope, offer)

        assert {_, [{"offer", _, status_entry} | _]} = action_since(before)
        assert status_entry =~ ": #{status} → confirmed"

        assert {:ok, %Offer{status: :shortlisted}} = Offers.unconfirm_offer(scope, confirmed)
        assert Offers.get_offer!(offer.id).status == :shortlisted
        assert frozen_ids(offer.id) == []
      end
    end

    test "un-confirming an offer that is not confirmed is refused", %{scope: scope} do
      offer = offer_fixture(scope, category_fixture(scope))
      before = entry_count()
      assert Offers.unconfirm_offer(scope, offer) == {:error, :not_confirmed}
      assert entry_count() == before
    end
  end

  # -- 3. confirming clears another offer's planning pick (DR-66) --------------------------------

  describe "confirming clears the category's planning pick (DR-66)" do
    test "another offer's pick is cleared, with an entry on that offer", %{scope: scope} do
      category = category_fixture(scope)
      venue_a = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})
      venue_b = offer_fixture(scope, category, %{"vendor_name" => "Venue B"})
      {:ok, %Offer{planning_pick: true}} = Offers.set_planning_pick(scope, venue_b)

      Realtime.subscribe(:offer)
      before = entry_count()
      assert {:ok, _} = Offers.confirm_offer(scope, venue_a)

      refute Offers.get_offer!(venue_b.id).planning_pick
      venue_b_id = venue_b.id

      assert_received {Realtime, :offer,
                       {:updated, %Offer{id: ^venue_b_id, planning_pick: false}}}

      {_summary, children} = action_since(before)

      assert {"offer", venue_b.id,
              "Wannes cleared offer 'Venue B' as the planning pick for Venue (an offer in Venue was confirmed)"} in children

      # Un-confirming does not restore it (DR-66).
      {:ok, _} = Offers.unconfirm_offer(scope, Offers.get_offer!(venue_a.id))
      refute Offers.get_offer!(venue_b.id).planning_pick
    end

    test "confirming the pick itself clears it in the same UPDATE, logged", %{scope: scope} do
      category = category_fixture(scope)
      venue_a = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})
      {:ok, picked} = Offers.set_planning_pick(scope, venue_a)
      before = entry_count()

      assert {:ok, %Offer{planning_pick: false}} = Offers.confirm_offer(scope, picked)
      {_summary, children} = action_since(before)

      assert {"offer", venue_a.id,
              "Wannes cleared offer 'Venue A' as the planning pick for Venue (offer confirmed)"} in children
    end
  end

  # -- 4. un-confirm (CST-42, DR-58, DR-64, DR-65) ------------------------------------------------

  describe "unconfirm_offer/2 (CST-42, DR-58, DR-64, DR-65)" do
    setup %{scope: scope} do
      %{offer: offer, venue: venue, services: services} = venue_a!(scope, guests: true)
      # An override from before the confirmation: Garden ceremony (not wanted) on.
      {:ok, _} = Offers.toggle_override(scope, offer, Map.fetch!(services, "Garden ceremony"))
      pre_total = likely_total(offer.id)
      {:ok, confirmed} = Offers.confirm_offer(scope, offer)
      deposit = invoice!(scope, venue, confirmed, "Venue deposit", 3000)
      final = invoice!(scope, venue, confirmed, "Final invoice", 8900)
      {:ok, confirmed} = Invoices.set_invoicing_complete(scope, confirmed, true)

      %{
        offer: confirmed,
        services: services,
        pre_total: pre_total,
        invoices: [deposit, final]
      }
    end

    test "refused while invoices link — nothing changes (DR-65)", %{scope: scope, offer: offer} do
      assert Offers.unconfirm_blockers(offer) == [
               "2 invoices are linked to it: 'Venue deposit', 'Final invoice' — unlink them first"
             ]

      frozen_before = frozen_ids(offer.id)
      before = entry_count()

      assert Offers.unconfirm_offer(scope, offer) == {:error, :has_invoices}

      assert %Offer{status: :confirmed, invoicing_complete: true} = Offers.get_offer!(offer.id)
      assert frozen_ids(offer.id) == frozen_before
      assert entry_count() == before
    end

    test "after unlinking: rows gone, invoicing complete cleared in the same UPDATE, overrides back in force",
         %{scope: scope, offer: offer, pre_total: pre_total, invoices: [deposit, final]} do
      {:ok, _} = Invoices.update_invoice(scope, deposit, %{"offer_id" => nil})

      assert Offers.unconfirm_blockers(offer) == [
               "1 invoice is linked to it: 'Final invoice' — unlink it first"
             ]

      {:ok, _} = Invoices.update_invoice(scope, final, %{"offer_id" => nil})
      assert Offers.unconfirm_blockers(offer) == []

      assert Offers.unconfirm_effects(offer) == [
               %{label: "5 services leave the confirmed scope", count: 5},
               %{label: "Invoicing complete will be cleared", count: 1}
             ]

      frozen = Offers.list_frozen_services(offer)
      Realtime.subscribe(:offer)
      Realtime.subscribe(:frozen_service)
      before = entry_count()

      assert {:ok, %Offer{status: :shortlisted, invoicing_complete: false}} =
               Offers.unconfirm_offer(scope, offer)

      assert frozen_ids(offer.id) == []
      assert %Offer{status: :shortlisted, invoicing_complete: false} = Offers.get_offer!(offer.id)

      assert action_since(before) ==
               {"Wannes un-confirmed offer 'Venue A'",
                [
                  {"offer", offer.id,
                   "Wannes changed the status of offer 'Venue A': confirmed → shortlisted"},
                  {"offer", offer.id,
                   "Wannes discarded the confirmed scope of offer 'Venue A' (5 services)"},
                  {"offer", offer.id,
                   "Wannes cleared invoicing complete for offer 'Venue A' (offer un-confirmed)"}
                ]}

      for %FrozenService{id: id} <- frozen do
        assert_received {Realtime, :frozen_service, {:deleted, ^id}}
      end

      offer_id = offer.id
      assert_received {Realtime, :offer, {:updated, %Offer{id: ^offer_id, status: :shortlisted}}}

      # DR-64: the override row survived the confirmation and is in force again.
      assert Repo.aggregate(from(o in Override, where: o.offer_id == ^offer.id), :count) == 1
      assert_money(likely_total(offer.id), pre_total, "total after un-confirming")
      assert Offers.unconfirm_effects(Offers.get_offer!(offer.id)) == []
    end
  end

  # -- 5. add_to_confirmed_scope/3 (CST-43 case 2, DR-64) ----------------------------------------

  describe "add_to_confirmed_scope/3 (CST-43, DR-64)" do
    test "refused unless confirmed, for another category, or when already in scope; then the line counts",
         %{scope: scope} do
      %{offer: offer, services: services, line_ids: line_ids} = venue_a!(scope)
      garden = Map.fetch!(services, "Garden ceremony")
      other_service = service_fixture(scope, category_fixture(scope, %{"name" => "Catering"}))

      assert Offers.add_to_confirmed_scope(scope, offer, garden) == {:error, :not_confirmed}

      {:ok, confirmed} = Offers.confirm_offer(scope, offer)

      assert Offers.add_to_confirmed_scope(scope, confirmed, other_service) ==
               {:error, :wrong_category}

      assert Offers.add_to_confirmed_scope(scope, confirmed, Map.fetch!(services, "Seating")) ==
               {:error, :already_in_scope}

      garden_line_id = Map.fetch!(line_ids, 6)
      {snapshot, loaded_offer} = loaded(offer.id)
      garden_line = Enum.find(snapshot.offer_lines, &(&1.id == garden_line_id))
      assert Selection.inclusion(snapshot, loaded_offer, garden_line) == :outside_scope
      total_before = likely_total(offer.id)

      Realtime.subscribe(:frozen_service)
      before = entry_count()

      assert {:ok, %FrozenService{offer_id: offer_id, service_id: garden_id} = row} =
               Offers.add_to_confirmed_scope(scope, confirmed, garden)

      assert {offer_id, garden_id} == {offer.id, garden.id}
      assert_received {Realtime, :frozen_service, {:created, ^row}}

      assert [%Entry{entity_type: "offer", description: description}] = entries_since(before)

      assert description ==
               "Wannes added 'Garden ceremony' to the confirmed scope of offer 'Venue A'"

      {snapshot, loaded_offer} = loaded(offer.id)
      garden_line = Enum.find(snapshot.offer_lines, &(&1.id == garden_line_id))
      assert Selection.inclusion(snapshot, loaded_offer, garden_line) == :counted

      assert_money(
        Money.sub!(likely_total(offer.id), total_before),
        500,
        "Garden ceremony's line"
      )

      assert Offers.add_to_confirmed_scope(scope, confirmed, garden) ==
               {:error, :already_in_scope}
    end
  end

  # -- 6. toggle_override/3 on a confirmed offer (DR-64) -------------------------------------------

  describe "toggle_override/3 on a confirmed offer (DR-64)" do
    test "is refused before anything else — no row, no entry", %{scope: scope} do
      category = category_fixture(scope)
      sound = service_fixture(scope, category)
      offer = offer_fixture(scope, category)
      {:ok, confirmed} = Offers.confirm_offer(scope, offer)
      before = entry_count()

      assert Offers.toggle_override(scope, confirmed, sound) == {:error, :confirmed}
      # A stale struct still reading "considering" is refused too — the stored status decides.
      assert Offers.toggle_override(scope, offer, sound) == {:error, :confirmed}

      assert Repo.aggregate(Override, :count) == 0
      assert entry_count() == before
    end
  end

  # -- 7. set_line_enabled/3 on a confirmed offer (CST-43 case 3, DR-64) ---------------------------

  describe "set_line_enabled/3 on a confirmed offer (CST-43 case 3, DR-64)" do
    test "logs the confirmed-scope wording both ways", %{scope: scope} do
      category = category_fixture(scope)
      offer = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})

      {:ok, line} =
        Offers.create_line(scope, offer, %{
          "label" => "Corkage fee",
          "state" => "optional",
          "basis" => "flat",
          "amount" => eur(100)
        })

      {:ok, _} = Offers.confirm_offer(scope, offer)

      before = entry_count()
      {:ok, line} = Offers.set_line_enabled(scope, line, true)
      {:ok, _line} = Offers.set_line_enabled(scope, line, false)

      assert Enum.map(entries_since(before), & &1.description) == [
               "Wannes turned on 'Corkage fee' in offer 'Venue A' (added to the confirmed scope)",
               "Wannes turned off 'Corkage fee' in offer 'Venue A' (removed from the confirmed scope)"
             ]
    end
  end

  # -- 8. line edits on a confirmed offer are logged (CST-43) --------------------------------------

  describe "line create/update/delete on a confirmed offer (CST-43)" do
    test "each writes an activity entry against the offer", %{scope: scope} do
      category = category_fixture(scope)
      sound = service_fixture(scope, category)
      offer = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})
      {:ok, _} = Offers.confirm_offer(scope, offer)

      before = entry_count()

      {:ok, line} =
        Offers.create_line(scope, offer, %{
          "service_id" => sound.id,
          "state" => "optional",
          "basis" => "flat",
          "amount" => eur(250)
        })

      {:ok, line} = Offers.update_line(scope, line, %{"amount" => eur(300)})
      {:ok, _} = Offers.delete_line(scope, line)

      entries = entries_since(before)
      assert Enum.all?(entries, &(&1.entity_type == "offer" and &1.entity_id == offer.id))

      assert Enum.map(entries, & &1.description) == [
               "Wannes added line 'Sound (optional)' to offer 'Venue A'",
               "Wannes changed the amount of line 'Sound (optional)' in offer 'Venue A': €#{@nbsp}250,00 → €#{@nbsp}300,00",
               "Wannes deleted line 'Sound (optional)' from offer 'Venue A'"
             ]
    end
  end

  # -- 9. planning pick (CST-44, DR-66) ------------------------------------------------------------

  describe "planning pick (CST-44, DR-66)" do
    setup %{scope: scope} do
      category = category_fixture(scope)
      venue_a = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})
      venue_b = offer_fixture(scope, category, %{"vendor_name" => "Venue B"})
      %{category: category, venue_a: venue_a, venue_b: venue_b}
    end

    test "set, move (both offers logged), set again (no-op) and clear", %{
      scope: scope,
      category: category,
      venue_a: venue_a,
      venue_b: venue_b
    } do
      Realtime.subscribe(:offer)
      before = entry_count()
      assert {:ok, %Offer{planning_pick: true}} = Offers.set_planning_pick(scope, venue_a)

      assert action_since(before) ==
               {"Wannes made offer 'Venue A' the planning pick for Venue",
                [{"offer", venue_a.id, "Wannes made offer 'Venue A' the planning pick for Venue"}]}

      venue_a_id = venue_a.id
      assert_received {Realtime, :offer, {:updated, %Offer{id: ^venue_a_id, planning_pick: true}}}

      before = entry_count()
      assert {:ok, %Offer{planning_pick: true}} = Offers.set_planning_pick(scope, venue_b)
      refute Offers.get_offer!(venue_a.id).planning_pick

      assert action_since(before) ==
               {"Wannes made offer 'Venue B' the planning pick for Venue",
                [
                  {"offer", venue_a.id,
                   "Wannes cleared offer 'Venue A' as the planning pick for Venue (moved to offer 'Venue B')"},
                  {"offer", venue_b.id, "Wannes made offer 'Venue B' the planning pick for Venue"}
                ]}

      assert_received {Realtime, :offer,
                       {:updated, %Offer{id: ^venue_a_id, planning_pick: false}}}

      venue_b_id = venue_b.id
      assert_received {Realtime, :offer, {:updated, %Offer{id: ^venue_b_id, planning_pick: true}}}

      before = entry_count()
      assert {:ok, %Offer{planning_pick: true}} = Offers.set_planning_pick(scope, venue_b)
      assert entry_count() == before

      assert Repo.aggregate(
               from(o in Offer, where: o.category_id == ^category.id and o.planning_pick),
               :count
             ) == 1

      assert {:ok, %Offer{planning_pick: false}} = Offers.clear_planning_pick(scope, venue_b)

      assert [%Entry{entity_id: ^venue_b_id, description: description}] = entries_since(before)
      assert description == "Wannes cleared offer 'Venue B' as the planning pick for Venue"

      before = entry_count()
      assert {:ok, %Offer{planning_pick: false}} = Offers.clear_planning_pick(scope, venue_b)
      assert entry_count() == before
    end

    test "refused for a rejected or a confirmed offer, and in a category with a confirmed offer",
         %{scope: scope, category: category, venue_a: venue_a, venue_b: venue_b} do
      {:ok, rejected} = Offers.update_offer(scope, venue_b, %{"status" => "rejected"})
      assert Offers.set_planning_pick(scope, rejected) == {:error, :rejected}

      refute Offers.category_has_confirmed_offer?(category)
      {:ok, confirmed} = Offers.confirm_offer(scope, venue_a)
      assert Offers.category_has_confirmed_offer?(category)
      assert Offers.category_has_confirmed_offer?(category.id)
      assert Offers.set_planning_pick(scope, confirmed) == {:error, :confirmed}

      venue_c = offer_fixture(scope, category, %{"vendor_name" => "Venue C"})
      before = entry_count()
      assert Offers.set_planning_pick(scope, venue_c) == {:error, :category_has_confirmed_offer}
      assert entry_count() == before
      refute Offers.get_offer!(venue_c.id).planning_pick
    end

    test "rejecting the pick via update_offer/3 clears it in the same UPDATE, logged", %{
      scope: scope,
      venue_a: venue_a
    } do
      {:ok, _} = Offers.set_planning_pick(scope, venue_a)
      before = entry_count()

      # A stale struct (planning_pick still false) must not trip the CHECK either.
      assert {:ok, %Offer{status: :rejected, planning_pick: false}} =
               Offers.update_offer(scope, venue_a, %{"status" => "rejected"})

      refute Offers.get_offer!(venue_a.id).planning_pick

      assert Enum.map(entries_since(before), & &1.description) == [
               "Wannes changed the status of offer 'Venue A': considering → rejected",
               "Wannes cleared offer 'Venue A' as the planning pick for Venue (offer rejected)"
             ]
    end
  end

  # -- 10. delete_offer/2 of a confirmed offer (DR-67) ---------------------------------------------

  describe "delete_offer/2 of a confirmed offer (DR-67)" do
    test "removes the frozen rows inside its own action; the effects name the scope", %{
      scope: scope
    } do
      category = category_fixture(scope)
      _sound = service_fixture(scope, category)
      _seating = service_fixture(scope, category, %{"name" => "Seating"})
      offer = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})
      {:ok, confirmed} = Offers.confirm_offer(scope, offer)
      frozen = Offers.list_frozen_services(confirmed)
      assert length(frozen) == 2

      assert %{label: "Its confirmed scope (2 services)", count: 2} in Offers.offer_deletion_effects(
               confirmed
             )

      Realtime.subscribe(:frozen_service)
      before = entry_count()
      assert {:ok, _} = Offers.delete_offer(scope, confirmed)

      assert Repo.aggregate(FrozenService, :count) == 0
      {summary, children} = action_since(before)
      assert summary == "Wannes deleted offer 'Venue A'"

      assert {"offer", offer.id,
              "Wannes discarded the confirmed scope of offer 'Venue A' (offer deleted)"} in children

      for %FrozenService{id: id} <- frozen do
        assert_received {Realtime, :frozen_service, {:deleted, ^id}}
      end
    end
  end

  # -- 11. Categories.delete_service/2 (CST-06, CST-43 case 4, DR-67) ------------------------------

  describe "Categories.delete_service/2 of a frozen-in service (CST-06, DR-67)" do
    test "is refused even with no lines left; service_frozen_offers/1 names the offer", %{
      scope: scope
    } do
      category = category_fixture(scope)
      sound = service_fixture(scope, category)
      offer = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})

      {:ok, line} =
        Offers.create_line(scope, offer, %{
          "service_id" => sound.id,
          "state" => "optional",
          "basis" => "flat",
          "amount" => eur(250)
        })

      {:ok, confirmed} = Offers.confirm_offer(scope, offer)
      # CST-43 case 4: the last line goes, the service stays in the frozen selection.
      {:ok, _} = Offers.delete_line(scope, line)
      assert Categories.service_line_count(sound) == 0

      before = entry_count()
      assert Categories.delete_service(scope, sound) == {:error, :in_confirmed_scope}
      assert Categories.get_service!(sound.id)
      assert entry_count() == before
      assert [%Offer{id: offer_id}] = Categories.service_frozen_offers(sound)
      assert offer_id == offer.id

      # Once un-confirmed, the service is deletable again.
      {:ok, _} = Offers.unconfirm_offer(scope, confirmed)
      assert Categories.service_frozen_offers(sound) == []
      assert {:ok, _} = Categories.delete_service(scope, sound)
    end
  end

  # -- 12. Categories.merge_services/3 (CST-04, DR-67) ---------------------------------------------

  describe "Categories.merge_services/3 with frozen selections (CST-04, DR-67)" do
    setup %{scope: scope} do
      venue = venue_a!(scope, guests: true)
      {:ok, confirmed} = Offers.confirm_offer(scope, venue.offer)
      total = likely_total(confirmed.id)
      assert_money(total, 11_726, "O1 confirmed")
      Map.merge(venue, %{offer: confirmed, total: total})
    end

    test "both in scope: the absorbed row is dropped, the total is unchanged", %{
      scope: scope,
      offer: offer,
      services: services,
      total: total
    } do
      sound = Map.fetch!(services, "Sound")
      seating = Map.fetch!(services, "Seating")
      absorbed_row = Repo.get_by!(FrozenService, offer_id: offer.id, service_id: sound.id)
      Realtime.subscribe(:frozen_service)
      before = entry_count()

      assert {:ok, _} = Categories.merge_services(scope, sound, seating)

      assert frozen_ids(offer.id) == ids(services, ["Seating", "Catering", "Late-night snack"])
      assert_money(likely_total(offer.id), total, "total after a both-in merge")
      absorbed_id = absorbed_row.id
      assert_received {Realtime, :frozen_service, {:deleted, ^absorbed_id}}

      {_summary, children} = action_since(before)

      assert {"offer", offer.id,
              "Wannes dropped 'Sound' from the confirmed scope of offer 'Venue A' ('Seating' is already in it; services merged)"} in children
    end

    test "exactly one in scope: refused before anything is written, naming the offer", %{
      scope: scope,
      offer: offer,
      services: services
    } do
      garden = Map.fetch!(services, "Garden ceremony")
      sound = Map.fetch!(services, "Sound")
      frozen_before = frozen_ids(offer.id)
      before = entry_count()

      assert {:error, {:confirmed_scope_mismatch, [%Offer{id: offer_id}]}} =
               Categories.merge_services(scope, garden, sound)

      assert offer_id == offer.id

      assert {:error, {:confirmed_scope_mismatch, [%Offer{}]}} =
               Categories.merge_services(scope, sound, garden)

      assert entry_count() == before
      assert frozen_ids(offer.id) == frozen_before
      assert Categories.get_service!(garden.id)
    end

    test "both out of scope: allowed, the total is unchanged", %{
      scope: scope,
      offer: offer,
      venue: venue,
      services: services,
      total: total
    } do
      garden = Map.fetch!(services, "Garden ceremony")
      # Created after the confirmation, so outside the frozen selection.
      fireworks = service_fixture(scope, venue, %{"name" => "Fireworks"})
      frozen_before = frozen_ids(offer.id)

      assert {:ok, _} = Categories.merge_services(scope, fireworks, garden)
      assert frozen_ids(offer.id) == frozen_before
      assert_money(likely_total(offer.id), total, "total after a both-out merge")
    end
  end

  # -- 13. B1/B2 through the real path (BIL-05, BIL-07) --------------------------------------------

  describe "B1/B2 through confirm_offer/2" do
    @describetag :real_path

    test "a paid €3,000 deposit leaves €8,726 not yet invoiced; the final invoice puts it €174 above",
         %{scope: scope} do
      %{offer: offer, venue: venue} = venue_a!(scope, guests: true)
      {:ok, confirmed} = Offers.confirm_offer(scope, offer)

      [deposit_given] = NE.given("B1").invoices

      {:ok, deposit} =
        Invoices.create_invoice(
          scope,
          venue,
          %{label: deposit_given.label, invoice_date: ~D[2027-01-15], offer_id: confirmed.id},
          %{label: deposit_given.label, amount: deposit_given.amount}
        )

      {:ok, _} = Invoices.mark_paid(scope, deposit, ~D[2027-01-31])

      {snapshot, loaded_offer} = loaded(offer.id)
      likely = Enum.find(snapshot.headcount_presets, &(&1.role == :likely))
      b1 = InvoiceFigures.variance(snapshot, loaded_offer, likely)
      assert_money(b1.amount, 8726, "B1 variance")
      assert b1.direction == :not_yet_invoiced

      final_given = Enum.find(NE.given("B2").invoices, &(&1.label == "Final invoice"))

      {:ok, _final} =
        Invoices.create_invoice(
          scope,
          venue,
          %{label: final_given.label, invoice_date: ~D[2027-06-20], offer_id: confirmed.id},
          %{label: final_given.label, amount: final_given.amount}
        )

      {:ok, _} = Invoices.set_invoicing_complete(scope, confirmed, true)

      {snapshot, loaded_offer} = loaded(offer.id)
      assert loaded_offer.invoicing_complete
      b2 = InvoiceFigures.variance(snapshot, loaded_offer, likely)
      assert_money(b2.amount, 174, "B2 variance")
      assert b2.direction == :above_committed
    end
  end

  # -- 14. CST-40 / CST-41 through the real path -------------------------------------------------

  describe "CST-40 and CST-41 through confirm_offer/2" do
    @describetag :real_path

    test "a priority change and an override attempt leave €11,726; an extra accepted adult moves it",
         %{scope: scope} do
      %{offer: offer, services: services, dinner: dinner} = venue_a!(scope, guests: true)
      {:ok, confirmed} = Offers.confirm_offer(scope, offer)
      assert_money(likely_total(offer.id), 11_726, "O1 confirmed")

      catering = Map.fetch!(services, "Catering")

      {:ok, catering} =
        Categories.update_service(scope, catering, %{"wanted_priority" => "not_wanted"})

      assert Offers.toggle_override(scope, confirmed, catering) == {:error, :confirmed}
      assert_money(likely_total(offer.id), 11_726, "after Catering → not wanted (CST-40)")

      {:ok, extra} =
        Guests.create_person(scope, %{"first_name" => "Extra", "last_name" => "Guest"})

      {:ok, _} = Invitations.set_invitation_status(scope, extra, dinner, :accepted)

      # Seating: €12 per attendee beyond the 50 included — 29 instead of 28 (CST-41).
      assert_money(likely_total(offer.id), 11_738, "after one extra accepted adult (CST-41)")
    end
  end
end
