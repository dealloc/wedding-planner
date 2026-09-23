defmodule WeddingPlannerWeb.Live.CategoryLiveOffersTest do
  @moduledoc """
  The category page's Offers section (task 51, `DR-43`) — a plain list plus a quick
  add-offer form, and `WeddingPlanner.Categories.category_deletion_blockers/1`'s offer
  half (`DR-26` Q11), wired up back in task 49 and exercised here for the first time
  with a real offer. Task 52 adds the quick-offer form (`CST-11`), the line-count
  column and the `CST-06` has-lines delete path exercised with a real line for the
  first time (task 50 built it behind the seam; `WeddingPlannerWeb.Live.CategoryLiveTest`
  only ever exercised the zero-lines path). Kept in its own file, separate from
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

    test "shows each offer's line count, live as lines are added (task 52)", %{
      conn: conn,
      scope: scope,
      category: category
    } do
      offer = offer_fixture(scope, category)

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")
      assert has_element?(view, "#category-offer-#{offer.id}-line-count", "No lines")

      {:ok, _line} =
        Offers.create_line(scope, offer, %{
          "label" => "Cleaning fee",
          "state" => "mandatory",
          "basis" => "flat",
          "amount_input" => "350"
        })

      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#category-offer-#{offer.id}-line-count", "1 line")
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

  describe "quick offer (CST-11, DR-41, task 52)" do
    test "creates an offer with one 'Price' line and shows it in the list with its line count",
         %{conn: conn, category: category} do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      view
      |> form("#quick-offer-form",
        quick_offer: %{"vendor_name" => "Bridal Boutique", "amount_input" => "1.800"}
      )
      |> render_submit()

      assert [offer] = Offers.list_offers(category)
      assert offer.vendor_name == "Bridal Boutique"
      assert offer.vat_basis == :inclusive

      assert [line] = Offers.list_lines(offer)
      assert line.label == "Price"
      assert line.state == :mandatory
      assert Money.equal?(line.amount, WeddingPlanner.Money.new(1800))

      assert has_element?(view, "#category-offer-#{offer.id}-vendor", "Bridal Boutique")
      assert has_element?(view, "#category-offer-#{offer.id}-line-count", "1 line")
      assert has_element?(view, "#flash-group", "Added Bridal Boutique")
    end

    test "a blank vendor name is rejected with an inline error, nothing created", %{
      conn: conn,
      category: category
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      html =
        view
        |> form("#quick-offer-form",
          quick_offer: %{"vendor_name" => "", "amount_input" => "1.800"}
        )
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Offers.list_offers(category) == []
    end
  end

  describe "service-with-lines delete path (CST-06, task 52)" do
    test "a service with a real line shows 'Set to not wanted' / merge instead of Delete", %{
      conn: conn,
      scope: scope,
      category: category
    } do
      {:ok, service} = Categories.create_service(scope, category, %{"name" => "Catering"})
      offer = offer_fixture(scope, category)

      {:ok, _line} =
        Offers.create_line(scope, offer, %{
          "service_id" => service.id,
          "state" => "mandatory",
          "basis" => "flat",
          "amount_input" => "500"
        })

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      view
      |> element("#service-#{service.id}-delete")
      |> render_click()

      refute has_element?(view, "#service-#{service.id}-delete-confirm-confirm")
      assert has_element?(view, "#service-#{service.id}-delete-confirm-set-not-wanted")
      assert has_element?(view, "#service-#{service.id}-delete-confirm", "not wanted")

      assert {:error, :has_lines} = Categories.delete_service(scope, service)
      assert Categories.get_service!(service.id)
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
