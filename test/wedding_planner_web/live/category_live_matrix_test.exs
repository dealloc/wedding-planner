defmodule WeddingPlannerWeb.Live.CategoryLiveMatrixTest do
  @moduledoc """
  The comparison matrix on `/categories/:id` (task 65; `DR-57`;
  `docs/modules/offers-and-comparison.md` `CST-50`…`CST-55`; `docs/04-cross-cutting.md`
  `XC-42`): offers as columns, services as rows banded by wanted priority, an "other
  charges" row, a totals row with a per-view preset selector and range, gap counts and
  the needs-attention marker in each column header, rejected offers hidden by default,
  all recomputed live.

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

  # The production path: a fresh snapshot, no `headcount:` test seam — exactly what
  # `WeddingPlanner.Valuation.Comparison.build/4` calls.
  defp total_string(offer_id, preset_name) do
    snapshot = Snapshot.load(Repo)
    offer = Enum.find(snapshot.offers, &(&1.id == offer_id))
    preset = Enum.find(snapshot.headcount_presets, &(&1.name == preset_name))
    %Formula{total: {:money, money}} = OfferEngine.total(snapshot, offer, preset)
    Format.money(money)
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
end
