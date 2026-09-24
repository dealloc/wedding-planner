defmodule WeddingPlannerWeb.Live.OfferLiveConfirmationTest do
  @moduledoc """
  The offer page's confirmation UI (task 74; `docs/modules/offers-and-comparison.md`
  `CST-40` through `CST-44`; `docs/04-cross-cutting.md` `XC-01`, `XC-40`;
  `docs/modules/invoices-and-budget.md` `BIL-05`, `BIL-07`): the `#offer-status`
  control (`DR-62`), Un-confirm and its blocked panel (`DR-65` final — the
  **ORCHESTRATOR AMENDMENT**), the planning pick (`DR-66`), outside-confirmed-scope
  lines and their "Add to confirmed scope" action (`DR-64`), the CST-43 case 4
  delete-confirmation sentence, the `:override`/`:frozen_service` live subscriptions
  (`XC-01` drift fix), and task 70's Invoices section becoming reachable for the first
  time through this page's own confirm control.

  `async: false`: mutates stored offer status/invoice links directly from the test
  process and reads live broadcasts across two connected views in the same test — the
  same reasoning `WeddingPlannerWeb.Live.OfferLiveInvoicesTest` gives.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WeddingPlanner.OfferFixtures

  alias WeddingPlanner.Invoices
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeGuests
  alias WeddingPlanner.NormativeOfferRows, as: Rows
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Offer, as: OfferEngine
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Format

  setup %{conn: conn} do
    scope = scope_fixture()
    category = category_fixture(scope)

    %{conn: log_in_user(conn, scope.user), scope: scope, category: category}
  end

  # -- helpers -------------------------------------------------------------------------------

  defp eur(amount), do: WeddingPlanner.Money.new(amount)
  defp nbsp, do: <<0xA0::utf8>>
  defp eur_text(str), do: "€#{nbsp()}#{str}"

  defp likely_total(offer_id) do
    snapshot = Snapshot.load(Repo)
    offer = Enum.find(snapshot.offers, &(&1.id == offer_id))
    likely = Enum.find(snapshot.headcount_presets, &(&1.role == :likely))
    %{total: {:money, money}} = OfferEngine.total(snapshot, offer, likely)
    money
  end

  defp assert_money(%Money{} = actual, %Money{} = expected, what) do
    assert Money.equal?(actual, expected),
           "#{what}: expected #{Money.to_string!(expected)}, got #{Money.to_string!(actual)}"
  end

  # -- 1. #offer-status confirms the offer (DR-62) -----------------------------------------

  describe "the #offer-status control (DR-62)" do
    test "picking Confirmed confirms the offer; the pill replaces the control; an entry is logged",
         %{conn: conn, scope: scope, category: category} do
      offer = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})

      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      assert has_element?(view, "#offer-status option[value=confirmed]")

      view
      |> form("#offer-status-form", %{"status" => "confirmed"})
      |> render_change()

      assert Offers.get_offer!(offer.id).status == :confirmed
      assert has_element?(view, "#offer-status-pill", "Confirmed")
      refute has_element?(view, "#offer-status-form")
      # `confirm_offer/2`'s `Log.action/3` summary itself carries no `entity_type`
      # (excluded from a per-entity history, `Log.Query.for_entity/2`'s moduledoc) —
      # its per-offer child entry is what `#offer-history` shows.
      assert has_element?(
               view,
               "#offer-history",
               "changed the status of offer 'Venue A': considering → confirmed"
             )
    end

    # Named fail-proof 3 (task 74 amendment territory: same fail-proof 1 in the task
    # file — keeping `status` inside `#offer-form` breaks this, since the generic
    # `Offer.changeset/2` refuses a `:confirmed` transition outright).
    test "picking Rejected updates only the status, nothing else in the header form",
         %{conn: conn, scope: scope, category: category} do
      offer =
        offer_fixture(scope, category, %{"vendor_name" => "Venue A", "notes" => "Great venue"})

      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      view
      |> form("#offer-status-form", %{"status" => "rejected"})
      |> render_change()

      reloaded = Offers.get_offer!(offer.id)
      assert reloaded.status == :rejected
      assert reloaded.vendor_name == "Venue A"
      assert reloaded.notes == "Great venue"
    end
  end

  # -- 2. Un-confirm, the blocked panel (DR-65 final, the ORCHESTRATOR AMENDMENT) ------------

  describe "un-confirm (CST-42, DR-65 final)" do
    setup %{scope: scope, category: category} do
      offer = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})
      {:ok, confirmed} = Offers.confirm_offer(scope, offer)
      %{offer: confirmed}
    end

    test "refused while an invoice links to the offer — the blocked panel names it, Cancel only",
         %{conn: conn, scope: scope, category: category, offer: offer} do
      {:ok, invoice} =
        Invoices.create_invoice(
          scope,
          category,
          %{label: "Deposit", invoice_date: ~D[2027-01-15], offer_id: offer.id},
          %{label: "Deposit", amount: eur(100)}
        )

      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      view |> element("#offer-unconfirm") |> render_click()

      assert has_element?(view, "#offer-unconfirm-blocked", "Deposit")
      refute has_element?(view, "#offer-unconfirm-confirm")

      view |> element("#offer-unconfirm-blocked-cancel") |> render_click()
      refute has_element?(view, "#offer-unconfirm-blocked")

      assert Offers.get_offer!(offer.id).status == :confirmed
      assert Invoices.get_invoice!(invoice.id).offer_id == offer.id
    end

    test "once unlinked, confirming names the effects, returns to shortlisted, hides Invoices",
         %{conn: conn, scope: scope, category: category, offer: offer} do
      {:ok, invoice} =
        Invoices.create_invoice(
          scope,
          category,
          %{label: "Deposit", invoice_date: ~D[2027-01-15], offer_id: offer.id},
          %{label: "Deposit", amount: eur(100)}
        )

      {:ok, offer} = Invoices.set_invoicing_complete(scope, offer, true)
      {:ok, _} = Invoices.update_invoice(scope, invoice, %{"offer_id" => nil})

      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")
      assert has_element?(view, "#offer-invoices")

      view |> element("#offer-unconfirm") |> render_click()

      # Named fail-proof 4: hard-coding this wording (rather than rendering whatever
      # `Offers.unconfirm_effects/1` returns) would still show *some* text here, so the
      # assertion pins the exact sentence the context generates.
      assert has_element?(view, "#offer-unconfirm-confirm", "Invoicing complete will be cleared")

      view |> element("#offer-unconfirm-confirm-confirm") |> render_click()

      assert Offers.get_offer!(offer.id).status == :shortlisted
      refute Offers.get_offer!(offer.id).invoicing_complete
      refute has_element?(view, "#offer-invoices")
    end
  end

  # -- 3. Planning pick (CST-44, DR-66) -------------------------------------------------------

  describe "planning pick (CST-44, DR-66)" do
    test "shown while the category has no confirmed offer; Clear brings the button back; " <>
           "hidden once another offer of the category confirms (XC-01)",
         %{conn: conn, scope: scope, category: category} do
      venue_a = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})
      venue_b = offer_fixture(scope, category, %{"vendor_name" => "Venue B"})
      venue_c = offer_fixture(scope, category, %{"vendor_name" => "Venue C"})

      {:ok, view_a, _html} = live(conn, ~p"/offers/#{venue_a.id}")
      {:ok, view_c, _html} = live(conn, ~p"/offers/#{venue_c.id}")

      assert has_element?(view_a, "#offer-planning-pick")
      refute has_element?(view_a, "#offer-planning-pick-badge")

      view_a |> element("#offer-planning-pick") |> render_click()

      assert has_element?(view_a, "#offer-planning-pick-badge", "Planning pick")
      refute has_element?(view_a, "#offer-planning-pick")
      assert Offers.get_offer!(venue_a.id).planning_pick

      view_a |> element("#offer-planning-pick-clear") |> render_click()

      assert has_element?(view_a, "#offer-planning-pick")
      refute Offers.get_offer!(venue_a.id).planning_pick

      # Venue C is never the pick and never changes itself — this is purely the
      # cross-offer `:offer` branch (`refresh_planning_pick/1`), not the "own offer" one.
      assert has_element?(view_c, "#offer-planning-pick")
      {:ok, _} = Offers.confirm_offer(scope, venue_b)
      refute has_element?(view_c, "#offer-planning-pick")
      refute has_element?(view_c, "#offer-planning-pick-badge")
    end
  end

  # -- 4/5. Outside-confirmed-scope lines and the CST-43 case 4 delete warning ---------------

  describe "outside-confirmed-scope lines and Add to confirmed scope (CST-43 case 2, DR-64)" do
    test "a new optional line for a frozen-out service is greyed out; Add to confirmed scope makes it count",
         %{conn: conn, scope: scope, category: category} do
      sound =
        service_fixture(scope, category, %{"name" => "Sound", "wanted_priority" => "nice_to_have"})

      lighting =
        service_fixture(scope, category, %{
          "name" => "Lighting",
          "wanted_priority" => "not_wanted"
        })

      offer = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})

      {:ok, _sound_line} =
        Offers.create_line(scope, offer, %{
          "service_id" => sound.id,
          "state" => "optional",
          "basis" => "flat",
          "amount" => eur(300)
        })

      {:ok, confirmed} = Offers.confirm_offer(scope, offer)
      total_before = likely_total(confirmed.id)

      {:ok, view, _html} = live(conn, ~p"/offers/#{confirmed.id}")

      view |> element("#offer-add-line") |> render_click()

      # First reveal the basis/amount fields (rendered only for the form's *current*
      # state, see `line_editor/1`'s moduledoc), then submit with them present.
      view
      |> form("#add-line-form",
        line: %{"service_choice" => to_string(lighting.id), "state" => "optional"}
      )
      |> render_change()

      view
      |> form("#add-line-form",
        line: %{
          "service_choice" => to_string(lighting.id),
          "state" => "optional",
          "basis" => "flat",
          "amount_input" => "150"
        }
      )
      |> render_submit()

      new_line = Enum.find(Offers.list_lines(confirmed), &(&1.service_id == lighting.id))
      refute is_nil(new_line)

      # Named fail-proof: rendering an outside-scope line like a counted one would drop
      # this marker — see the fail-proof note below the test.
      assert has_element?(view, "#offer-line-#{new_line.id}-outside-scope")
      assert has_element?(view, "#offer-line-#{new_line.id}-add-to-scope")
      assert_money(likely_total(confirmed.id), total_before, "unchanged while outside scope")

      view |> element("#offer-line-#{new_line.id}-add-to-scope") |> render_click()

      refute has_element?(view, "#offer-line-#{new_line.id}-outside-scope")

      assert_money(
        Money.sub!(likely_total(confirmed.id), total_before),
        eur(150),
        "Lighting's line now counts"
      )
    end
  end

  describe "the :frozen_service live subscription (XC-01)" do
    test "a scope extension made elsewhere (the matrix) un-greys the line on this page",
         %{conn: conn, scope: scope, category: category} do
      lighting =
        service_fixture(scope, category, %{
          "name" => "Lighting",
          "wanted_priority" => "not_wanted"
        })

      offer = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})
      {:ok, confirmed} = Offers.confirm_offer(scope, offer)

      {:ok, line} =
        Offers.create_line(scope, confirmed, %{
          "service_id" => lighting.id,
          "state" => "optional",
          "basis" => "flat",
          "amount" => eur(150)
        })

      {:ok, view, _html} = live(conn, ~p"/offers/#{confirmed.id}")
      assert has_element?(view, "#offer-line-#{line.id}-outside-scope")

      # Another process (the matrix's "Add to confirmed scope") only broadcasts
      # `:frozen_service` — this page must follow it.
      {:ok, _row} = Offers.add_to_confirmed_scope(scope, confirmed, lighting)
      _ = render(view)

      refute has_element?(view, "#offer-line-#{line.id}-outside-scope")
    end
  end

  describe "CST-43 case 4: deleting the last line of a frozen-in service" do
    test "the delete confirmation warns; afterwards the Cost card shows the service's gap",
         %{conn: conn, scope: scope, category: category} do
      sound =
        service_fixture(scope, category, %{"name" => "Sound", "wanted_priority" => "nice_to_have"})

      offer = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})

      {:ok, line} =
        Offers.create_line(scope, offer, %{
          "service_id" => sound.id,
          "state" => "optional",
          "basis" => "flat",
          "amount" => eur(300)
        })

      {:ok, confirmed} = Offers.confirm_offer(scope, offer)

      {:ok, view, _html} = live(conn, ~p"/offers/#{confirmed.id}")

      view |> element("#offer-line-#{line.id}-delete") |> render_click()

      assert has_element?(
               view,
               "#offer-line-#{line.id}-delete-confirm",
               "'Sound' stays in the confirmed scope and will show as a gap (CST-43)"
             )

      view |> element("#offer-line-#{line.id}-delete-confirm-confirm") |> render_click()

      refute Enum.any?(Offers.list_lines(confirmed), &(&1.id == line.id))
      assert has_element?(view, "#offer-gap-#{sound.id}")
    end
  end

  # -- 6. XC-01 drift fix: the :override subscription (task 74) ------------------------------

  describe "the :override live subscription (XC-01 drift fix)" do
    test "toggling an override from another process refreshes this page's Cost total",
         %{conn: conn, scope: scope, category: category} do
      sound =
        service_fixture(scope, category, %{"name" => "Sound", "wanted_priority" => "not_wanted"})

      offer = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})

      {:ok, _line} =
        Offers.create_line(scope, offer, %{
          "service_id" => sound.id,
          "state" => "optional",
          "basis" => "flat",
          "amount" => eur(200)
        })

      before_total = likely_total(offer.id)

      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      assert has_element?(view, "#offer-cost-formula-total", Format.money(before_total))

      {:ok, _} = Offers.toggle_override(scope, offer, sound)
      after_total = likely_total(offer.id)

      assert_money(Money.sub!(after_total, before_total), eur(200), "override turned Sound on")
      assert has_element?(view, "#offer-cost-formula-total", Format.money(after_total))
    end
  end

  # -- 7. Task 70's B2 flow through the real confirm UI (BIL-05, BIL-07) --------------------

  describe "B2 through the real UI confirm path (task 70 reachability)" do
    setup %{scope: scope} do
      dinner = Rows.dinner!(scope)
      NormativeGuests.shared_dinner!(scope, dinner)
      {category, services} = Rows.category!(scope, NE.venue_category())
      %{offer: offer} = Rows.offer!(scope, :venue_a, category, services, dinner)

      %{category: category, offer: offer}
    end

    @tag :ui_example
    test "confirming via #offer-status makes Invoices reachable; the B2 variance and invoicing complete work end to end",
         %{conn: conn, scope: scope, category: category, offer: offer} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      refute has_element?(view, "#offer-invoices")

      view
      |> form("#offer-status-form", %{"status" => "confirmed"})
      |> render_change()

      assert Offers.get_offer!(offer.id).status == :confirmed
      assert has_element?(view, "#offer-invoices")
      assert has_element?(view, "#offer-cost-committed-label")

      {:ok, deposit} =
        Invoices.create_invoice(
          scope,
          category,
          %{label: "Deposit", invoice_date: ~D[2027-01-15], offer_id: offer.id},
          %{label: "Deposit", amount: eur(3000)}
        )

      {:ok, _deposit} = Invoices.mark_paid(scope, deposit, ~D[2027-01-31])

      {:ok, _final} =
        Invoices.create_invoice(
          scope,
          category,
          %{label: "Final invoice", invoice_date: ~D[2027-06-20], offer_id: offer.id},
          %{label: "Final invoice", amount: eur(8900)}
        )

      view |> element("#offer-invoicing-complete") |> render_click()

      assert has_element?(view, "#offer-variance", eur_text("174,00"))
      assert has_element?(view, "#offer-variance", "above committed")
      assert has_element?(view, "#offer-invoicing-complete", "Invoicing complete")
    end
  end
end
