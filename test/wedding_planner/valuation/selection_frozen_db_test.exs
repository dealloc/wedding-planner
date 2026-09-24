defmodule WeddingPlanner.Valuation.SelectionFrozenDbTest do
  @moduledoc """
  The frozen selection over **real database rows** (`CST-40`, `CST-44`, `DR-61`,
  `DR-66`): Venue A confirmed with `WeddingPlanner.OfferFixtures.confirm_directly!/1`, a
  later priority change through `WeddingPlanner.Categories.update_service/3`, and the
  committed total read back through `WeddingPlanner.Valuation.Snapshot.load/1` — the round
  trip the pure `WeddingPlanner.Valuation.SelectionFrozenTest` cannot exercise. Plus the
  migration's backstops: the planning pick's partial unique index and CHECK, and the
  frozen rows' unique pair and service-side `on_delete: :restrict`.
  """
  use WeddingPlanner.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import WeddingPlanner.OfferFixtures

  alias WeddingPlanner.Categories
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeGuests
  alias WeddingPlanner.NormativeOfferRows, as: Rows
  alias WeddingPlanner.Offers.FrozenService
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Offer, as: OfferEngine
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Format

  @nbsp <<0xA0::utf8>>

  defp likely_total(offer_id) do
    snapshot = Snapshot.load(Repo)
    offer = Enum.find(snapshot.offers, &(&1.id == offer_id))
    likely = Enum.find(snapshot.headcount_presets, &(&1.role == :likely))
    %Formula{total: {:money, money}} = OfferEngine.total(snapshot, offer, likely)
    Format.money(money)
  end

  @tag :real_path
  test "CST-40 through the loader: Catering set to not wanted after confirming leaves Venue A at €11,726" do
    scope = scope_fixture()
    dinner = Rows.dinner!(scope)
    {venue, services} = Rows.category!(scope, NE.venue_category())
    %{offer: offer} = Rows.offer!(scope, :venue_a, venue, services, dinner)
    _guests = NormativeGuests.shared_dinner!(scope, dinner)

    confirmed = confirm_directly!(offer)
    assert confirmed.status == :confirmed
    refute confirmed.planning_pick

    snapshot = Snapshot.load(Repo)

    assert snapshot.frozen_services |> Enum.map(& &1.service_id) |> Enum.sort() ==
             services
             |> Map.take(["Seating", "Catering", "Sound", "Late-night snack"])
             |> Map.values()
             |> Enum.map(& &1.id)
             |> Enum.sort()

    assert likely_total(offer.id) == "€#{@nbsp}11.726,00"

    catering = Map.fetch!(services, "Catering")

    {:ok, _catering} =
      Categories.update_service(scope, catering, %{"wanted_priority" => "not_wanted"})

    assert likely_total(offer.id) == "€#{@nbsp}11.726,00"

    # The same change does move an unconfirmed offer — the test is not vacuous.
    snapshot = Snapshot.load(Repo)
    unconfirmed = %{Enum.find(snapshot.offers, &(&1.id == offer.id)) | status: :shortlisted}
    loaded_catering = Enum.find(snapshot.services, &(&1.id == catering.id))
    assert loaded_catering.wanted_priority == :not_wanted
    refute Selection.effectively_wanted?(snapshot, unconfirmed, loaded_catering)
  end

  describe "migration backstops (DR-61, DR-66)" do
    setup do
      scope = scope_fixture()
      category = category_fixture(scope)
      %{scope: scope, category: category}
    end

    defp set_pick!(offer_id) do
      Repo.update_all(from(o in Offer, where: o.id == ^offer_id), set: [planning_pick: true])
    end

    test "one planning pick per category (partial unique index); another category is fine", %{
      scope: scope,
      category: category
    } do
      first = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})
      second = offer_fixture(scope, category, %{"vendor_name" => "Venue B"})
      other = offer_fixture(scope, category_fixture(scope, %{"name" => "Catering"}))

      assert {1, _} = set_pick!(first.id)
      assert {1, _} = set_pick!(other.id)

      assert_raise Exqlite.Error, ~r/UNIQUE constraint failed/, fn -> set_pick!(second.id) end
    end

    test "no planning pick on a confirmed or a rejected offer (CHECK)", %{
      scope: scope,
      category: category
    } do
      confirmed = scope |> offer_fixture(category) |> confirm_directly!()

      assert_raise Exqlite.Error,
                   ~r/CHECK constraint failed: offers_planning_pick_requires_open_status/,
                   fn -> set_pick!(confirmed.id) end

      rejected = offer_fixture(scope, category, %{"vendor_name" => "Venue R"})

      {1, _} =
        Repo.update_all(from(o in Offer, where: o.id == ^rejected.id), set: [status: :rejected])

      assert_raise Exqlite.Error,
                   ~r/CHECK constraint failed: offers_planning_pick_requires_open_status/,
                   fn -> set_pick!(rejected.id) end
    end

    test "a frozen row is unique per offer × service, and its service cannot be deleted", %{
      scope: scope,
      category: category
    } do
      service = service_fixture(scope, category)
      offer = scope |> offer_fixture(category) |> confirm_directly!()

      assert [%FrozenService{service_id: service_id}] =
               Repo.all(from f in FrozenService, where: f.offer_id == ^offer.id)

      assert service_id == service.id

      assert {:error, changeset} =
               %FrozenService{offer_id: offer.id, service_id: service.id}
               |> FrozenService.changeset()
               |> Repo.insert()

      assert errors_on(changeset) != %{}

      assert_raise Ecto.ConstraintError, fn -> Repo.delete(service) end
    end
  end
end
