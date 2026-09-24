defmodule WeddingPlannerWeb.Live.CategoryLiveMatrixTest do
  @moduledoc """
  The comparison matrix on `/categories/:id` (task 65; `DR-57`;
  `docs/modules/offers-and-comparison.md` `CST-50`…`CST-55`; `docs/04-cross-cutting.md`
  `XC-42`): offers as columns, services as rows banded by wanted priority, an "other
  charges" row, a totals row with a per-view preset selector and range, gap counts and
  the needs-attention marker in each column header, rejected offers hidden by default,
  all recomputed live.

  Task 66 adds this file's later `describe` blocks: the cell override toggle (`DR-56`),
  the header status select (`DR-40`), the "Other charges" ad hoc toggle (`CST-22`) and
  the cell's Edit/Add deep links (`DR-57`) — mounting those links themselves is
  `WeddingPlannerWeb.Live.OfferLiveLinesTest`'s job, kept there per this task's own
  boundaries.

  Real database rows throughout — `WeddingPlanner.NormativeOfferRows` (Venue A, Venue
  B) and `WeddingPlanner.NormativeGuests.shared_dinner!/2` (the shared Dinner guest
  list) — through `WeddingPlanner.Valuation.Snapshot.load/1`, the production path, same
  as `WeddingPlannerWeb.Live.OfferLiveCostTest`. The three default headcount presets
  (Minimum/Likely/Maximum, with their roles) come from the migration seed
  (`20260923193000_add_group_ids_and_role_to_headcount_presets.exs`) — every test DB
  already has them.

  `async: false`: mutates stored preset roles directly (the range test), the same
  reason `WeddingPlannerWeb.Live.OfferLiveCostTest` is `async: false`.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Events
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeGuests
  alias WeddingPlanner.NormativeOfferRows, as: Rows
  alias WeddingPlanner.OfferFixtures
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Presets.HeadcountPreset
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Gaps
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

  defp preset_named(name), do: Repo.get_by!(HeadcountPreset, name: name)

  defp attr_of(html, selector, name) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  # The production path over a fresh snapshot — never trust the UI's own gap count text.
  defp unknown_gap_count(offer_id) do
    snapshot = Snapshot.load(Repo)
    offer = Enum.find(snapshot.offers, &(&1.id == offer_id))
    snapshot |> Gaps.for_offer(offer) |> Enum.count(&(&1.severity == :unknown))
  end

  # The production path: a fresh snapshot, no `headcount:` test seam — exactly what
  # `WeddingPlanner.Valuation.Comparison.build/4` calls.
  defp total_money(offer_id, preset_name) do
    snapshot = Snapshot.load(Repo)
    offer = Enum.find(snapshot.offers, &(&1.id == offer_id))
    preset = Enum.find(snapshot.headcount_presets, &(&1.name == preset_name))
    %Formula{total: {:money, money}} = OfferEngine.total(snapshot, offer, preset)
    money
  end

  defp total_string(offer_id, preset_name) do
    offer_id |> total_money(preset_name) |> Format.money()
  end

  # -- columns, default preset, switching preset (CST-50, CST-53, HC-10) ------------------

  describe "columns and totals" do
    test "Venue A and Venue B render as columns; the default (Likely) total is € 11.726,00",
         %{conn: conn, category: category, venue_a: venue_a, venue_b: venue_b} do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      assert has_element?(view, "#matrix-col-#{venue_a.id}-vendor", "Venue A")
      assert has_element?(view, "#matrix-col-#{venue_b.id}-vendor", "Venue B")

      likely = preset_named("Likely")
      assert has_element?(view, "#matrix-preset-option-#{likely.id}[checked]")
      assert has_element?(view, "#matrix-total-#{venue_a.id}", "€ 11.726,00")
    end

    test "selecting the Minimum chip shows € 11.478,00 for Venue A", %{
      conn: conn,
      category: category,
      venue_a: venue_a
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")
      minimum = preset_named("Minimum")

      view
      |> element("#matrix-preset-form")
      |> render_change(%{"matrix-preset-preset" => to_string(minimum.id)})

      assert has_element?(view, "#matrix-preset-option-#{minimum.id}[checked]")
      assert has_element?(view, "#matrix-total-#{venue_a.id}", "€ 11.478,00")
    end
  end

  # -- O3: Venue B's missing must-have Catering (DR-52 — visual half only) ----------------

  describe "O3 — Venue B's missing must-have Catering" do
    @describetag example: "O3"

    test "Catering's cell shows the prominent must-have gap badge, the column's gap count " <>
           "includes a warning, and its total is still shown (partial, not like-for-like)",
         %{conn: conn, category: category, venue_b: venue_b, services: services} do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")
      catering = Map.fetch!(services, "Catering")

      assert has_element?(
               view,
               "#matrix-cell-#{catering.id}-#{venue_b.id}-gap",
               "Must-have gap"
             )

      assert has_element?(view, "#matrix-col-#{venue_b.id}-gaps", "1 warning")

      snapshot = Snapshot.load(Repo)
      offer = Enum.find(snapshot.offers, &(&1.id == venue_b.id))
      gap_count = length(Gaps.for_offer(snapshot, offer))
      assert gap_count >= 1

      assert has_element?(view, "#matrix-total-#{venue_b.id}-partial", "partial")
      assert has_element?(view, "#matrix-total-#{venue_b.id}-partial", ~r/partial — 2 gaps\b/)
      assert has_element?(view, "#matrix-total-#{venue_b.id}", total_string(venue_b.id, "Likely"))
    end
  end

  # -- CST-51: a priority change from the row header recomputes every column --------------

  describe "changing a service's wanted priority (CST-51)" do
    test "moving Sound to not wanted moves the row and recomputes every column", %{
      conn: conn,
      category: category,
      services: services,
      venue_a: venue_a
    } do
      sound = Map.fetch!(services, "Sound")
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      # Merge-into dropdowns list every other service regardless of band, so a service's
      # own row is asserted by its stream item id — never by band text, which every
      # other row's merge dropdown could also contain.
      assert has_element?(view, "#services_nice_to_have-#{sound.id}")

      view
      |> element("#service-#{sound.id}-priority-form")
      |> render_change(%{"wanted_priority" => "not_wanted"})

      refute has_element?(view, "#services_nice_to_have-#{sound.id}")
      assert has_element?(view, "#services_not_wanted-#{sound.id}")

      # Sound was `:included` (€0) for Venue A either way, so the total figure itself
      # does not move here — what this proves is that the row moved bands live and the
      # page did not crash recomputing every column with Sound now not wanted.
      assert has_element?(view, "#matrix-total-#{venue_a.id}", total_string(venue_a.id, "Likely"))
    end
  end

  # -- overrides (DR-49, DR-56) ------------------------------------------------------------

  describe "overrides" do
    test "a stored override shows the override marker live; toggling back removes it", %{
      conn: conn,
      scope: scope,
      category: category,
      services: services,
      venue_a: venue_a
    } do
      sound = Map.fetch!(services, "Sound")
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      marker_id = "#matrix-cell-#{sound.id}-#{venue_a.id}-override-marker"
      refute has_element?(view, marker_id)

      {:ok, _} = Offers.toggle_override(scope, venue_a, sound)
      _ = :sys.get_state(view.pid)
      assert has_element?(view, marker_id)

      {:ok, _} = Offers.toggle_override(scope, venue_a, sound)
      _ = :sys.get_state(view.pid)
      refute has_element?(view, marker_id)
    end
  end

  # -- rejected offers hidden by default (CST-55) -----------------------------------------

  describe "rejected offers" do
    test "a rejected offer's column hides, the toggle reveals it", %{
      conn: conn,
      scope: scope,
      category: category,
      venue_b: venue_b
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      {:ok, _} = Offers.update_offer(scope, venue_b, %{"status" => "rejected"})
      _ = :sys.get_state(view.pid)

      refute has_element?(view, "#matrix-col-#{venue_b.id}")
      assert has_element?(view, "#matrix-show-rejected", "Show rejected (1)")

      view |> element("#matrix-show-rejected") |> render_click()

      assert has_element?(view, "#matrix-col-#{venue_b.id}")
    end
  end

  # -- invalid line / needs attention (XC-41, XC-42) --------------------------------------

  describe "invalid line — needs attention" do
    test "deleting the Dinner event shows the needs-attention marker for Venue A", %{
      conn: conn,
      scope: scope,
      category: category,
      dinner: dinner,
      venue_a: venue_a
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      refute has_element?(view, "#matrix-col-#{venue_a.id}-attention")

      {:ok, _} = Events.delete_event(scope, dinner)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#matrix-col-#{venue_a.id}-attention", "Needs attention")
    end
  end

  # -- live recompute over the guest list (NFR-33, XC-01) ----------------------------------

  describe "live recompute on a guest change" do
    test "a new certain adult invited to Dinner changes Venue A's Likely total live", %{
      conn: conn,
      scope: scope,
      category: category,
      dinner: dinner,
      venue_a: venue_a
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      {:ok, person} =
        Guests.create_person(scope, %{
          first_name: "Extra",
          last_name: "Guest",
          certainty: :certain,
          age_category: :adult
        })

      {:ok, _invitation} = Invitations.set_invitation_status(scope, person, dinner, :invited)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#matrix-total-#{venue_a.id}", total_string(venue_a.id, "Likely"))
    end
  end

  # -- range (CST-53, DR-54) ---------------------------------------------------------------

  describe "range" do
    test "the range's low end is the Minimum preset's figure; unassigning :maximum shows the missing notice",
         %{conn: conn, category: category, venue_a: venue_a} do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      assert has_element?(
               view,
               "#matrix-total-#{venue_a.id}-range",
               total_string(venue_a.id, "Minimum")
             )

      refute has_element?(view, "#matrix-range-missing")

      # Revised DR-54 (task 62): the three default presets' roles are now fixed —
      # `Presets.update_preset/3` refuses moving a role holder's role at all. The
      # missing-range notice stays as a defensive path (a role could still end up
      # unassigned some other way than through the context), so it's exercised here by
      # clearing the column directly, bypassing the context, and re-mounting to pick it
      # up (nothing goes through `Presets`, so there is no `:headcount_preset`
      # broadcast to wait for).
      maximum = preset_named("Maximum")
      maximum |> Ecto.Changeset.change(role: nil) |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      assert has_element?(view, "#matrix-range-missing")
    end
  end

  # -- override toggle (task 66, CST-24, CST-52, DR-56) ------------------------------------

  describe "override toggle" do
    test "turning Late-night snack off for Venue A writes a row, shows the marker, drops " <>
           "the unknown gap count by one and logs it; toggling again removes both",
         %{conn: conn, category: category, services: services, venue_a: venue_a} do
      late_night = Map.fetch!(services, "Late-night snack")
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      toggle_id = "#matrix-toggle-#{late_night.id}-#{venue_a.id}"
      marker_id = "#matrix-cell-#{late_night.id}-#{venue_a.id}-override-marker"

      before_unknown = unknown_gap_count(venue_a.id)
      refute Enum.any?(Offers.list_overrides(venue_a), &(&1.service_id == late_night.id))
      refute has_element?(view, marker_id)
      assert has_element?(view, "#{toggle_id}[aria-pressed=\"true\"]")

      view |> element(toggle_id) |> render_click()

      assert has_element?(view, marker_id)
      assert has_element?(view, "#{toggle_id}[aria-pressed=\"false\"]")

      assert %{wanted: false} =
               Enum.find(Offers.list_overrides(venue_a), &(&1.service_id == late_night.id))

      assert unknown_gap_count(venue_a.id) == before_unknown - 1

      entries = Query.for_entity(:offer, venue_a.id)

      assert Enum.any?(
               entries,
               &(&1.description ==
                   "Wannes turned off 'Late-night snack' for offer 'Venue A' (override)")
             )

      view |> element(toggle_id) |> render_click()

      refute has_element?(view, marker_id)
      refute Enum.any?(Offers.list_overrides(venue_a), &(&1.service_id == late_night.id))
      assert unknown_gap_count(venue_a.id) == before_unknown
    end

    test "turning Garden ceremony (not wanted) on for Venue A adds €500 to its Likely total",
         %{conn: conn, category: category, services: services, venue_a: venue_a} do
      garden = Map.fetch!(services, "Garden ceremony")
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      before_total = total_string(venue_a.id, "Likely")
      assert has_element?(view, "#matrix-total-#{venue_a.id}", before_total)

      view |> element("#matrix-toggle-#{garden.id}-#{venue_a.id}") |> render_click()

      # Computed via `Offer.total/3` over a fresh snapshot (`total_string/2`), never the
      # literal alone — the literal is only asserted alongside it as the documented
      # expectation.
      after_total = total_string(venue_a.id, "Likely")
      assert after_total == "€ 12.226,00"
      assert has_element?(view, "#matrix-total-#{venue_a.id}", after_total)
    end
  end

  # -- header status select (task 66, DR-40) -----------------------------------------------

  describe "status select" do
    test "moving Venue B to rejected hides its column; the select never offers confirmed",
         %{conn: conn, category: category, venue_a: venue_a, venue_b: venue_b} do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      assert attr_of(
               render(view),
               "#matrix-status-#{venue_a.id} option[value=confirmed]",
               "value"
             ) ==
               []

      view
      |> element("#matrix-status-form-#{venue_b.id}")
      |> render_change(%{"status" => "rejected"})

      assert Offers.get_offer!(venue_b.id).status == :rejected
      refute has_element?(view, "#matrix-col-#{venue_b.id}")
      assert has_element?(view, "#matrix-show-rejected", "Show rejected (1)")

      view |> element("#matrix-show-rejected") |> render_click()

      assert has_element?(view, "#matrix-col-#{venue_b.id}")

      assert attr_of(render(view), "#matrix-status-#{venue_b.id} option[selected]", "value") == [
               "rejected"
             ]
    end
  end

  # -- ad hoc toggle (task 66, CST-22) -----------------------------------------------------

  describe "ad hoc toggle" do
    test "flips enabled and the column total changes by the line's own total", %{
      conn: conn,
      scope: scope,
      category: category,
      venue_a: venue_a
    } do
      {:ok, line} =
        Offers.create_line(scope, venue_a, %{
          "label" => "Late checkout",
          "state" => "optional",
          "basis" => "flat",
          "amount_input" => "60"
        })

      refute line.enabled
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      before_money = total_money(venue_a.id, "Likely")
      assert has_element?(view, "#matrix-total-#{venue_a.id}", Format.money(before_money))
      assert has_element?(view, "#matrix-adhoc-toggle-#{line.id}[aria-checked=\"false\"]")

      view |> element("#matrix-adhoc-toggle-#{line.id}") |> render_click()

      assert Offers.get_line!(line.id).enabled
      assert has_element?(view, "#matrix-adhoc-toggle-#{line.id}[aria-checked=\"true\"]")

      # `total_money/2` is `Offer.total/3` over a fresh snapshot (see the module's own
      # helper) — the €60 flat ad hoc line is now counted, so the two totals differ by
      # exactly its own amount.
      after_money = total_money(venue_a.id, "Likely")
      assert has_element?(view, "#matrix-total-#{venue_a.id}", Format.money(after_money))

      assert Money.equal?(
               WeddingPlanner.Money.subtract(after_money, before_money),
               WeddingPlanner.Money.new(60)
             )
    end
  end

  # -- cell edit/add deep links (task 66, DR-57) -------------------------------------------

  describe "cell edit/add links" do
    test "a cell with lines links Edit to each of them; an empty cell links Add", %{
      conn: conn,
      category: category,
      services: services,
      venue_a: venue_a,
      venue_b: venue_b
    } do
      catering = Map.fetch!(services, "Catering")
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      catering_lines = Enum.filter(Offers.list_lines(venue_a), &(&1.service_id == catering.id))
      assert catering_lines != []

      html = render(view)

      for line <- catering_lines do
        assert attr_of(html, "#matrix-edit-line-#{line.id}", "href") == [
                 "/offers/#{venue_a.id}?line=#{line.id}"
               ]
      end

      # Several lines in one cell: each link's text tells them apart (no "Edit Edit").
      if length(catering_lines) > 1 do
        labels =
          Enum.map(catering_lines, fn line ->
            view
            |> element("#matrix-edit-line-#{line.id}")
            |> render()
            |> LazyHTML.from_fragment()
            |> LazyHTML.text()
            |> String.trim()
          end)

        assert labels == Enum.uniq(labels)
      end

      assert attr_of(html, "#matrix-add-line-#{catering.id}-#{venue_b.id}", "href") == [
               "/offers/#{venue_b.id}?add_line=#{catering.id}"
             ]
    end
  end
end
