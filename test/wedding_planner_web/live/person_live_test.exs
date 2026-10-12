defmodule WeddingPlannerWeb.Live.PersonLiveTest do
  @moduledoc """
  `docs/modules/guests-and-events.md` `PER-01`, `PER-02`, `PER-10`–`PER-16`,
  `docs/04-cross-cutting.md` `XC-10`, `XC-11`, `XC-40`, `NFR-31` — the per-person detail
  page (task 27, `DR-26` Q9) and its +1 handling (task 37, `DR-32`/`DR-34`).

  The "marginal cost" describe block (`docs/modules/invoices-and-budget.md` `BUD-22`,
  `BUD-21`; `DR-81`; task 90) builds its own minimal real-database fixture (one Dinner
  event, a confirmed offer with a single per-attendee mandatory line at € 10,00, no
  minimums) rather than the shared 78-guest `WeddingPlanner.NormativeGuests` fixture —
  simplest thing that lets a person's own removal change the forecast by exactly € 10,00
  per person, so the assertions read as round numbers.
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Events
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Log.Query, as: LogQuery
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Repo
  alias WeddingPlannerWeb.Format

  setup %{conn: conn} do
    user = insert_user!("Wannes")
    %{conn: log_in_user(conn, user), user: user, scope: Scope.for_user(user)}
  end

  describe "authentication" do
    test "an unauthenticated request redirects to /login", %{scope: scope} do
      {:ok, person} = Guests.create_person(scope, %{"first_name" => "Anna"})

      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, ~p"/people/#{person.id}")

      assert redirected_to(conn) =~ "/login"
    end
  end

  describe "edit" do
    setup %{scope: scope} do
      {:ok, person} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      %{person: person}
    end

    test "edits a field and shows it in the history", %{conn: conn, person: person} do
      {:ok, view, html} = live(conn, ~p"/people/#{person.id}")

      assert html =~ "Anna Peeters"
      assert has_element?(view, "#person-history", "added 'Anna Peeters'")

      view
      |> form("#person-form",
        person: %{
          "first_name" => "Anna",
          "last_name" => "Peeters",
          "want_tier" => "maybe",
          "certainty" => "likely",
          "age_category" => "adult"
        }
      )
      |> render_submit()

      assert Guests.get_person!(person.id).want_tier == :maybe
      assert has_element?(view, "#person-history", "changed the want tier")
    end

    test "the activity log's person link navigates here", %{conn: conn, person: person} do
      {:ok, activity_view, _html} = live(conn, ~p"/activity")

      assert has_element?(activity_view, "#activity-log", "Anna Peeters")

      {:ok, view, _html} =
        activity_view
        |> element("#activity-log a", "Anna Peeters")
        |> render_click()
        |> follow_redirect(conn)

      assert has_element?(view, "#person-form")
      assert has_element?(view, "h1", "Anna Peeters")
      _ = view
      _ = person
    end

    test "delete requires confirmation and removes the person", %{conn: conn, person: person} do
      {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")

      refute has_element?(view, "#person-delete-confirm")

      view |> element("#person-delete") |> render_click()
      assert has_element?(view, "#person-delete-confirm")
      assert Guests.get_person!(person.id)

      {:ok, index_view, _html} =
        view
        |> element("#person-delete-confirm-confirm")
        |> render_click()
        |> follow_redirect(conn, ~p"/people")

      assert index_view
      assert_raise Ecto.NoResultsError, fn -> Guests.get_person!(person.id) end
    end
  end

  describe "plus ones" do
    setup %{scope: scope} do
      {:ok, host} =
        Guests.create_person(scope, %{
          "first_name" => "Anna",
          "last_name" => "Peeters",
          "want_tier" => "maybe",
          "certainty" => "certain"
        })

      %{host: host}
    end

    test "a possible +1's page shows the host link, no editable want/certainty/group and the inherited values",
         %{conn: conn, scope: scope, host: host} do
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{plus_one_status: :possible})

      {:ok, view, html} = live(conn, ~p"/people/#{plus_one.id}")

      assert html =~ "+1 of Anna Peeters"
      assert has_element?(view, "#person-host-link", "Anna Peeters")

      refute has_element?(view, "#person-form-want")
      refute has_element?(view, "#person-form-certainty")
      refute has_element?(view, "#person-form-group")

      assert has_element?(view, "#person-inherited-want", "Maybe")
      assert has_element?(view, "#person-inherited-certainty", "Certain")
      assert has_element?(view, "#person-inherited-group", "No group")
    end

    test "a confirmed +1 inherits the host's own certainty",
         %{conn: conn, scope: scope, host: host} do
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{plus_one_status: :confirmed})

      {:ok, view, _html} = live(conn, ~p"/people/#{plus_one.id}")

      assert has_element?(view, "#person-inherited-certainty", "Certain")
    end

    test "Confirm is a single click that writes exactly one activity entry",
         %{conn: conn, scope: scope, host: host} do
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{plus_one_status: :possible})
      before_count = length(LogQuery.for_entity(:person, plus_one.id))

      {:ok, view, _html} = live(conn, ~p"/people/#{plus_one.id}")
      assert has_element?(view, "#person-confirm-plus-one")

      view |> element("#person-confirm-plus-one") |> render_click()

      assert Guests.get_person!(plus_one.id).plus_one_status == :confirmed
      refute has_element?(view, "#person-confirm-plus-one")
      assert length(LogQuery.for_entity(:person, plus_one.id)) == before_count + 1
    end

    test "Name is a single submit that writes exactly one entry and updates the page title",
         %{conn: conn, scope: scope, host: host} do
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{plus_one_status: :confirmed})
      before_count = length(LogQuery.for_entity(:person, plus_one.id))

      {:ok, view, html} = live(conn, ~p"/people/#{plus_one.id}")
      assert html =~ "+1 of Anna Peeters"
      assert has_element?(view, "#person-name-form")

      view
      |> form("#person-name-form", person: %{"first_name" => "Tom", "last_name" => "Wils"})
      |> render_submit()

      assert has_element?(view, "h1", "Tom Wils")
      refute has_element?(view, "#person-name-form")
      assert Guests.get_person!(plus_one.id).first_name == "Tom"
      assert length(LogQuery.for_entity(:person, plus_one.id)) == before_count + 1
    end

    test "editing a +1's age saves, but a posted want_tier is refused",
         %{conn: conn, scope: scope, host: host} do
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{plus_one_status: :confirmed})

      {:ok, view, _html} = live(conn, ~p"/people/#{plus_one.id}")

      view
      |> form("#person-form", person: %{"age_category" => "child"})
      |> render_submit()

      assert Guests.get_person!(plus_one.id).age_category == :child

      # The rendered form never has a want_tier input for a +1 — simulate a crafted
      # param bypassing the UI to prove the context itself refuses it (`PER-15`).
      render_submit(view, "save", %{"person" => %{"want_tier" => "no"}})

      assert Guests.get_person!(plus_one.id).want_tier == host.want_tier
    end

    test "a host's page lists its +1s and can add one", %{conn: conn, scope: scope, host: host} do
      {:ok, existing} = Guests.add_plus_one(scope, host, %{plus_one_status: :possible})

      {:ok, view, _html} = live(conn, ~p"/people/#{host.id}")

      assert has_element?(view, "#person-plus-ones")
      assert has_element?(view, "#person-plus-one-#{existing.id}")

      view
      |> form("#person-add-plus-one-form",
        person: %{
          "first_name" => "Tom",
          "last_name" => "Wils",
          "plus_one_status" => "confirmed",
          "age_category" => "adult"
        }
      )
      |> render_submit()

      plus_ones = Guests.get_person!(host.id).plus_ones
      assert length(plus_ones) == 2

      new_plus_one = Enum.find(plus_ones, &(&1.first_name == "Tom"))
      assert new_plus_one
      assert has_element?(view, "#person-plus-one-#{new_plus_one.id}", "Tom Wils")
    end

    test "the host's delete confirmation names the +1", %{conn: conn, scope: scope, host: host} do
      {:ok, plus_one} =
        Guests.add_plus_one(scope, host, %{
          first_name: "Tom",
          last_name: "Wils",
          plus_one_status: :confirmed
        })

      {:ok, view, _html} = live(conn, ~p"/people/#{host.id}")

      view |> element("#person-delete") |> render_click()

      assert has_element?(view, "#person-delete-confirm-affected", "Tom Wils")
      _ = plus_one
    end

    test "renaming the host re-renders an unnamed +1's page title live",
         %{conn: conn, scope: scope, host: host} do
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{plus_one_status: :confirmed})

      {:ok, view, _html} = live(conn, ~p"/people/#{plus_one.id}")
      assert has_element?(view, "h1", "+1 of Anna Peeters")

      {:ok, _updated} = Guests.update_person(scope, host, %{"first_name" => "Annelies"})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "h1", "+1 of Annelies Peeters")
      assert has_element?(view, "#person-host-link", "Annelies Peeters")
    end
  end

  # -- marginal cost (BUD-22, BUD-21, HC-08, HC-10, NFR-31, NFR-32, XC-01, DR-81, task 90) -

  describe "marginal cost" do
    setup %{scope: scope} do
      {:ok, event} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Kasteel Heers"})

      {:ok, _line} =
        Offers.create_line(scope, offer, %{
          "label" => "Dinner charge",
          "state" => "mandatory",
          "basis" => "per_attendee",
          "amount" => WeddingPlanner.Money.new(10),
          "event_id" => event.id
        })

      {:ok, offer} = Offers.confirm_offer(scope, offer)

      %{event: event, offer: offer}
    end

    test "a certain, invited host without a +1 collapses to one value under every preset; a likely one splits, Minimum excluding them",
         %{conn: conn, scope: scope, event: event} do
      {:ok, certain} =
        Guests.create_person(scope, %{
          first_name: "Anna",
          last_name: "Peeters",
          certainty: :certain
        })

      {:ok, _} = Invitations.set_invitation_status(scope, certain, event, :invited)

      {:ok, view, _html} = live(conn, ~p"/people/#{certain.id}")

      ten = Format.money(WeddingPlanner.Money.new(10))
      assert has_element?(view, "#person-marginal-cost-values-value", ten)

      assert has_element?(
               view,
               "#person-marginal-cost-caption",
               "How much the forecast would drop without Anna Peeters"
             )

      refute has_element?(view, "#person-marginal-cost-values-minimum")

      {:ok, likely} =
        Guests.create_person(scope, %{first_name: "Bram", last_name: "Wils", certainty: :likely})

      {:ok, _} = Invitations.set_invitation_status(scope, likely, event, :invited)

      {:ok, likely_view, _html} = live(conn, ~p"/people/#{likely.id}")

      zero = Format.money(WeddingPlanner.Money.new(0))
      refute has_element?(likely_view, "#person-marginal-cost-values-value")
      assert has_element?(likely_view, "#person-marginal-cost-values-minimum", zero)
      assert has_element?(likely_view, "#person-marginal-cost-values-likely", ten)
      assert has_element?(likely_view, "#person-marginal-cost-values-maximum", ten)
    end

    test "a certain host with a confirmed +1 removes both (€ 20,00, 'and their +1'); the +1's own page removes only itself (€ 10,00, 'this +1')",
         %{conn: conn, scope: scope, event: event} do
      {:ok, host} =
        Guests.create_person(scope, %{
          first_name: "Anna",
          last_name: "Peeters",
          certainty: :certain
        })

      {:ok, _} = Invitations.set_invitation_status(scope, host, event, :invited)
      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{plus_one_status: :confirmed})

      {:ok, host_view, _html} = live(conn, ~p"/people/#{host.id}")

      twenty = Format.money(WeddingPlanner.Money.new(20))
      assert has_element?(host_view, "#person-marginal-cost-values-value", twenty)
      assert has_element?(host_view, "#person-marginal-cost-caption", "and their +1")

      {:ok, plus_one_view, _html} = live(conn, ~p"/people/#{plus_one.id}")

      ten = Format.money(WeddingPlanner.Money.new(10))
      assert has_element?(plus_one_view, "#person-marginal-cost-values-value", ten)

      assert has_element?(
               plus_one_view,
               "#person-marginal-cost-caption",
               "How much the forecast would drop without this +1"
             )
    end

    test "an uninvited person shows € 0,00 under every preset and the 'not counted' caption",
         %{conn: conn, scope: scope} do
      {:ok, person} =
        Guests.create_person(scope, %{
          first_name: "Griet",
          last_name: "Peeters",
          certainty: :certain
        })

      {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")

      zero = Format.money(WeddingPlanner.Money.new(0))
      assert has_element?(view, "#person-marginal-cost-values-value", zero)

      assert has_element?(
               view,
               "#person-marginal-cost-caption",
               "Not counted for any event under these presets."
             )
    end

    test "the preset selector changes only the formula's own preset step (HC-10); a role-value button also selects that preset",
         %{conn: conn, scope: scope, event: event} do
      {:ok, likely} =
        Guests.create_person(scope, %{first_name: "Bram", last_name: "Wils", certainty: :likely})

      {:ok, _} = Invitations.set_invitation_status(scope, likely, event, :invited)

      minimum = Repo.get_by!(WeddingPlanner.Presets.HeadcountPreset, name: "Minimum")
      maximum = Repo.get_by!(WeddingPlanner.Presets.HeadcountPreset, name: "Maximum")

      {:ok, view, _html} = live(conn, ~p"/people/#{likely.id}")

      before_values = view |> element("#person-marginal-cost-values") |> render()

      view
      |> element("#person-marginal-cost-preset-form")
      |> render_change(%{"person-marginal-cost-preset-preset" => to_string(minimum.id)})

      after_values = view |> element("#person-marginal-cost-values") |> render()
      assert before_values == after_values
      assert has_element?(view, "#person-marginal-cost-formula-step-0", "Minimum")

      view |> element("#person-marginal-cost-values-maximum") |> render_click()

      assert has_element?(view, "#person-marginal-cost-formula-step-0", "Maximum")
      assert has_element?(view, "#person-marginal-cost-preset-option-#{maximum.id}[checked]")
    end

    test "inviting an uninvited person updates their own open page live; the offer line's amount then follows (FP-90b)",
         %{conn: conn, scope: scope, event: event, offer: offer} do
      {:ok, person} =
        Guests.create_person(scope, %{
          first_name: "Griet",
          last_name: "Peeters",
          certainty: :certain
        })

      {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")

      zero = Format.money(WeddingPlanner.Money.new(0))
      assert has_element?(view, "#person-marginal-cost-values-value", zero)

      {:ok, _} = Invitations.set_invitation_status(scope, person, event, :invited)

      render_async(view)
      ten = Format.money(WeddingPlanner.Money.new(10))
      assert has_element?(view, "#person-marginal-cost-values-value", ten)

      [line] = Offers.list_lines(offer)
      {:ok, _} = Offers.update_line(scope, line, %{"amount" => WeddingPlanner.Money.new(25)})

      render_async(view)
      twenty_five = Format.money(WeddingPlanner.Money.new(25))
      assert has_element?(view, "#person-marginal-cost-values-value", twenty_five)
    end

    test "the page's existing behaviour is intact: saving #person-form and changing an invitation select still work (FP-90d)",
         %{conn: conn, scope: scope, event: event} do
      {:ok, person} = Guests.create_person(scope, %{first_name: "Anna", last_name: "Peeters"})

      {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")

      view
      |> form("#person-form", person: %{"first_name" => "Anna", "last_name" => "Vermeulen"})
      |> render_submit()

      assert Guests.get_person!(person.id).last_name == "Vermeulen"

      view
      |> element("#person-invitation-#{event.id}-form")
      |> render_change(%{"event_id" => event.id, "status" => "accepted"})

      assert Invitations.statuses_for_person(Guests.get_person!(person.id))[event.id] == :accepted
    end

    test "the preset form and a role-value button each carry JS.push's own :loading target (fail-proof: drop :loading and this assertion fails)",
         %{conn: conn, scope: scope, event: event} do
      {:ok, likely} =
        Guests.create_person(scope, %{first_name: "Bram", last_name: "Wils", certainty: :likely})

      {:ok, _} = Invitations.set_invitation_status(scope, likely, event, :invited)

      {:ok, view, _html} = live(conn, ~p"/people/#{likely.id}")

      # The exact JSON `JS.push/2` encodes for `:loading`, HTML-escaped as it appears in
      # the rendered attribute — the same `/budget` idiom (`BudgetLiveTest`'s own
      # "carry JS.push's own :loading target" test).
      loading_json =
        ~s(loading&quot;:&quot;#person-marginal-cost-formula, #person-marginal-cost-updating&quot;)

      form_html = view |> element("#person-marginal-cost-preset-form") |> render()
      assert form_html =~ loading_json

      button_html = view |> element("#person-marginal-cost-values-likely") |> render()
      assert button_html =~ loading_json

      # The client-side "Updating…" twin is in the page while idle, hidden until the JS
      # client puts a phx-*-loading class on it.
      assert has_element?(view, "#person-marginal-cost-updating.hidden.phx-click-loading\\:flex")
    end

    test "no rendered 'false' text node anywhere in the marginal cost section",
         %{conn: conn, scope: scope, event: event} do
      {:ok, host} =
        Guests.create_person(scope, %{
          first_name: "Anna",
          last_name: "Peeters",
          certainty: :certain
        })

      {:ok, _} = Invitations.set_invitation_status(scope, host, event, :invited)
      {:ok, _plus_one} = Guests.add_plus_one(scope, host, %{plus_one_status: :confirmed})

      {:ok, view, _html} = live(conn, ~p"/people/#{host.id}")

      refute view |> element("#person-marginal-cost") |> render() =~ ">false<"
    end
  end

  describe "What if… entry point (task 89, DR-82)" do
    test "a host's page links to /what-if with their own id", %{conn: conn, scope: scope} do
      {:ok, person} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")
      assert has_element?(view, "#person-what-if")

      {:ok, what_if_view, _html} =
        view |> element("#person-what-if") |> render_click() |> follow_redirect(conn)

      assert has_element?(what_if_view, "#what-if-person-#{person.id}")
    end

    test "a +1's page links to /what-if with its host's id (PER-13)", %{conn: conn, scope: scope} do
      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{"plus_one_status" => "confirmed"})

      {:ok, view, _html} = live(conn, ~p"/people/#{plus_one.id}")

      {:ok, what_if_view, _html} =
        view |> element("#person-what-if") |> render_click() |> follow_redirect(conn)

      assert has_element?(what_if_view, "#what-if-person-#{host.id}")
      refute has_element?(what_if_view, "#what-if-person-#{plus_one.id}")
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
