defmodule WeddingPlannerWeb.Live.InvitationsLiveTest do
  @moduledoc """
  `docs/modules/guests-and-events.md` `INVT-01`–`INVT-04`, `PER-04`, `PER-13`, `PER-14`,
  `docs/04-cross-cutting.md` `XC-01`, `XC-40` — the `/invitations` matrix LiveView
  (task 45), on top of task 44's `WeddingPlanner.Invitations` context and
  `WeddingPlanner.Invitations.Matrix` (see `WeddingPlanner.Invitations.MatrixTest` for
  the pure row-building coverage — this file is the LiveView wiring on top of it).
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Events
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Log.Query, as: LogQuery
  alias WeddingPlanner.Repo

  setup %{conn: conn} do
    user = insert_user!("Wannes")
    %{conn: log_in_user(conn, user), user: user, scope: Scope.for_user(user)}
  end

  describe "authentication" do
    test "an unauthenticated request redirects to /login" do
      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, ~p"/invitations")

      assert redirected_to(conn) == "/login?return_to=%2Finvitations"
    end
  end

  describe "nav" do
    test "the nav has an Invitations entry right after People", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invitations")

      html = render(view)
      {people_pos, _} = :binary.match(html, "id=\"nav-people\"")
      {invitations_pos, _} = :binary.match(html, "id=\"nav-invitations\"")
      {events_pos, _} = :binary.match(html, "id=\"nav-events\"")

      assert people_pos < invitations_pos
      assert invitations_pos < events_pos
      assert has_element?(view, "#nav-invitations a", "Invitations")
    end
  end

  describe "empty state" do
    test "shows an empty state and a 0 of 0 shown count", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/invitations")

      assert html =~ "Invitations"
      assert has_element?(view, "#invitations-empty")
      assert has_element?(view, "#invitations-shown-count", "0 of 0 shown")
    end
  end

  describe "a single cell change (INVT-01, DR-38)" do
    test "persists across a reload and logs, no confirmation needed", %{
      conn: conn,
      scope: scope
    } do
      {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner"})

      {:ok, anna} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, view, _html} = live(conn, ~p"/invitations")

      refute has_element?(view, "#cell-#{anna.id}-#{dinner.id}-confirm")

      view
      |> form("#cell-#{anna.id}-#{dinner.id}-form", %{"status" => "accepted"})
      |> render_change()

      assert has_element?(view, "#cell-#{anna.id}-#{dinner.id} option[selected]", "Accepted")

      entries = LogQuery.for_entity(:person, anna.id)
      assert Enum.any?(entries, &(&1.description =~ "accepted"))

      {:ok, reloaded, _html} = live(conn, ~p"/invitations")
      assert has_element?(reloaded, "#cell-#{anna.id}-#{dinner.id} option[selected]", "Accepted")
    end

    test "a broadcast from another process updates the view live", %{conn: conn, scope: scope} do
      {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner"})

      {:ok, anna} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, view, _html} = live(conn, ~p"/invitations")

      {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :accepted)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#cell-#{anna.id}-#{dinner.id} option[selected]", "Accepted")
    end

    test "events render as columns in EVT-04 manual sort order, not date order", %{
      conn: conn,
      scope: scope
    } do
      {:ok, reception} =
        Events.create_event(scope, %{"name" => "Reception", "date" => "2028-05-14"})

      {:ok, ceremony} =
        Events.create_event(scope, %{"name" => "Ceremony", "date" => "2028-05-13"})

      {:ok, _view, html} = live(conn, ~p"/invitations")

      {reception_pos, _} = :binary.match(html, reception.name)
      {ceremony_pos, _} = :binary.match(html, ceremony.name)
      assert reception_pos < ceremony_pos
    end
  end

  describe "+1 rows (PER-13, PER-14, DR-34)" do
    setup %{scope: scope} do
      {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner"})

      {:ok, anna} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, plus_one} =
        Guests.add_plus_one(scope, anna, %{
          first_name: "Tomas",
          last_name: "Verlinden",
          plus_one_status: :confirmed
        })

      %{dinner: dinner, anna: anna, plus_one: plus_one}
    end

    test "hidden until the host's chevron is toggled, then rendered directly under it", %{
      conn: conn,
      dinner: dinner,
      anna: anna,
      plus_one: plus_one
    } do
      {:ok, view, _html} = live(conn, ~p"/invitations")

      refute has_element?(view, "#cell-#{plus_one.id}-#{dinner.id}")

      view |> element("#plus-one-toggle-#{anna.id}") |> render_click()

      assert has_element?(view, "#unit-#{anna.id} #cell-#{plus_one.id}-#{dinner.id}")
    end

    test "shows 'Following host (status)' and opting out calls the real opt-out path", %{
      conn: conn,
      scope: scope,
      dinner: dinner,
      anna: anna,
      plus_one: plus_one
    } do
      {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :accepted)

      {:ok, view, _html} = live(conn, ~p"/invitations")
      view |> element("#plus-one-toggle-#{anna.id}") |> render_click()

      assert has_element?(
               view,
               "#cell-#{plus_one.id}-#{dinner.id} option[selected]",
               "Following host (Accepted)"
             )

      view
      |> form("#cell-#{plus_one.id}-#{dinner.id}-form", %{"opt_out" => "opted_out"})
      |> render_change()

      assert has_element?(view, "#cell-#{plus_one.id}-#{dinner.id} option[selected]", "Opted out")
      assert Invitations.opted_out_event_ids(plus_one) == MapSet.new([dinner.id])
    end

    test "host set to declined re-renders the +1's 'Following host' label (re-inserted unit)",
         %{conn: conn, scope: scope, dinner: dinner, anna: anna} do
      {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :accepted)

      {:ok, view, _html} = live(conn, ~p"/invitations")
      view |> element("#plus-one-toggle-#{anna.id}") |> render_click()

      # Asserted on `render_change/1`'s own return value, not a later `has_element?/2,3`
      # call: `set_invitation_status/4` also broadcasts on `:invitation`, which this same
      # LiveView subscribes to and reacts to with a full `refresh/1` — a later query
      # against the view could pass on that redundant broadcast-triggered refresh alone,
      # masking a missing `refresh_after_cell_change/2` re-insert (see the fail-proofs in
      # `.claude/tasks/45-invitation-matrix-screen.md`). `render_change/1`'s return is the
      # diff for *this* message only, computed and replied before the process loops
      # around to the separately-queued self-broadcast message.
      html =
        view
        |> form("#cell-#{anna.id}-#{dinner.id}-form", %{"status" => "declined"})
        |> render_change()

      assert html =~ "Following host (Declined)"
    end
  end

  describe "filters (INVT-04)" do
    test "the name filter narrows the matrix and updates the shown count", %{
      conn: conn,
      scope: scope
    } do
      {:ok, anna} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, ben} = Guests.create_person(scope, %{"first_name" => "Ben", "last_name" => "Aerts"})

      {:ok, view, _html} = live(conn, ~p"/invitations")
      assert has_element?(view, "#invitations-shown-count", "2 of 2 shown")

      view |> form("#invitations-filter", filter: %{"text" => "anna"}) |> render_change()

      assert has_element?(view, "#invitations-shown-count", "1 of 2 shown")
      assert has_element?(view, "#unit-#{anna.id}")
      refute has_element?(view, "#unit-#{ben.id}")
    end

    test "want tier maybe + status for event narrows to the B-list", %{
      conn: conn,
      scope: scope
    } do
      {:ok, reception} = Events.create_event(scope, %{"name" => "Reception"})

      {:ok, not_invited} =
        Guests.create_person(scope, %{
          "first_name" => "NotInvited",
          "last_name" => "Maybe",
          "want_tier" => "maybe"
        })

      {:ok, invited} =
        Guests.create_person(scope, %{
          "first_name" => "Invited",
          "last_name" => "Maybe",
          "want_tier" => "maybe"
        })

      {:ok, _} = Invitations.set_invitation_status(scope, invited, reception, :invited)

      {:ok, view, _html} = live(conn, ~p"/invitations")

      view
      |> form("#invitations-filter",
        filter: %{
          "want_tier" => "maybe",
          "event_id" => to_string(reception.id),
          "status" => "not_invited"
        }
      )
      |> render_change()

      assert has_element?(view, "#unit-#{not_invited.id}")
      refute has_element?(view, "#unit-#{invited.id}")
    end
  end

  describe "flat vs grouped (DR-39)" do
    test "grouped is the default; the toggle switches to flat and back", %{
      conn: conn,
      scope: scope
    } do
      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      {:ok, anna} =
        Guests.create_person(scope, %{
          "first_name" => "Anna",
          "last_name" => "Peeters",
          "group_id" => group.id
        })

      {:ok, view, _html} = live(conn, ~p"/invitations")
      assert has_element?(view, "#group-#{group.id}")
      assert has_element?(view, "#unit-#{anna.id}")

      view |> element("#invitations-grouping-toggle") |> render_click()

      refute has_element?(view, "#group-#{group.id}")
      assert has_element?(view, "#unit-#{anna.id}")

      view |> element("#invitations-grouping-toggle") |> render_click()
      assert has_element?(view, "#group-#{group.id}")
    end
  end

  describe "group bulk action (PER-04, DR-38, DR-39, XC-40)" do
    test "confirmation names the changing count and overwritten RSVPs, apply updates every shown member, +1s untouched",
         %{conn: conn, scope: scope} do
      {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner"})
      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      {:ok, anna} =
        Guests.create_person(scope, %{
          "first_name" => "Anna",
          "last_name" => "Peeters",
          "group_id" => group.id
        })

      {:ok, ben} =
        Guests.create_person(scope, %{
          "first_name" => "Ben",
          "last_name" => "Peeters",
          "group_id" => group.id
        })

      {:ok, plus_one} =
        Guests.add_plus_one(scope, anna, %{
          first_name: "Tomas",
          last_name: "Verlinden",
          plus_one_status: :confirmed
        })

      {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :accepted)

      {:ok, view, _html} = live(conn, ~p"/invitations")

      view
      |> form("#group-bulk-#{group.id}", %{
        "event_id" => to_string(dinner.id),
        "status" => "invited"
      })
      |> render_submit()

      assert has_element?(
               view,
               "#group-bulk-confirm-#{group.id}-title",
               "Set 2 people in Family Peeters to Invited for Dinner?"
             )

      assert has_element?(
               view,
               "#group-bulk-confirm-#{group.id}",
               ~r/1 RSVP will be overwritten/
             )

      view |> element("#group-bulk-confirm-#{group.id}-confirm") |> render_click()

      refute has_element?(view, "#group-bulk-confirm-#{group.id}")
      assert has_element?(view, "#cell-#{anna.id}-#{dinner.id} option[selected]", "Invited")
      assert has_element?(view, "#cell-#{ben.id}-#{dinner.id} option[selected]", "Invited")
      assert Invitations.statuses_for_person(plus_one) == %{}
    end

    test "the Ungrouped section has no bulk control", %{conn: conn, scope: scope} do
      {:ok, _anna} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, view, _html} = live(conn, ~p"/invitations")

      assert has_element?(view, "#group-ungrouped")
      refute has_element?(view, "#group-bulk-ungrouped")
    end

    test "cancelling the confirmation writes nothing", %{conn: conn, scope: scope} do
      {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner"})
      {:ok, group} = Guests.create_group(scope, %{"name" => "Family Peeters"})

      {:ok, anna} =
        Guests.create_person(scope, %{
          "first_name" => "Anna",
          "last_name" => "Peeters",
          "group_id" => group.id
        })

      {:ok, view, _html} = live(conn, ~p"/invitations")

      view
      |> form("#group-bulk-#{group.id}", %{
        "event_id" => to_string(dinner.id),
        "status" => "invited"
      })
      |> render_submit()

      view |> element("#group-bulk-confirm-#{group.id}-cancel") |> render_click()

      refute has_element?(view, "#group-bulk-confirm-#{group.id}")
      assert has_element?(view, "#cell-#{anna.id}-#{dinner.id} option[selected]", "Not invited")
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
