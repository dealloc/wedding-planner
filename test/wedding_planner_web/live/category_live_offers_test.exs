defmodule WeddingPlannerWeb.Live.CategoryLiveOffersTest do
  @moduledoc """
  The category page's offer forms (tasks 51/52, `DR-43`) — the add-offer form and the
  quick-offer form (`CST-11`) — and `WeddingPlanner.Categories.category_deletion_blockers/1`'s
  offer half (`DR-26` Q11). Task 65 (`DR-57`) replaced the plain offers list this file
  used to exercise with the comparison matrix: a created offer now shows up as a
  **matrix column** (`#matrix-col-<id>-*`) rather than a `#category-offer-<id>-*` list
  row — the matrix's own rendering (cells, gaps, totals) is
  `WeddingPlannerWeb.Live.CategoryLiveMatrixTest`'s job; this file only re-asserts the
  behaviour that survives the replacement (offer creation, the quick-offer form, the
  `CST-06` has-lines delete path, category deletion blockers). Kept in its own file,
  separate from `WeddingPlannerWeb.Live.CategoryLiveTest`, per this task's boundaries.
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

  describe "matrix column (task 65, DR-57)" do
    test "an offer renders as a matrix column: vendor (linking to its page), status, VAT basis",
         %{conn: conn, scope: scope, category: category} do
      offer =
        offer_fixture(scope, category, %{"vat_basis" => "inclusive", "status" => "considering"})

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      assert has_element?(view, "#matrix-col-#{offer.id}-vendor", offer.vendor_name)

      assert attr_of(
               render(view),
               "#matrix-col-#{offer.id}-vendor",
               "href"
             ) == ["/offers/#{offer.id}"]

      # Task 66 (DR-40): a non-confirmed offer's status is the header's own select, not
      # the read-only pill (that only ever shows for :confirmed) — the selected option's
      # text is the status.
      assert has_element?(view, "#matrix-status-#{offer.id} option[selected]", "Considering")
      assert has_element?(view, "#matrix-col-#{offer.id}-vat-basis", "incl. VAT")
    end

    test "the matrix refreshes on :offer broadcasts from another process", %{
      conn: conn,
      scope: scope,
      category: category
    } do
      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      refute has_element?(view, "#comparison-matrix", "Kasteel Heers")

      offer = offer_fixture(scope, category)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#matrix-col-#{offer.id}-vendor", "Kasteel Heers")
    end
  end

  describe "line notes in the matrix (CST-26)" do
    test "a service line's and an ad hoc line's notes sit behind a collapsed toggle",
         %{conn: conn, scope: scope, category: category} do
      offer = offer_fixture(scope, category)
      {:ok, catering} = Categories.create_service(scope, category, %{"name" => "Catering"})

      {:ok, service_line} =
        Offers.create_line(scope, offer, %{
          "service_id" => catering.id,
          "state" => "included",
          "notes" => "excludes drinks"
        })

      {:ok, ad_hoc_line} =
        Offers.create_line(scope, offer, %{
          "label" => "Cleaning fee",
          "state" => "mandatory",
          "basis" => "flat",
          "amount_input" => "350",
          "notes" => "paid on the day"
        })

      {:ok, plain_line} =
        Offers.create_line(scope, offer, %{
          "label" => "Parking",
          "state" => "mandatory",
          "basis" => "flat",
          "amount_input" => "10"
        })

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

      assert has_element?(view, "#matrix-line-note-#{service_line.id}")
      assert has_element?(view, "#matrix-line-note-#{service_line.id} summary")
      assert has_element?(view, "#matrix-line-note-#{service_line.id}", "excludes drinks")
      assert has_element?(view, "#matrix-line-note-#{ad_hoc_line.id}", "paid on the day")
      refute has_element?(view, "#matrix-line-note-#{plain_line.id}")
      refute has_element?(view, "#matrix-line-note-#{service_line.id}[open]")
    end
  end

  describe "quick offer (CST-11, DR-41, task 52)" do
    test "creates an offer with one 'Price' line and shows it as a matrix column",
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

      assert has_element?(view, "#matrix-col-#{offer.id}-vendor", "Bridal Boutique")
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
