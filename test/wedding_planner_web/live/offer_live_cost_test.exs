defmodule WeddingPlannerWeb.Live.OfferLiveCostTest do
  @moduledoc """
  The Cost card on `/offers/:id` (task 57, DR-51): `docs/modules/offers-and-comparison.md`
  `CST-25`, `CST-34`, `CST-36`, `CST-53`; `docs/modules/headcount.md` `HC-08`, `HC-10`;
  `docs/05-non-functional.md` `NFR-14`, `NFR-32`, `NFR-33`; `docs/06-decisions.md` `D-31`.

  Real database rows throughout (`WeddingPlanner.NormativeGuests`,
  `WeddingPlanner.NormativeOfferRows`) → `WeddingPlanner.Valuation.Snapshot.load/1` →
  the production path of `WeddingPlanner.Valuation.Offer.total/3` (no `headcount:` seam)
  — the same real-data join `WeddingPlanner.NormativeGuestsTest` (task 34) proves at the
  engine level, exercised here through the LiveView.

  `async: false`: writes real rows via the contexts and deletes a stored preset row
  directly, the same reasons `WeddingPlannerWeb.Live.OfferLiveTest` is `async: false`.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Categories
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.NormativeExamples
  alias WeddingPlanner.NormativeGuests
  alias WeddingPlanner.NormativeOfferRows, as: Rows
  alias WeddingPlanner.OfferFixtures
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

  defp nbsp, do: " "
  defp eur(str), do: "€#{nbsp()}#{str}"

  defp preset(snapshot, name), do: Enum.find(snapshot.headcount_presets, &(&1.name == name))
  defp loaded_offer(snapshot, offer_id), do: Enum.find(snapshot.offers, &(&1.id == offer_id))

  # The production path: a fresh snapshot, no `headcount:` test seam — exactly what
  # `WeddingPlannerWeb.OfferCost.build/3` calls.
  defp total_string(offer_id, preset_name) do
    snapshot = WeddingPlanner.Valuation.Snapshot.load(Repo)
    offer = loaded_offer(snapshot, offer_id)
    %Formula{total: {:money, money}} = Offer.total(snapshot, offer, preset(snapshot, preset_name))
    Format.money(money)
  end

  # -- Venue A / Caterer C figures (O1, O2, O4, O5) -------------------------------------------

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
    end

    test "switching to Minimum via the preset form shows € 11.478,00", %{
      conn: conn,
      offer: offer
    } do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      view
      |> element("#offer-cost-preset-form")
      |> render_change(%{"offer-cost-preset-preset" => "Minimum"})

      assert has_element?(view, "#offer-cost-formula-total", eur("11.478,00"))
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

      view
      |> element("#offer-cost-preset-form")
      |> render_change(%{"offer-cost-preset-preset" => "Minimum"})

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
        Guests.create_person(scope, %{
          first_name: "New",
          last_name: "Certain",
          certainty: :certain,
          age_category: :adult
        })

      {:ok, _invitation} = Invitations.set_invitation_status(scope, person, dinner, :invited)

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

      view
      |> element("#offer-cost-preset-form")
      |> render_change(%{"offer-cost-preset-preset" => "Minimum"})

      assert has_element?(view, "#offer-cost-formula-total", eur("11.478,00"))

      {:ok, person} =
        Guests.create_person(scope, %{
          first_name: "New",
          last_name: "Certain",
          certainty: :certain,
          age_category: :adult
        })

      {:ok, _invitation} = Invitations.set_invitation_status(scope, person, dinner, :invited)

      recomputed = total_string(offer.id, "Minimum")
      assert recomputed != eur("11.478,00")
      assert has_element?(view, "#offer-cost-formula-total", recomputed)
      assert has_element?(view, "#offer-cost-preset-option-Minimum[checked]")
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
        Categories.update_service(scope, snack, %{"wanted_priority" => "not_wanted"})

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

  # -- missing stored preset -------------------------------------------------------------------

  describe "a missing stored preset" do
    test "shows the missing-preset notice instead of a figure, no crash", %{
      conn: conn,
      scope: scope,
      dinner: dinner
    } do
      NormativeGuests.shared_dinner!(scope, dinner)
      {venue, services} = Rows.category!(scope, NormativeExamples.venue_category())
      %{offer: offer} = Rows.offer!(scope, :venue_a, venue, services, dinner)

      Repo.delete!(Repo.get_by!(HeadcountPreset, name: "Maximum"))

      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      assert has_element?(view, "#offer-cost-missing-preset")
      refute has_element?(view, "#offer-cost-range")
      refute has_element?(view, "#offer-cost-formula")
    end
  end
end
