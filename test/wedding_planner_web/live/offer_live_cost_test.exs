defmodule WeddingPlannerWeb.Live.OfferLiveCostTest do
  @moduledoc """
  The Cost card on `/offers/:id` (task 57/60): `docs/modules/offers-and-comparison.md`
  `CST-25`, `CST-34`, `CST-36`, `CST-53`; `docs/modules/headcount.md` `HC-06`, `HC-08`,
  `HC-10`; `docs/05-non-functional.md` `NFR-14`, `NFR-32`, `NFR-33`;
  `docs/06-decisions.md` `D-31`; `DR-54`.

  Real database rows throughout (`WeddingPlanner.NormativeGuests`,
  `WeddingPlanner.NormativeOfferRows`) → `WeddingPlanner.Valuation.Snapshot.load/1` →
  the production path of `WeddingPlanner.Valuation.Offer.total/3` (no `headcount:` seam)
  — the same real-data join `WeddingPlanner.NormativeGuestsTest` (task 34) proves at the
  engine level, exercised here through the LiveView.

  `async: false`: writes real rows via the contexts and deletes/renames stored preset
  rows directly, the same reasons `WeddingPlannerWeb.Live.OfferLiveTest` is `async: false`.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias WeddingPlanner.NormativeExamples
  alias WeddingPlanner.NormativeGuests
  alias WeddingPlanner.NormativeOfferRows, as: Rows
  alias WeddingPlanner.OfferFixtures
  alias WeddingPlanner.Presets
  alias WeddingPlanner.Presets.HeadcountPreset
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Offer
  alias WeddingPlannerWeb.Format

  setup %{conn: conn} do
    scope = OfferFixtures.scope_fixture()
    dinner = Rows.dinner!(scope)

    %{conn: log_in_user(conn, scope.user), scope: scope, dinner: dinner}
  end

  # -- helpers -------------------------------------------------------------------------------

  defp nbsp, do: <<0xA0::utf8>>
  defp eur(str), do: "€#{nbsp()}#{str}"

  defp preset_named(name), do: Repo.get_by!(HeadcountPreset, name: name)
  defp loaded_offer(snapshot, offer_id), do: Enum.find(snapshot.offers, &(&1.id == offer_id))

  # The production path: a fresh snapshot, no `headcount:` test seam — exactly what
  # `WeddingPlannerWeb.OfferCost.build/3` calls.
  defp total_string(offer_id, preset_name) do
    snapshot = WeddingPlanner.Valuation.Snapshot.load(Repo)
    offer = loaded_offer(snapshot, offer_id)
    preset = Enum.find(snapshot.headcount_presets, &(&1.name == preset_name))
    %Formula{total: {:money, money}} = Offer.total(snapshot, offer, preset)
    Format.money(money)
  end

  # -- Venue A on the shared Dinner guests (O1, O2, O4, O5) -------------------------------

  describe "Venue A on the shared Dinner guests" do
    setup %{scope: scope, dinner: dinner} do
      NormativeGuests.shared_dinner!(scope, dinner)
      {venue, services} = Rows.category!(scope, NormativeExamples.venue_category())
      %{offer: offer} = Rows.offer!(scope, :venue_a, venue, services, dinner)
      %{offer: offer, services: services}
    end

    test "defaults to Likely: € 11.726,00, expands into its formula", %{conn: conn, offer: offer} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      assert has_element?(view, "#offer-cost-formula-total", eur("11.726,00"))
      assert has_element?(view, "#offer-cost-formula-step-0", "Likely")

      likely = preset_named("Likely")
      assert has_element?(view, "#offer-cost-preset-option-#{likely.id}[checked]")
    end

    test "switching to Minimum via the preset form (selected by id) shows € 11.478,00", %{
      conn: conn,
      offer: offer
    } do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")
      minimum = preset_named("Minimum")

      view
      |> element("#offer-cost-preset-form")
      |> render_change(%{"offer-cost-preset-preset" => to_string(minimum.id)})

      assert has_element?(view, "#offer-cost-formula-total", eur("11.478,00"))
      assert has_element?(view, "#offer-cost-preset-option-#{minimum.id}[checked]")
    end

    test "the range shows Minimum..Maximum, Maximum matching Offer.total/3 under the stored Maximum preset",
         %{conn: conn, offer: offer} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      maximum = total_string(offer.id, "Maximum")

      assert has_element?(view, "#offer-cost-range-minimum", eur("11.478,00"))
      assert has_element?(view, "#offer-cost-range-maximum", maximum)
    end

    test "the Late-night snack gap renders as unknown ('ask the vendor')", %{
      conn: conn,
      offer: offer,
      services: services
    } do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")
      snack = Map.fetch!(services, "Late-night snack")

      assert has_element?(view, "#offer-gap-#{snack.id}", "ask the vendor")
    end
  end

  describe "Caterer C on the shared Dinner guests" do
    setup %{scope: scope, dinner: dinner} do
      NormativeGuests.shared_dinner!(scope, dinner)
      {catering, services} = Rows.category!(scope, NormativeExamples.catering_category())
      %{offer: offer} = Rows.offer!(scope, :caterer_c, catering, services, dinner)
      %{offer: offer}
    end

    test "defaults to Likely: € 7.641,50", %{conn: conn, offer: offer} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      assert has_element?(view, "#offer-cost-formula-total", eur("7.641,50"))
    end

    test "switching to Minimum shows € 7.000,00", %{conn: conn, offer: offer} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")
      minimum = preset_named("Minimum")

      view
      |> element("#offer-cost-preset-form")
      |> render_change(%{"offer-cost-preset-preset" => to_string(minimum.id)})

      assert has_element?(view, "#offer-cost-formula-total", eur("7.000,00"))
    end
  end

  # -- live recompute (NFR-33) -----------------------------------------------------------------

  describe "live recompute on invitation/guest changes" do
    setup %{scope: scope, dinner: dinner} do
      NormativeGuests.shared_dinner!(scope, dinner)
      {venue, services} = Rows.category!(scope, NormativeExamples.venue_category())
      %{offer: offer} = Rows.offer!(scope, :venue_a, venue, services, dinner)
      %{offer: offer}
    end

    test "inviting a new certain adult from another process updates the Likely total", %{
      conn: conn,
      scope: scope,
      dinner: dinner,
      offer: offer
    } do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")
      assert has_element?(view, "#offer-cost-formula-total", eur("11.726,00"))

      {:ok, person} =
        WeddingPlanner.Guests.create_person(scope, %{
          first_name: "New",
          last_name: "Certain",
          certainty: :certain,
          age_category: :adult
        })

      {:ok, _invitation} =
        WeddingPlanner.Invitations.set_invitation_status(scope, person, dinner, :invited)

      recomputed = total_string(offer.id, "Likely")
      assert recomputed != eur("11.726,00")
      assert has_element?(view, "#offer-cost-formula-total", recomputed)
    end

    test "the selected preset (Minimum) is kept across a live recompute", %{
      conn: conn,
      scope: scope,
      dinner: dinner,
      offer: offer
    } do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")
      minimum = preset_named("Minimum")

      view
      |> element("#offer-cost-preset-form")
      |> render_change(%{"offer-cost-preset-preset" => to_string(minimum.id)})

      assert has_element?(view, "#offer-cost-formula-total", eur("11.478,00"))

      {:ok, person} =
        WeddingPlanner.Guests.create_person(scope, %{
          first_name: "New",
          last_name: "Certain",
          certainty: :certain,
          age_category: :adult
        })

      {:ok, _invitation} =
        WeddingPlanner.Invitations.set_invitation_status(scope, person, dinner, :invited)

      recomputed = total_string(offer.id, "Minimum")
      assert recomputed != eur("11.478,00")
      assert has_element?(view, "#offer-cost-formula-total", recomputed)
      assert has_element?(view, "#offer-cost-preset-option-#{minimum.id}[checked]")
    end
  end

  # -- gaps change live -----------------------------------------------------------------------

  describe "gap changes" do
    test "switching Late-night snack to not wanted removes its gap", %{
      conn: conn,
      scope: scope,
      dinner: dinner
    } do
      NormativeGuests.shared_dinner!(scope, dinner)
      {venue, services} = Rows.category!(scope, NormativeExamples.venue_category())
      %{offer: offer} = Rows.offer!(scope, :venue_a, venue, services, dinner)
      snack = Map.fetch!(services, "Late-night snack")

      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")
      assert has_element?(view, "#offer-gap-#{snack.id}")

      {:ok, _updated} =
        WeddingPlanner.Categories.update_service(scope, snack, %{
          "wanted_priority" => "not_wanted"
        })

      refute has_element?(view, "#offer-gap-#{snack.id}")
    end

    test "a Venue B without a catering line shows the prominent Catering gap", %{
      conn: conn,
      scope: scope,
      dinner: dinner
    } do
      NormativeGuests.shared_dinner!(scope, dinner)
      {venue, services} = Rows.category!(scope, NormativeExamples.venue_category())
      %{offer: venue_b} = Rows.offer!(scope, {:venue_b, :no_line}, venue, services, dinner)
      catering = Map.fetch!(services, "Catering")

      {:ok, view, _html} = live(conn, ~p"/offers/#{venue_b.id}")

      assert has_element?(view, "#offer-gap-#{catering.id}[data-severity=must_have]")
    end
  end

  # -- preset identity, HC-06/HC-08/HC-10/DR-54 --------------------------------------------

  describe "preset identity follows role, not name (DR-54 revised)" do
    # `DR-54` was revised by a binding orchestrator ruling (2026-09-24, task 62): the
    # three seeded defaults (the role holders) are now locked — no rename, no role
    # change, no delete, ever, through `WeddingPlanner.Presets`. The tests below that
    # used to exercise those operations on a default now either (a) assert the
    # operation is refused and the offer page is unaffected, or (b) reach the same
    # degenerate state directly at the database level (bypassing the now-locked
    # context) to keep proving these display paths stay defensive rather than crash —
    # `WeddingPlanner.Valuation.PresetChoice` itself is untouched by the revision.
    setup %{scope: scope, dinner: dinner} do
      NormativeGuests.shared_dinner!(scope, dinner)
      {venue, services} = Rows.category!(scope, NormativeExamples.venue_category())
      %{offer: offer} = Rows.offer!(scope, :venue_a, venue, services, dinner)
      %{offer: offer}
    end

    test "'Likely' can no longer be renamed (DR-54 revised) — the offer page keeps showing it",
         %{conn: conn, scope: scope, offer: offer} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")
      assert has_element?(view, "#offer-cost-formula-total", eur("11.726,00"))

      likely = preset_named("Likely")

      assert Presets.update_preset(scope, likely, %{"name" => "Expected"}) ==
               {:error, :default_preset_locked}

      assert has_element?(view, "#offer-cost-formula-total", eur("11.726,00"))
      assert has_element?(view, "#offer-cost-formula", "Total (Likely)")
      assert has_element?(view, "#offer-cost-preset-option-#{likely.id}[checked]")
      assert has_element?(view, "#offer-cost-preset", "Likely")
    end

    test "a custom preset created via Presets.create_preset/2 appears as a chip", %{
      conn: conn,
      scope: scope,
      offer: offer
    } do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      {:ok, custom} = Presets.create_preset(scope, %{"name" => "Custom"})

      assert has_element?(view, "#offer-cost-preset-option-#{custom.id}")
      assert has_element?(view, "#offer-cost-preset", "Custom")
    end

    test "deleting the selected (custom) preset live falls back to the default", %{
      conn: conn,
      scope: scope,
      offer: offer
    } do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")
      {:ok, custom} = Presets.create_preset(scope, %{"name" => "Custom"})

      view
      |> element("#offer-cost-preset-form")
      |> render_change(%{"offer-cost-preset-preset" => to_string(custom.id)})

      assert has_element?(view, "#offer-cost-preset-option-#{custom.id}[checked]")

      {:ok, _} = Presets.delete_preset(scope, custom)

      likely = preset_named("Likely")
      assert has_element?(view, "#offer-cost-formula-total", eur("11.726,00"))
      assert has_element?(view, "#offer-cost-preset-option-#{likely.id}[checked]")
    end

    test "a role unset directly in the DB (defensive only) still shows the missing-range notice",
         %{conn: conn, offer: offer} do
      maximum = preset_named("Maximum")
      {:ok, _} = maximum |> Ecto.Changeset.change(role: nil) |> Repo.update()

      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      assert has_element?(view, "#offer-cost-missing-range")
      assert has_element?(view, "#offer-cost-formula-total", eur("11.726,00"))
      refute has_element?(view, "#offer-cost-range")
    end

    test "every preset removed directly in the DB (defensive only) shows the missing-preset notice, no crash",
         %{conn: conn, offer: offer} do
      Repo.delete_all(HeadcountPreset)

      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      assert has_element?(view, "#offer-cost-missing-preset")
      refute has_element?(view, "#offer-cost-range")
      refute has_element?(view, "#offer-cost-formula")
    end
  end
end
