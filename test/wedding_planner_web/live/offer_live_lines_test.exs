defmodule WeddingPlannerWeb.Live.OfferLiveLinesTest do
  @moduledoc """
  The offer page's lines section (task 52; `docs/modules/offers-and-comparison.md`
  `CST-02`, `CST-20` through `CST-33`, `CST-36`; `docs/04-cross-cutting.md` `XC-01`,
  `XC-10`, `XC-40`–`XC-42`; `DR-18`, `DR-23`, `DR-41`, `DR-42`). Kept separate from
  `WeddingPlannerWeb.Live.OfferLiveTest` (task 51's own file) per this task's
  boundaries.
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import WeddingPlanner.OfferFixtures

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Events
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Repo

  setup %{conn: conn} do
    user = insert_user!("Wannes")
    scope = Scope.for_user(user)
    category = category_fixture(scope)
    offer = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})
    {:ok, catering} = Categories.create_service(scope, category, %{"name" => "Catering"})
    {:ok, sound} = Categories.create_service(scope, category, %{"name" => "Sound"})
    {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner"})

    %{
      conn: log_in_user(conn, user),
      user: user,
      scope: scope,
      category: category,
      offer: offer,
      catering: catering,
      sound: sound,
      dinner: dinner
    }
  end

  defp eur(amount), do: WeddingPlanner.Money.new(amount)

  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp attr(html, selector, name), do: html |> find(selector) |> LazyHTML.attribute(name)

  defp open_add_line(view) do
    view |> element("#offer-add-line") |> render_click()
  end

  describe "add line — each state/basis combination (CST-20..33)" do
    test "a mandatory flat ad hoc line", %{conn: conn, offer: offer} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      open_add_line(view)

      view
      |> form("#add-line-form", line: %{"label" => "Cleaning fee", "state" => "mandatory"})
      |> render_change()

      view
      |> form("#add-line-form",
        line: %{
          "label" => "Cleaning fee",
          "state" => "mandatory",
          "basis" => "flat",
          "amount_input" => "350"
        }
      )
      |> render_submit()

      assert [line] = Offers.list_lines(offer)
      assert line.label == "Cleaning fee"
      assert line.state == :mandatory
      assert line.basis == :flat
      assert Money.equal?(line.amount, eur(350))
      refute has_element?(view, "#add-line-form")
      assert has_element?(view, "#offer-line-#{line.id}", "Cleaning fee")
    end

    test "a per-adult service line with an event and a minimum charge", %{
      conn: conn,
      offer: offer,
      catering: catering,
      dinner: dinner
    } do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      open_add_line(view)

      view
      |> form("#add-line-form",
        line: %{"service_choice" => to_string(catering.id), "state" => "optional"}
      )
      |> render_change()

      view
      |> form("#add-line-form",
        line: %{
          "service_choice" => to_string(catering.id),
          "state" => "optional",
          "basis" => "per_adult"
        }
      )
      |> render_change()

      view
      |> form("#add-line-form",
        line: %{
          "service_choice" => to_string(catering.id),
          "state" => "optional",
          "basis" => "per_adult",
          "event_id" => to_string(dinner.id),
          "amount_input" => "85",
          "minimum_charge_input" => "6.800"
        }
      )
      |> render_submit()

      assert [line] = Offers.list_lines(offer)
      assert line.service_id == catering.id
      assert line.state == :optional
      assert line.basis == :per_adult
      assert line.event_id == dinner.id
      assert Money.equal?(line.amount, eur(85))
      assert Money.equal?(line.minimum_charge, eur(6800))
    end

    test "a per-attendee line with an included quantity", %{
      conn: conn,
      offer: offer,
      catering: catering,
      dinner: dinner
    } do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      open_add_line(view)

      view
      |> form("#add-line-form",
        line: %{"service_choice" => to_string(catering.id), "state" => "mandatory"}
      )
      |> render_change()

      view
      |> form("#add-line-form",
        line: %{
          "service_choice" => to_string(catering.id),
          "state" => "mandatory",
          "basis" => "per_attendee"
        }
      )
      |> render_change()

      view
      |> form("#add-line-form",
        line: %{
          "service_choice" => to_string(catering.id),
          "state" => "mandatory",
          "basis" => "per_attendee",
          "event_id" => to_string(dinner.id),
          "amount_input" => "12",
          "included_quantity" => "50"
        }
      )
      |> render_submit()

      assert [line] = Offers.list_lines(offer)
      assert line.basis == :per_attendee
      assert line.included_quantity == 50
      assert Money.equal?(line.amount, eur(12))
    end

    test "an included service line renders no pricing fields", %{
      conn: conn,
      offer: offer,
      sound: sound
    } do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      open_add_line(view)

      view
      |> form("#add-line-form", line: %{"service_choice" => to_string(sound.id)})
      |> render_change()

      view
      |> form("#add-line-form",
        line: %{"service_choice" => to_string(sound.id), "state" => "included"}
      )
      |> render_change()

      refute has_element?(view, "#add-line-basis")
      refute has_element?(view, "#add-line-amount")

      view
      |> form("#add-line-form",
        line: %{"service_choice" => to_string(sound.id), "state" => "included"}
      )
      |> render_submit()

      assert [line] = Offers.list_lines(offer)
      assert line.state == :included
      assert is_nil(line.basis)
      assert is_nil(line.amount)
    end

    test "an unknown service line", %{conn: conn, offer: offer, sound: sound} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      open_add_line(view)

      view
      |> form("#add-line-form", line: %{"service_choice" => to_string(sound.id)})
      |> render_change()

      view
      |> form("#add-line-form",
        line: %{"service_choice" => to_string(sound.id), "state" => "unknown"}
      )
      |> render_submit()

      assert [line] = Offers.list_lines(offer)
      assert line.state == :unknown
      assert is_nil(line.basis)
    end
  end

  describe "field visibility on state/basis change (fail-proof: remove phx-change)" do
    test "basis/amount appear for a priced state and hide for an unpriced one", %{
      conn: conn,
      offer: offer,
      catering: catering,
      dinner: dinner
    } do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      open_add_line(view)
      refute has_element?(view, "#add-line-basis")

      view
      |> form("#add-line-form",
        line: %{"service_choice" => to_string(catering.id), "state" => "optional"}
      )
      |> render_change()

      assert has_element?(view, "#add-line-basis")
      assert has_element?(view, "#add-line-amount")
      refute has_element?(view, "#add-line-event")
      refute has_element?(view, "#add-line-included")

      view
      |> form("#add-line-form",
        line: %{
          "service_choice" => to_string(catering.id),
          "state" => "optional",
          "basis" => "per_adult"
        }
      )
      |> render_change()

      assert has_element?(view, "#add-line-event")
      assert has_element?(view, "#add-line-included")

      view
      |> form("#add-line-form",
        line: %{
          "service_choice" => to_string(catering.id),
          "state" => "optional",
          "basis" => "per_adult",
          "event_id" => to_string(dinner.id)
        }
      )
      |> render_change()

      view
      |> form("#add-line-form",
        line: %{"service_choice" => to_string(catering.id), "state" => "included"}
      )
      |> render_change()

      refute has_element?(view, "#add-line-basis")
      refute has_element?(view, "#add-line-amount")
      refute has_element?(view, "#add-line-event")
    end
  end

  describe "ad hoc constraints (CST-22)" do
    test "an ad hoc line's state select never offers Included", %{conn: conn, offer: offer} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      open_add_line(view)
      html = render(view)

      assert attr(html, "#add-line-state option[value=included]", "value") == []
      assert attr(html, "#add-line-state option[value=mandatory]", "value") == ["mandatory"]
      assert attr(html, "#add-line-state option[value=optional]", "value") == ["optional"]
    end

    test "a service line's state select offers all five states", %{
      conn: conn,
      offer: offer,
      catering: catering
    } do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      open_add_line(view)

      view
      |> form("#add-line-form", line: %{"service_choice" => to_string(catering.id)})
      |> render_change()

      html = render(view)
      assert attr(html, "#add-line-state option[value=included]", "value") == ["included"]
    end
  end

  describe "per-person requires an event (CST-31)" do
    test "submitting without an event shows the error and saves nothing", %{
      conn: conn,
      offer: offer,
      catering: catering
    } do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      open_add_line(view)

      view
      |> form("#add-line-form",
        line: %{"service_choice" => to_string(catering.id), "state" => "optional"}
      )
      |> render_change()

      # A second step, revealing the (still-blank) event field before submitting, is
      # needed so the field counts as "used" (`Phoenix.Component.used_input?/1`) — the
      # same reason the two-step vat-rate test in `OfferLiveTest` exists — otherwise
      # Phoenix's own "don't show an error for a field the user hasn't reached yet"
      # filtering would (correctly) hide the error on this very first render of it.
      view
      |> form("#add-line-form",
        line: %{
          "service_choice" => to_string(catering.id),
          "state" => "optional",
          "basis" => "per_adult"
        }
      )
      |> render_change()

      html =
        view
        |> form("#add-line-form",
          line: %{
            "service_choice" => to_string(catering.id),
            "state" => "optional",
            "basis" => "per_adult",
            "amount_input" => "85"
          }
        )
        |> render_submit()

      assert html =~ "a per-person line needs an event"
      assert Offers.list_lines(offer) == []
    end
  end

  describe "VAT rate override (CST-33, DR-41)" do
    test "not shown on an inclusive offer", %{conn: conn, offer: offer} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      open_add_line(view)

      view
      |> form("#add-line-form", line: %{"state" => "mandatory"})
      |> render_change()

      refute has_element?(view, "#add-line-vat-rate")
    end

    test "shown, with the offer's own rate as placeholder, on an exclusive offer", %{
      conn: conn,
      scope: scope,
      category: category
    } do
      offer =
        offer_fixture(scope, category, %{
          "vendor_name" => "Caterer C",
          "vat_basis" => "exclusive",
          "vat_rate_input" => "21"
        })

      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      open_add_line(view)

      view
      |> form("#add-line-form", line: %{"state" => "mandatory"})
      |> render_change()

      assert has_element?(view, "#add-line-vat-rate[placeholder=\"21\"]")
    end
  end

  describe "on/off toggle (CST-22)" do
    test "flips enabled and logs it", %{conn: conn, scope: scope, offer: offer} do
      {:ok, line} =
        Offers.create_line(scope, offer, %{
          "label" => "Corkage fee",
          "state" => "optional",
          "basis" => "flat",
          "amount_input" => "25"
        })

      refute line.enabled

      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")
      assert has_element?(view, "#offer-line-#{line.id}-toggle")

      view
      |> form("#offer-line-#{line.id}-toggle-form", %{"enabled" => "true"})
      |> render_change()

      assert Offers.get_line!(line.id).enabled
      assert has_element?(view, "#offer-history", "turned on")
    end
  end

  describe "service created on the fly (CST-02)" do
    test "creates the service in the category and the line against it", %{
      conn: conn,
      offer: offer,
      category: category
    } do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      open_add_line(view)

      view
      |> form("#add-line-form", line: %{"service_choice" => "new"})
      |> render_change()

      assert has_element?(view, "#add-line-new-service-name")
      refute has_element?(view, "#add-line-label")

      view
      |> form("#add-line-form",
        line: %{
          "service_choice" => "new",
          "new_service_name" => "Photobooth",
          "state" => "mandatory"
        }
      )
      |> render_change()

      view
      |> form("#add-line-form",
        line: %{
          "service_choice" => "new",
          "new_service_name" => "Photobooth",
          "state" => "mandatory",
          "basis" => "flat",
          "amount_input" => "250"
        }
      )
      |> render_submit()

      services = Categories.list_services(category)
      assert service = Enum.find(services, &(&1.name == "Photobooth"))

      assert [line] = Offers.list_lines(offer)
      assert line.service_id == service.id
    end
  end

  describe "invalid lines — event deleted (XC-41, XC-42, DR-42)" do
    test "deleting the event marks the line invalid live, and editing it to another event repairs it",
         %{conn: conn, scope: scope, offer: offer, catering: catering, dinner: dinner} do
      {:ok, line} =
        Offers.create_line(scope, offer, %{
          "service_id" => catering.id,
          "state" => "optional",
          "basis" => "per_adult",
          "event_id" => dinner.id,
          "amount_input" => "85"
        })

      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")
      refute has_element?(view, "#offer-line-#{line.id}-invalid")

      {:ok, _} = Events.delete_event(scope, dinner)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#offer-line-#{line.id}-invalid", "Event deleted")
      assert has_element?(view, "#offer-line-#{line.id} .line-through")

      {:ok, party} = Events.create_event(scope, %{"name" => "Party"})

      view |> element("#offer-line-#{line.id}-edit") |> render_click()
      assert has_element?(view, "#edit-line-event")

      view
      |> form("#edit-line-form",
        line: %{
          "service_choice" => to_string(catering.id),
          "state" => "optional",
          "basis" => "per_adult",
          "event_id" => to_string(party.id),
          "amount_input" => "85"
        }
      )
      |> render_submit()

      refute has_element?(view, "#offer-line-#{line.id}-invalid")
      assert Offers.get_line!(line.id).event_id == party.id
    end
  end

  describe "delete (XC-40)" do
    test "through the confirmation", %{conn: conn, scope: scope, offer: offer} do
      {:ok, line} =
        Offers.create_line(scope, offer, %{
          "label" => "Cleaning fee",
          "state" => "mandatory",
          "basis" => "flat",
          "amount_input" => "350"
        })

      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      view |> element("#offer-line-#{line.id}-delete") |> render_click()
      assert has_element?(view, "#offer-line-#{line.id}-delete-confirm")

      view |> element("#offer-line-#{line.id}-delete-confirm-confirm") |> render_click()

      assert_raise Ecto.NoResultsError, fn -> Offers.get_line!(line.id) end
      refute has_element?(view, "#offer-line-#{line.id}")
    end
  end

  describe "history (XC-11)" do
    test "adding a line shows an entry", %{conn: conn, offer: offer} do
      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")

      open_add_line(view)

      view
      |> form("#add-line-form", line: %{"label" => "Cleaning fee", "state" => "mandatory"})
      |> render_change()

      view
      |> form("#add-line-form",
        line: %{
          "label" => "Cleaning fee",
          "state" => "mandatory",
          "basis" => "flat",
          "amount_input" => "350"
        }
      )
      |> render_submit()

      assert has_element?(view, "#offer-history", "added line 'Cleaning fee'")
    end
  end

  describe "live updates (fail-proof: remove the :event/:service subscription)" do
    test "renaming an event live-updates a per-person line's displayed event name", %{
      conn: conn,
      scope: scope,
      offer: offer,
      catering: catering,
      dinner: dinner
    } do
      {:ok, line} =
        Offers.create_line(scope, offer, %{
          "service_id" => catering.id,
          "state" => "optional",
          "basis" => "per_adult",
          "event_id" => dinner.id,
          "amount_input" => "85"
        })

      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")
      assert has_element?(view, "#offer-line-#{line.id}", "Dinner")

      {:ok, _} = Events.update_event(scope, dinner, %{"name" => "Dinner party"})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#offer-line-#{line.id}", "Dinner party")
    end

    test "renaming a service live-updates a line's displayed label", %{
      conn: conn,
      scope: scope,
      offer: offer,
      sound: sound
    } do
      {:ok, line} =
        Offers.create_line(scope, offer, %{"service_id" => sound.id, "state" => "included"})

      {:ok, view, _html} = live(conn, ~p"/offers/#{offer.id}")
      assert has_element?(view, "#offer-line-#{line.id}", "Sound")

      {:ok, _} = Categories.update_service(scope, sound, %{"name" => "Sound system"})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#offer-line-#{line.id}", "Sound system")
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
