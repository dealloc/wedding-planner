defmodule WeddingPlannerWeb.Live.EventsLiveTest do
  @moduledoc """
  `docs/modules/guests-and-events.md` EVT-01 through EVT-05, `NFR-20`, `XC-01`, `XC-10`,
  `XC-40` — the events LiveView, the exemplar vertical slice's UI layer.
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Events
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks

  setup %{conn: conn} do
    user = insert_user!("Wannes")
    %{conn: log_in_user(conn, user), user: user, scope: Scope.for_user(user)}
  end

  describe "authentication" do
    test "an unauthenticated request redirects to /login" do
      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, ~p"/events")

      assert redirected_to(conn) == "/login?return_to=%2Fevents"
    end
  end

  describe "index" do
    test "shows an empty state when there are no events yet", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/events")

      assert html =~ "Events"
      assert has_element?(view, "#events-empty")
    end

    test "the nav has one Events entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/events")

      assert has_element?(view, "#nav-events a", "Events")
    end

    test "renders in manual sort order, not date order (EVT-04)", %{conn: conn, scope: scope} do
      {:ok, reception} =
        Events.create_event(scope, %{"name" => "Reception", "date" => "2028-05-14"})

      {:ok, ceremony} =
        Events.create_event(scope, %{"name" => "Ceremony", "date" => "2028-05-13"})

      {:ok, _view, html} = live(conn, ~p"/events")

      {reception_pos, _} = :binary.match(html, "event-#{reception.id}-name")
      {ceremony_pos, _} = :binary.match(html, "event-#{ceremony.id}-name")
      assert reception_pos < ceremony_pos
    end

    test "an event with no date shows the explicit placeholder, not a blank cell (EVT-03)", %{
      conn: conn,
      scope: scope
    } do
      {:ok, event} = Events.create_event(scope, %{"name" => "Ceremony"})

      {:ok, view, _html} = live(conn, ~p"/events")

      assert has_element?(view, "#event-#{event.id}-date", "No date yet")
      refute has_element?(view, "#event-#{event.id}-date.tabular-nums")
    end

    test "a dated event shows dd/mm/yyyy, with no shift (NFR-20, NFR-23)", %{
      conn: conn,
      scope: scope
    } do
      {:ok, event} =
        Events.create_event(scope, %{"name" => "Reception", "date" => "2028-05-13"})

      {:ok, view, _html} = live(conn, ~p"/events")

      assert has_element?(view, "#event-#{event.id}-date", "13/05/2028")
      assert has_element?(view, "#event-#{event.id}-date.tabular-nums")
    end
  end

  describe "create (EVT-01, EVT-03)" do
    test "creating without a date succeeds and lands back on the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/events/new")

      form = form(view, "#event-form", event: %{"name" => "Ceremony"})
      {:ok, index_view, _html} = form |> render_submit() |> follow_redirect(conn)

      assert has_element?(index_view, "#events li", "Ceremony")
      assert has_element?(index_view, "#events", "No date yet")
    end

    test "creating with a date shows it formatted dd/mm/yyyy afterwards", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/events/new")

      form =
        form(view, "#event-form", event: %{"name" => "Reception", "date" => "2028-05-13"})

      {:ok, index_view, _html} = form |> render_submit() |> follow_redirect(conn)

      assert has_element?(index_view, "#events", "13/05/2028")
    end

    test "a blank name is rejected with an inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/events/new")

      html =
        view
        |> form("#event-form", event: %{"name" => ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert has_element?(view, "#event-form")
    end
  end

  describe "edit" do
    setup %{scope: scope} do
      {:ok, event} = Events.create_event(scope, %{"name" => "Dinner"})
      %{event: event}
    end

    test "updates the event and shows the change on the list", %{conn: conn, event: event} do
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/edit")

      form =
        form(view, "#event-form",
          event: %{"name" => "Dinner", "location" => "Garden Hall", "date" => "2028-05-13"}
        )

      {:ok, index_view, _html} = form |> render_submit() |> follow_redirect(conn)

      assert has_element?(index_view, "#events", "Garden Hall")
      assert has_element?(index_view, "#events", "13/05/2028")
    end

    test "shows this event's own activity history, updating live", %{
      conn: conn,
      event: event,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/edit")

      assert has_element?(view, "#event-history", "created event 'Dinner'")

      {:ok, _updated} = Events.update_event(scope, event, %{"location" => "Garden Hall"})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#event-history", "changed the location")
    end
  end

  describe "reordering (EVT-04)" do
    setup %{scope: scope} do
      {:ok, a} = Events.create_event(scope, %{"name" => "A"})
      {:ok, b} = Events.create_event(scope, %{"name" => "B"})
      %{a: a, b: b}
    end

    test "moving an event up persists across a fresh mount", %{conn: conn, a: a, b: b} do
      {:ok, view, _html} = live(conn, ~p"/events")

      view |> element("#event-#{b.id}-move-up") |> render_click()

      {b_pos, _} = :binary.match(render(view), "event-#{b.id}-name")
      {a_pos, _} = :binary.match(render(view), "event-#{a.id}-name")
      assert b_pos < a_pos

      # A brand new mount (simulating a reload) reflects the persisted order.
      {:ok, fresh_view, _html} = live(conn, ~p"/events")
      html = render(fresh_view)
      {b_pos2, _} = :binary.match(html, "event-#{b.id}-name")
      {a_pos2, _} = :binary.match(html, "event-#{a.id}-name")
      assert b_pos2 < a_pos2
    end

    test "the first row's move-up control is disabled", %{conn: conn, a: a} do
      {:ok, view, _html} = live(conn, ~p"/events")

      # Match the boolean attribute, not the text: "disabled" also appears in the
      # button's Tailwind classes (`disabled:cursor-not-allowed`), so `=~` always passed.
      assert has_element?(view, "#event-#{a.id}-move-up[disabled]")
    end

    test "the last row's move-down control is disabled", %{conn: conn, b: b} do
      {:ok, view, _html} = live(conn, ~p"/events")

      # Match the boolean attribute, not the text: "disabled" also appears in the
      # button's Tailwind classes (`disabled:cursor-not-allowed`), so `=~` always passed.
      assert has_element?(view, "#event-#{b.id}-move-down[disabled]")
    end
  end

  describe "delete (EVT-05, XC-40)" do
    setup %{scope: scope} do
      {:ok, event} = Events.create_event(scope, %{"name" => "Reception"})
      %{event: event}
    end

    test "requires confirmation before deleting", %{conn: conn, event: event} do
      {:ok, view, _html} = live(conn, ~p"/events")

      refute has_element?(view, "#event-#{event.id}-delete-confirm")

      view |> element("#event-#{event.id}-delete") |> render_click()
      assert has_element?(view, "#event-#{event.id}-delete-confirm")

      # The event is still there — clicking Delete alone must not delete it.
      assert Events.get_event!(event.id)
    end

    test "the confirmation states what else is affected", %{conn: conn, event: event} do
      {:ok, view, _html} = live(conn, ~p"/events")

      view |> element("#event-#{event.id}-delete") |> render_click()

      assert has_element?(
               view,
               "#event-#{event.id}-delete-confirm-affected",
               "Nothing else references this yet."
             )
    end

    test "cancelling leaves the event in place", %{conn: conn, event: event} do
      {:ok, view, _html} = live(conn, ~p"/events")

      view |> element("#event-#{event.id}-delete") |> render_click()
      view |> element("#event-#{event.id}-delete-confirm-cancel") |> render_click()

      refute has_element?(view, "#event-#{event.id}-delete-confirm")
      assert has_element?(view, "#event-#{event.id}-name")
    end

    test "confirming deletes the event and removes its row", %{conn: conn, event: event} do
      {:ok, view, _html} = live(conn, ~p"/events")

      view |> element("#event-#{event.id}-delete") |> render_click()
      view |> element("#event-#{event.id}-delete-confirm-confirm") |> render_click()

      refute has_element?(view, "#event-#{event.id}-name")
      assert_raise Ecto.NoResultsError, fn -> Events.get_event!(event.id) end
    end

    test "the delete still writes an activity entry, visible on /activity", %{
      conn: conn,
      event: event
    } do
      {:ok, view, _html} = live(conn, ~p"/events")

      view |> element("#event-#{event.id}-delete") |> render_click()
      view |> element("#event-#{event.id}-delete-confirm-confirm") |> render_click()

      {:ok, activity_view, _html} = live(conn, ~p"/activity")
      assert has_element?(activity_view, "#activity-log", "deleted event 'Reception'")
    end

    test "with a reference of every kind (DR-85), the confirmation lists all five", %{
      conn: conn,
      scope: scope
    } do
      {:ok, event} = Events.create_event(scope, %{"name" => "Brunch"})

      {:ok, _anchored} =
        Tasks.create_task(scope, %{
          "title" => "Send invitations",
          "deadline_kind" => "relative",
          "deadline_amount" => "2",
          "deadline_unit" => "weeks",
          "deadline_direction" => "before",
          "deadline_event_id" => event.id
        })

      {:ok, _linked} =
        Tasks.create_task(scope, %{"title" => "Book florist", "link_event_id" => event.id})

      {:ok, host} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, plus_one} = Guests.add_plus_one(scope, host, %{})
      {:ok, _invitation} = Invitations.set_invitation_status(scope, host, event, :accepted)
      {:ok, _opt_out} = Invitations.set_opt_out(scope, plus_one, event, true)

      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, service} = Categories.create_service(scope, category, %{"name" => "Catering"})
      {:ok, offer} = Offers.create_offer(scope, category, %{"vendor_name" => "Venue A"})

      {:ok, _line} =
        Offers.create_line(scope, offer, %{
          "service_id" => service.id,
          "state" => "mandatory",
          "basis" => "per_adult",
          "event_id" => event.id,
          "amount_input" => "85"
        })

      {:ok, view, _html} = live(conn, ~p"/events")

      view |> element("#event-#{event.id}-delete") |> render_click()

      affected_html = view |> element("#event-#{event.id}-delete-confirm-affected") |> render()

      assert affected_html =~
               "1 task with a deadline relative to this event (deadline becomes none)"

      assert affected_html =~ "1 task linked to this event (link removed)"
      assert affected_html =~ "1 invitation"
      assert affected_html =~ "1 +1 opt-out"
      assert affected_html =~ "1 offer line (it becomes invalid)"

      view |> element("#event-#{event.id}-delete-confirm-confirm") |> render_click()

      refute has_element?(view, "#event-#{event.id}-name")
      assert_raise Ecto.NoResultsError, fn -> Events.get_event!(event.id) end
    end
  end

  describe "live updates (XC-01)" do
    test "a second session sees a newly created event without a refresh", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      {:ok, view_a, _html} = live(conn, ~p"/events")
      {:ok, view_b, _html} = live(log_in_user(build_conn(), user), ~p"/events")

      refute render(view_a) =~ "Ceremony"
      refute render(view_b) =~ "Ceremony"

      {:ok, event} = Events.create_event(scope, %{"name" => "Ceremony"})
      _ = :sys.get_state(view_a.pid)
      _ = :sys.get_state(view_b.pid)

      assert has_element?(view_a, "#event-#{event.id}-name", "Ceremony")
      assert has_element?(view_b, "#event-#{event.id}-name", "Ceremony")
    end

    test "a second session sees a deletion without a refresh", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      {:ok, event} = Events.create_event(scope, %{"name" => "Ceremony"})

      {:ok, view_a, _html} = live(conn, ~p"/events")
      {:ok, view_b, _html} = live(log_in_user(build_conn(), user), ~p"/events")

      assert has_element?(view_b, "#event-#{event.id}-name")

      view_a |> element("#event-#{event.id}-delete") |> render_click()
      view_a |> element("#event-#{event.id}-delete-confirm-confirm") |> render_click()
      _ = :sys.get_state(view_b.pid)

      refute has_element?(view_b, "#event-#{event.id}-name")
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
