defmodule WeddingPlanner.OfferFixtures do
  @moduledoc """
  Test support for offers (`docs/modules/offers-and-comparison.md` `CST-10`, `CST-33`;
  `DR-40`) — a scope, a category and a vendor name are all a caller usually needs; every
  option can be overridden through `attrs`.

  `confirm_directly!/1` confirms an offer the way C5 does (`CST-40`, `DR-61`): status
  *and* frozen selection. Use `WeddingPlanner.Offers.confirm_offer/2` once task 73 lands;
  this helper exists so tests can confirm before then, and for engine-adjacent tests that
  want no activity-log entry. Never confirm an offer by writing only its status column: a
  confirmed offer without frozen rows has an empty scope, so its optional service lines
  stop counting.
  """

  import Ecto.Query

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Offers.FrozenService
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Snapshot

  @doc "A scope for a freshly inserted user named `display_name`."
  @spec scope_fixture(String.t()) :: Scope.t()
  def scope_fixture(display_name \\ "Wannes") do
    user = %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
    Scope.for_user(user)
  end

  @doc "A freshly inserted category, `attrs` overriding the default name."
  def category_fixture(scope, attrs \\ %{}) do
    {:ok, category} = Categories.create_category(scope, Map.merge(%{"name" => "Venue"}, attrs))
    category
  end

  @doc """
  A freshly inserted offer in `category` (`attrs` overriding the default vendor name).
  """
  def offer_fixture(scope, category, attrs \\ %{}) do
    {:ok, offer} =
      Offers.create_offer(scope, category, Map.merge(%{"vendor_name" => "Kasteel Heers"}, attrs))

    offer
  end

  @doc """
  A freshly inserted service in `category` (`attrs` overriding the default name and
  wanted priority — nice-to-have by default).
  """
  def service_fixture(scope, category, attrs \\ %{}) do
    {:ok, service} =
      Categories.create_service(
        scope,
        category,
        Map.merge(%{"name" => "Sound", "wanted_priority" => "nice_to_have"}, attrs)
      )

    service
  end

  @doc """
  Test-only: confirms `offer` in one transaction — `status: :confirmed`,
  `planning_pick: false` (one `UPDATE`, the `DR-66` CHECK) and one
  `WeddingPlanner.Offers.FrozenService` row per id of
  `Selection.freeze(Snapshot.load(Repo), offer)`, the frozen selection `CST-40` requires.
  No log entry, no broadcast. Returns the reloaded offer. See the moduledoc.
  """
  @spec confirm_directly!(Offer.t()) :: Offer.t()
  def confirm_directly!(%Offer{id: offer_id}) do
    {:ok, confirmed} =
      Repo.transaction(fn ->
        snapshot = Snapshot.load(Repo)
        loaded = Enum.find(snapshot.offers, &(&1.id == offer_id))
        service_ids = Selection.freeze(snapshot, loaded)

        {1, _} =
          Repo.update_all(from(o in Offer, where: o.id == ^offer_id),
            set: [status: :confirmed, planning_pick: false]
          )

        for service_id <- service_ids do
          %FrozenService{offer_id: offer_id, service_id: service_id}
          |> FrozenService.changeset()
          |> Repo.insert!()
        end

        Repo.get!(Offer, offer_id)
      end)

    confirmed
  end
end
