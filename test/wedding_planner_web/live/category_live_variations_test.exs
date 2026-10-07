defmodule WeddingPlannerWeb.Live.CategoryLiveVariationsTest do
  @moduledoc """
  Variations of a service (`docs/modules/offers-and-comparison.md` `CST-27`): lines of one
  service sharing a variation name are mutually exclusive — the matrix cell's dropdown
  picks the one that counts toward the total (O7).
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import WeddingPlanner.DataCase, only: [errors_on: 1]
  import WeddingPlanner.OfferFixtures

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Offer, as: OfferEngine
  alias WeddingPlanner.Valuation.Snapshot

  setup %{conn: conn} do
    user = insert_user!("Wannes")
    scope = Scope.for_user(user)
    category = category_fixture(scope)
    offer = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})
    drinks = service_fixture(scope, category, %{"name" => "Drinks"})

    line = fn attrs ->
      {:ok, line} =
        Offers.create_line(
          scope,
          offer,
          Map.merge(
            %{
              "service_id" => drinks.id,
              "state" => "mandatory",
              "basis" => "flat"
            },
            attrs
          )
        )

      line
    end

    base = line.(%{"amount_input" => "50"})
    cava = line.(%{"variation" => "Cava", "amount_input" => "100"})
    champagne = line.(%{"variation" => "Champagne", "amount_input" => "160"})

    %{
      conn: log_in_user(conn, user),
      scope: scope,
      category: category,
      offer: offer,
      drinks: drinks,
      base: base,
      cava: cava,
      champagne: champagne
    }
  end

  defp total(offer_id) do
    snapshot = Snapshot.load(Repo)
    offer = Enum.find(snapshot.offers, &(&1.id == offer_id))
    preset = Enum.find(snapshot.headcount_presets, &(&1.name == "Likely"))
    %Formula{total: {:money, money}} = OfferEngine.total(snapshot, offer, preset)
    money
  end

  test "only the first variation counts until another is chosen (O7)", %{offer: offer} do
    # common €50 + Cava €100; Champagne is not chosen.
    assert Money.equal?(total(offer.id), WeddingPlanner.Money.new(150))
  end

  test "the matrix cell shows a dropdown; choosing a variation moves the total",
       %{
         conn: conn,
         category: category,
         offer: offer,
         drinks: drinks,
         cava: cava,
         champagne: champagne
       } do
    {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}")

    select = "#matrix-variation-#{drinks.id}-#{offer.id}"
    assert has_element?(view, select)
    assert has_element?(view, "#{select} option[selected]", "Cava")
    assert has_element?(view, "#{select} option", "Champagne")

    view
    |> form("#matrix-variation-form-#{drinks.id}-#{offer.id}", %{"variation" => "Champagne"})
    |> render_change()

    assert has_element?(view, "#{select} option[selected]", "Champagne")
    assert Offers.get_line!(champagne.id).chosen
    refute Offers.get_line!(cava.id).chosen
    assert Money.equal?(total(offer.id), WeddingPlanner.Money.new(210))
  end

  test "a choice for a variation that no longer exists falls back to the first",
       %{offer: offer, drinks: drinks, champagne: champagne, scope: scope} do
    {:ok, _} = Offers.choose_variation(scope, offer, drinks, "Champagne")
    assert Money.equal?(total(offer.id), WeddingPlanner.Money.new(210))

    {:ok, _} = Offers.delete_line(scope, champagne)
    assert Money.equal?(total(offer.id), WeddingPlanner.Money.new(150))
  end

  test "choose_variation refuses an unknown variation", %{
    offer: offer,
    drinks: drinks,
    scope: scope
  } do
    assert {:error, :unknown_variation} =
             Offers.choose_variation(scope, offer, drinks, "Prosecco")
  end

  test "an ad hoc line cannot carry a variation", %{scope: scope, offer: offer} do
    assert {:error, changeset} =
             Offers.create_line(scope, offer, %{
               "label" => "Cleaning",
               "variation" => "Deep",
               "state" => "mandatory",
               "basis" => "flat",
               "amount_input" => "10"
             })

    assert %{variation: [_]} = errors_on(changeset)
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
