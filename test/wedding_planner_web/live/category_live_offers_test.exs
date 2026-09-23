defmodule WeddingPlannerWeb.Live.CategoryLiveOffersTest do
  @moduledoc """
  The category page's Offers section (task 51, `DR-43`) — a plain list plus a quick
  add-offer form, and `WeddingPlanner.Categories.category_deletion_blockers/1`'s offer
  half (`DR-26` Q11), wired up back in task 49 and exercised here for the first time
  with a real offer. Kept in its own file, separate from
  `WeddingPlannerWeb.Live.CategoryLiveTest`, per this task's boundaries (task 50 edits
  that file concurrently).
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import WeddingPlanner.OfferFixtures

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Repo

  setup %{conn: conn} do
    user = insert_user!("Wannes")
    scope = Scope.for_user(user)
    category = category_fixture(scope)

    %{conn: log_in_user(conn, user), scope: scope, category: category}
  end

  describe "add offer" do
    test "creating an offer navigates to its own page", %{conn: conn, category: category} do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      view
      |> form("#add-offer-form", offer: %{"vendor_name" => "Kasteel Heers"})
      |> render_submit()

      [offer] = Offers.list_offers(category)
      assert offer.vendor_name == "Kasteel Heers"
      assert offer.status == :considering
      assert offer.vat_basis == :inclusive

      assert_redirect(view, ~p"/offers/#{offer.id}")
    end

    test "a blank vendor name is rejected with an inline error", %{
      conn: conn,
      category: category
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      html =
        view
        |> form("#add-offer-form", offer: %{"vendor_name" => ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Offers.list_offers(category) == []
    end
  end

  describe "listing" do
    test "lists an offer's vendor (linking to its page), status and VAT basis", %{
      conn: conn,
      scope: scope,
      category: category
    } do
      offer =
        offer_fixture(scope, category, %{"vat_basis" => "inclusive", "status" => "considering"})

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      assert has_element?(view, "#category-offer-#{offer.id}-vendor", offer.vendor_name)

      assert attr_of(
               render(view),
               "#category-offer-#{offer.id}-vendor",
               "href"
             ) == ["/offers/#{offer.id}"]

      assert has_element?(
               view,
               "#category-offer-#{offer.id}-status",
               "Considering"
             )

      assert has_element?(
               view,
               "#category-offer-#{offer.id}-vat-basis",
               "Inclusive"
             )
    end

    test "the offers list refreshes on :offer broadcasts from another process", %{
      conn: conn,
      scope: scope,
      category: category
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      refute has_element?(view, "#category-offers", "Kasteel Heers")

      offer = offer_fixture(scope, category)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#category-offer-#{offer.id}-vendor", "Kasteel Heers")
    end
  end

  describe "category deletion blockers (DR-26 Q11)" do
    test "a category with an offer cannot be deleted, and the confirmation says why", %{
      conn: conn,
      scope: scope,
      category: category
    } do
      offer_fixture(scope, category)

      {:ok, view, _html} = live(conn, ~p"/categories")

      view |> element("#category-#{category.id}-delete") |> render_click()

      refute has_element?(view, "#category-#{category.id}-delete-confirm-confirm")
      assert has_element?(view, "#category-#{category.id}-delete-confirm-blockers", "1 offer")

      assert {:error, :has_blockers} = Categories.delete_category(scope, category)
      assert Categories.get_category!(category.id)
    end

    test "a category with no offers deletes normally", %{
      conn: conn,
      category: category
    } do
      {:ok, view, _html} = live(conn, ~p"/categories")

      view |> element("#category-#{category.id}-delete") |> render_click()
      assert has_element?(view, "#category-#{category.id}-delete-confirm-confirm")

      view |> element("#category-#{category.id}-delete-confirm-confirm") |> render_click()

      assert_raise Ecto.NoResultsError, fn -> Categories.get_category!(category.id) end
    end
  end

  defp attr_of(html, selector, name) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
