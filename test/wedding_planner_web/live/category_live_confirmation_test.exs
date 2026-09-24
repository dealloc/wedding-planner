defmodule WeddingPlannerWeb.Live.CategoryLiveConfirmationTest do
  @moduledoc """
  Confirmation, planning pick and confirmed-scope UI on the comparison matrix (task 75;
  `docs/modules/offers-and-comparison.md` `CST-40`…`CST-44`, `CST-06`; `w11-plan.md` §9
  `DR-62`, `DR-64`…`DR-67`): the header status select gaining *Confirmed*, the confirmed
  column's pill/"Un-confirm…"/"Committed" caption, cell scope locks and "Add to confirmed
  scope", planning pick, and the row-header frozen-service delete/merge refusals.

  Same real-database setup as `WeddingPlannerWeb.Live.CategoryLiveMatrixTest` (Venue A/B,
  `WeddingPlanner.NormativeOfferRows`, the shared Dinner guest list) — through
  `WeddingPlanner.Valuation.Snapshot.load/1`, the production path.

  `async: false` for the same reason as the sibling matrix test file (serial suite,
  `max_cases: 1`, kept consistent).
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Categories
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.InvoiceFixtures
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeGuests
  alias WeddingPlanner.NormativeOfferRows, as: Rows
  alias WeddingPlanner.OfferFixtures
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Offer, as: OfferEngine
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Format

  setup %{conn: conn} do
    scope = OfferFixtures.scope_fixture()
    dinner = Rows.dinner!(scope)
    guests = NormativeGuests.shared_dinner!(scope, dinner)
    {category, services} = Rows.category!(scope, NE.venue_category())

    %{offer: venue_a} = Rows.offer!(scope, :venue_a, category, services, dinner)
    %{offer: venue_b} = Rows.offer!(scope, {:venue_b, :no_line}, category, services, dinner)

    %{
      conn: log_in_user(conn, scope.user),
      scope: scope,
      dinner: dinner,
      guests: guests,
      category: category,
      services: services,
      venue_a: venue_a,
      venue_b: venue_b
    }
  end

  # -- helpers -------------------------------------------------------------------------------

  defp total_string(offer_id, preset_name) do
    snapshot = Snapshot.load(Repo)
    offer = Enum.find(snapshot.offers, &(&1.id == offer_id))
    preset = Enum.find(snapshot.headcount_presets, &(&1.name == preset_name))

    %WeddingPlanner.Valuation.Formula{total: {:money, money}} =
      OfferEngine.total(snapshot, offer, preset)

    Format.money(money)
  end

  # -- confirming from the header select (DR-62) -------------------------------------------

  describe "confirming from the header select" do
    test "picking Confirmed replaces the select with the pill, shows Un-confirm, drops the " <>
           "override toggle and shows scope locks for every frozen-in service",
         %{conn: conn, category: category, services: services, venue_a: venue_a} do
      sound = Map.fetch!(services, "Sound")
      seating = Map.fetch!(services, "Seating")
      garden = Map.fetch!(services, "Garden ceremony")

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      refute has_element?(view, "#matrix-col-#{venue_a.id}-unconfirm")

      view
      |> element("#matrix-status-form-#{venue_a.id}")
      |> render_change(%{"status" => "confirmed"})

      assert Offers.get_offer!(venue_a.id).status == :confirmed
      assert has_element?(view, "#matrix-col-#{venue_a.id}-status", "Confirmed")
      refute has_element?(view, "#matrix-status-form-#{venue_a.id}")
      assert has_element?(view, "#matrix-col-#{venue_a.id}-unconfirm")

      # DR-64: no override toggle anywhere in this column — fail-proof 1 (rendering it
      # unconditionally for a confirmed column would keep this passing wrongly, so this
      # is asserted against several rows, not just one).
      refute has_element?(view, "#matrix-toggle-#{sound.id}-#{venue_a.id}")
      refute has_element?(view, "#matrix-toggle-#{seating.id}-#{venue_a.id}")
      refute has_element?(view, "#matrix-toggle-#{garden.id}-#{venue_a.id}")

      # Seating and Sound are nice-to-have with no override, so both are frozen in.
      assert has_element?(view, "#matrix-cell-#{sound.id}-#{venue_a.id}-scope")
      assert has_element?(view, "#matrix-cell-#{seating.id}-#{venue_a.id}-scope")

      # Garden ceremony is not_wanted, so it is frozen out — no lock, no toggle.
      refute has_element?(view, "#matrix-cell-#{garden.id}-#{venue_a.id}-scope")
    end
  end

  # -- CST-40 visual: a priority change elsewhere never moves the committed total ---------

  describe "CST-40 — priority change doesn't move the confirmed total" do
    test "changing Garden ceremony's priority leaves Venue A's total unchanged and moves Venue B's",
         %{
           conn: conn,
           scope: scope,
           category: category,
           services: services,
           venue_a: venue_a,
           venue_b: venue_b
         } do
      garden = Map.fetch!(services, "Garden ceremony")
      {:ok, _confirmed} = Offers.confirm_offer(scope, venue_a)

      venue_a_before = total_string(venue_a.id, "Likely")
      venue_b_before = total_string(venue_b.id, "Likely")

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      view
      |> element("#service-#{garden.id}-priority-form")
      |> render_change(%{"wanted_priority" => "nice_to_have"})

      assert Categories.get_service!(garden.id).wanted_priority == :nice_to_have

      venue_a_after = total_string(venue_a.id, "Likely")
      venue_b_after = total_string(venue_b.id, "Likely")

      assert venue_a_after == venue_a_before
      assert has_element?(view, "#matrix-total-#{venue_a.id}", venue_a_before)

      assert venue_b_after != venue_b_before
      assert has_element?(view, "#matrix-total-#{venue_b.id}", venue_b_after)
    end
  end

  # -- CST-41 visual: the guest list still moves the committed total ----------------------

  describe "CST-41 — the guest list still moves the confirmed total" do
    test "a new certain adult invited to Dinner changes Venue A's committed total live", %{
      conn: conn,
      scope: scope,
      category: category,
      dinner: dinner,
      venue_a: venue_a
    } do
      {:ok, _confirmed} = Offers.confirm_offer(scope, venue_a)
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      before_total = total_string(venue_a.id, "Likely")
      assert has_element?(view, "#matrix-total-#{venue_a.id}", before_total)

      {:ok, person} =
        Guests.create_person(scope, %{
          first_name: "Extra",
          last_name: "Guest",
          certainty: :certain,
          age_category: :adult
        })

      {:ok, _invitation} = Invitations.set_invitation_status(scope, person, dinner, :invited)
      _ = :sys.get_state(view.pid)

      after_total = total_string(venue_a.id, "Likely")
      assert after_total != before_total
      assert has_element?(view, "#matrix-total-#{venue_a.id}", after_total)
    end
  end

  # -- outside-scope line: add-to-confirmed-scope (CST-43, DR-64) -------------------------

  describe "outside-scope line" do
    test "an optional line for a frozen-out service greys out with Add to confirmed scope; " <>
           "clicking it counts the line and grows the total",
         %{
           conn: conn,
           scope: scope,
           category: category,
           services: services,
           venue_a: venue_a
         } do
      garden = Map.fetch!(services, "Garden ceremony")
      {:ok, _confirmed} = Offers.confirm_offer(scope, venue_a)

      {:ok, line} =
        Offers.create_line(scope, venue_a, %{
          "service_id" => garden.id,
          "state" => "optional",
          "basis" => "flat",
          "amount_input" => "75"
        })

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      before_total = total_string(venue_a.id, "Likely")
      assert has_element?(view, "#matrix-add-to-scope-#{line.id}", "Add to confirmed scope")
      refute has_element?(view, "#matrix-cell-#{garden.id}-#{venue_a.id}-scope")

      view |> element("#matrix-add-to-scope-#{line.id}") |> render_click()

      assert Offers.list_frozen_services(Offers.get_offer!(venue_a.id))
             |> Enum.any?(&(&1.service_id == garden.id))

      refute has_element?(view, "#matrix-add-to-scope-#{line.id}")
      assert has_element?(view, "#matrix-cell-#{garden.id}-#{venue_a.id}-scope")

      after_total = total_string(venue_a.id, "Likely")
      assert after_total != before_total
      assert has_element?(view, "#matrix-total-#{venue_a.id}", after_total)
    end

    # Fail-proof 2 (dropping the `:frozen_service` subscription): the update here comes
    # from a call in the test process, standing in for "another tab" — never a click in
    # this view — so it can only reach this view through the broadcast/subscription.
    test "adding to scope from another process updates the matrix live", %{
      conn: conn,
      scope: scope,
      category: category,
      services: services,
      venue_a: venue_a
    } do
      garden = Map.fetch!(services, "Garden ceremony")
      {:ok, _confirmed} = Offers.confirm_offer(scope, venue_a)
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      refute has_element?(view, "#matrix-cell-#{garden.id}-#{venue_a.id}-scope")

      {:ok, _row} = Offers.add_to_confirmed_scope(scope, venue_a, garden)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#matrix-cell-#{garden.id}-#{venue_a.id}-scope")
    end
  end

  # -- un-confirm dialog, effects, resuming overrides (CST-42, DR-62, DR-64) --------------

  describe "un-confirm" do
    test "the dialog lists unconfirm_effects/1; confirming returns to shortlisted and " <>
           "resumes the dormant override",
         %{
           conn: conn,
           scope: scope,
           category: category,
           services: services,
           venue_a: venue_a
         } do
      sound = Map.fetch!(services, "Sound")
      {:ok, _off} = Offers.toggle_override(scope, venue_a, sound)

      marker_id = "#matrix-cell-#{sound.id}-#{venue_a.id}-override-marker"
      toggle_id = "#matrix-toggle-#{sound.id}-#{venue_a.id}"

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")
      assert has_element?(view, marker_id)
      assert has_element?(view, "#{toggle_id}[aria-pressed=\"false\"]")

      view
      |> element("#matrix-status-form-#{venue_a.id}")
      |> render_change(%{"status" => "confirmed"})

      refute has_element?(view, marker_id)
      refute has_element?(view, toggle_id)

      effects = Offers.unconfirm_effects(Offers.get_offer!(venue_a.id))
      assert effects != []

      view
      |> element("#matrix-col-#{venue_a.id}-unconfirm")
      |> render_click()

      assert has_element?(view, "#matrix-unconfirm-dialog")
      refute has_element?(view, "#matrix-unconfirm-blocked")

      for effect <- effects do
        assert has_element?(view, "#matrix-unconfirm-dialog-affected", effect.label)
      end

      view |> element("#matrix-unconfirm-dialog-confirm") |> render_click()

      assert Offers.get_offer!(venue_a.id).status == :shortlisted
      refute has_element?(view, "#matrix-unconfirm-dialog")
      assert has_element?(view, "#matrix-status-form-#{venue_a.id}")

      assert has_element?(view, marker_id)
      assert has_element?(view, "#{toggle_id}[aria-pressed=\"false\"]")
    end

    # ORCHESTRATOR AMENDMENT — DR-65 final: refused with a blocked panel while an
    # invoice still links to the offer, never the destructive_confirm dialog.
    test "un-confirming is refused with a blocked panel while an invoice is linked", %{
      conn: conn,
      scope: scope,
      category: category,
      venue_a: venue_a
    } do
      {:ok, _confirmed} = Offers.confirm_offer(scope, venue_a)
      invoice = InvoiceFixtures.invoice_fixture(scope, category, %{"offer_id" => venue_a.id})

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      view
      |> element("#matrix-col-#{venue_a.id}-unconfirm")
      |> render_click()

      refute has_element?(view, "#matrix-unconfirm-dialog")
      assert has_element?(view, "#matrix-unconfirm-blocked", invoice.label)
      refute has_element?(view, "#matrix-unconfirm-dialog-confirm")

      view |> element("#matrix-unconfirm-blocked-cancel") |> render_click()

      refute has_element?(view, "#matrix-unconfirm-blocked")
      assert Offers.get_offer!(venue_a.id).status == :confirmed
    end
  end

  # -- planning pick (CST-44, DR-66) -------------------------------------------------------

  describe "planning pick" do
    test "a button on each non-rejected column, a badge that moves, Clear, hidden once " <>
           "any offer in the category is confirmed",
         %{
           conn: conn,
           scope: scope,
           category: category,
           venue_a: venue_a,
           venue_b: venue_b
         } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      assert has_element?(view, "#matrix-col-#{venue_a.id}-planning-pick")
      assert has_element?(view, "#matrix-col-#{venue_b.id}-planning-pick")

      view
      |> element("#matrix-col-#{venue_a.id}-planning-pick")
      |> render_click()

      assert Offers.get_offer!(venue_a.id).planning_pick
      assert has_element?(view, "#matrix-col-#{venue_a.id}-planning-pick-badge", "Planning pick")
      refute has_element?(view, "#matrix-col-#{venue_a.id}-planning-pick")

      view
      |> element("#matrix-col-#{venue_b.id}-planning-pick")
      |> render_click()

      refute Offers.get_offer!(venue_a.id).planning_pick
      assert Offers.get_offer!(venue_b.id).planning_pick
      refute has_element?(view, "#matrix-col-#{venue_a.id}-planning-pick-badge")
      assert has_element?(view, "#matrix-col-#{venue_a.id}-planning-pick")
      assert has_element?(view, "#matrix-col-#{venue_b.id}-planning-pick-badge")

      view
      |> element("#matrix-col-#{venue_b.id}-planning-pick-clear")
      |> render_click()

      refute Offers.get_offer!(venue_b.id).planning_pick
      refute has_element?(view, "#matrix-col-#{venue_b.id}-planning-pick-badge")
      assert has_element?(view, "#matrix-col-#{venue_b.id}-planning-pick")

      # Fail-proof 4: showing the planning-pick control once the category has a
      # confirmed offer would keep this passing wrongly.
      {:ok, _confirmed} = Offers.confirm_offer(scope, venue_a)
      _ = :sys.get_state(view.pid)

      refute has_element?(view, "#matrix-col-#{venue_a.id}-planning-pick")
      refute has_element?(view, "#matrix-col-#{venue_a.id}-planning-pick-badge")
      refute has_element?(view, "#matrix-col-#{venue_b.id}-planning-pick")
      refute has_element?(view, "#matrix-col-#{venue_b.id}-planning-pick-badge")
    end
  end

  # -- frozen-service delete/merge refusals (CST-06, CST-04, DR-67) -----------------------

  describe "frozen-service delete refusal" do
    # Fail-proof 3: deleting a frozen-in service without this check would either delete
    # it (breaking the FK backing CST-06) or crash instead of showing this panel.
    test "a frozen-in service with no lines shows the blocked panel, not the normal delete",
         %{conn: conn, scope: scope, category: category, venue_a: venue_a} do
      {:ok, valet} =
        Categories.create_service(scope, category, %{
          "name" => "Valet parking",
          "wanted_priority" => "not_wanted"
        })

      {:ok, _confirmed} = Offers.confirm_offer(scope, venue_a)
      {:ok, _row} = Offers.add_to_confirmed_scope(scope, venue_a, valet)

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      view
      |> element("#service-#{valet.id}-delete")
      |> render_click()

      assert has_element?(view, "#service-#{valet.id}-delete-frozen", "Venue A")
      refute has_element?(view, "#service-#{valet.id}-delete-confirm")

      view
      |> element("#service-#{valet.id}-delete-frozen-cancel")
      |> render_click()

      refute has_element?(view, "#service-#{valet.id}-delete-frozen")
      assert Categories.get_service!(valet.id)
    end
  end

  describe "frozen-scope merge refusal" do
    test "merging a frozen-in service into a frozen-out one is refused with a flash naming " <>
           "the offer",
         %{conn: conn, scope: scope, category: category, services: services, venue_a: venue_a} do
      sound = Map.fetch!(services, "Sound")
      garden = Map.fetch!(services, "Garden ceremony")
      {:ok, _confirmed} = Offers.confirm_offer(scope, venue_a)

      assert Offers.list_frozen_services(venue_a) |> Enum.any?(&(&1.service_id == sound.id))
      refute Offers.list_frozen_services(venue_a) |> Enum.any?(&(&1.service_id == garden.id))

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      view
      |> element("#service-#{sound.id}-merge-form")
      |> render_submit(%{"survivor_id" => to_string(garden.id)})

      view
      |> element("#service-#{sound.id}-merge-confirm-confirm")
      |> render_click()

      assert has_element?(view, "#flash-error", "Venue A")
      assert Categories.get_service!(sound.id)
    end
  end

  # -- totals row: "Committed" caption (task 75) -------------------------------------------

  describe "Committed caption" do
    test "only a confirmed column's total gets the Committed caption", %{
      conn: conn,
      scope: scope,
      category: category,
      venue_a: venue_a,
      venue_b: venue_b
    } do
      {:ok, _confirmed} = Offers.confirm_offer(scope, venue_a)
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      assert has_element?(view, "#matrix-total-#{venue_a.id}-committed", "Committed")
      refute has_element?(view, "#matrix-total-#{venue_b.id}-committed")
    end
  end
end
