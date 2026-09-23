defmodule WeddingPlanner.OfferFixtures do
  @moduledoc """
  Test support for offers (`docs/modules/offers-and-comparison.md` `CST-10`, `CST-33`;
  `DR-40`) — a scope, a category and a vendor name are all a caller usually needs; every
  option can be overridden through `attrs`.
  """

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Repo

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
end
