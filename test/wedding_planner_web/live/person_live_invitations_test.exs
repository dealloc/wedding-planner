defmodule WeddingPlannerWeb.Live.PersonLiveInvitationsTest do
  @moduledoc """
  `docs/modules/guests-and-events.md` `INVT-01`–`04`, `PER-13`, `PER-14`, `EVT-04`,
  `docs/04-cross-cutting.md` `XC-01`, `XC-11`, `XC-40`, `docs/05-non-functional.md`
  `NFR-31` — the person page's "Invitations" section and +1 opt-outs (task 46,
  `DR-37`–`DR-39`).
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Events
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Repo

  setup %{conn: conn} do
    user = insert_user!("Wannes")
    %{conn: log_in_user(conn, user), user: user, scope: Scope.for_user(user)}
  end

  describe "a regular person's invitation status (INVT-01)" do
    setup %{scope: scope} do
      {:ok, anna} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner"})
      %{anna: anna, dinner: dinner}
    end

    test "defaults to 'Not invited' with no row yet", %{conn: conn, anna: anna, dinner: dinner} do
      {:ok, view, _html} = live(conn, ~p"/people/#{anna.id}")

      assert has_element?(
               view,
               "#person-invitation-#{dinner.id} option[selected]",
               "Not invited"
             )
    end

    test "changing the select persists the status, survives a reload, and logs one entry",
         %{conn: conn, anna: anna, dinner: dinner} do
      {:ok, view, _html} = live(conn, ~p"/people/#{anna.id}")

      view
      |> form("#person-invitation-#{dinner.id}-form", %{"status" => "accepted"})
      |> render_change()

      assert Invitations.statuses_for_person(anna) == %{dinner.id => :accepted}
      assert has_element?(view, "#person-invitation-#{dinner.id} option[selected]", "Accepted")
      assert has_element?(view, "#person-history", "changed the invitation")

      {:ok, view2, _html2} = live(conn, ~p"/people/#{anna.id}")
      assert has_element?(view2, "#person-invitation-#{dinner.id} option[selected]", "Accepted")
    end

    test "choosing 'Not invited' removes the stored row and survives a reload",
         %{conn: conn, scope: scope, anna: anna, dinner: dinner} do
      {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :invited)
      {:ok, view, _html} = live(conn, ~p"/people/#{anna.id}")
      assert has_element?(view, "#person-invitation-#{dinner.id} option[selected]", "Invited")

      view
      |> form("#person-invitation-#{dinner.id}-form", %{"status" => "not_invited"})
      |> render_change()

      assert Invitations.statuses_for_person(anna) == %{}

      {:ok, view2, _html2} = live(conn, ~p"/people/#{anna.id}")

      assert has_element?(
               view2,
               "#person-invitation-#{dinner.id} option[selected]",
               "Not invited"
             )
    end
  end

  describe "a +1's derived status (PER-13, PER-14)" do
    setup %{scope: scope} do
      {:ok, anna} =
        Guests.create_person(scope, %{"first_name" => "Anna", "last_name" => "Peeters"})

      {:ok, plus_one} = Guests.add_plus_one(scope, anna, %{plus_one_status: :confirmed})
      {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner"})
      %{anna: anna, plus_one: plus_one, dinner: dinner}
    end

    test "shows 'Following host (Accepted)' when the host accepted, no opt-out",
         %{conn: conn, scope: scope, anna: anna, plus_one: plus_one, dinner: dinner} do
      {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :accepted)

      {:ok, view, _html} = live(conn, ~p"/people/#{plus_one.id}")

      assert has_element?(
               view,
               "#person-invitation-#{dinner.id} option[selected]",
               "Following host (Accepted)"
             )

      refute Invitations.opted_out_event_ids(plus_one) |> MapSet.member?(dinner.id)
    end

    # `PER-14`: a decline propagates to the +1 regardless of any opt-out — this is also
    # this task's specified fail-proof: reading the +1's own (nonexistent) invitation
    # instead of `Effective.status/3` off the host would show "Not invited" here
    # instead of "Declined", since `Invitations.statuses_for_person/1` always returns
    # `%{}` for a +1.
    test "shows 'Following host (Declined)' when the host declined, with no opt-out",
         %{conn: conn, scope: scope, anna: anna, plus_one: plus_one, dinner: dinner} do
      {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :declined)

      {:ok, view, _html} = live(conn, ~p"/people/#{plus_one.id}")

      assert has_element?(
               view,
               "#person-invitation-#{dinner.id} option[selected]",
               "Following host (Declined)"
             )

      refute Invitations.opted_out_event_ids(plus_one) |> MapSet.member?(dinner.id)
    end

    test "choosing 'Opted out' persists and survives a reload",
         %{conn: conn, scope: scope, anna: anna, plus_one: plus_one, dinner: dinner} do
      {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :accepted)
      {:ok, view, _html} = live(conn, ~p"/people/#{plus_one.id}")

      view
      |> form("#person-invitation-#{dinner.id}-form", %{"opt_out" => "opted_out"})
      |> render_change()

      assert Invitations.opted_out_event_ids(plus_one) == MapSet.new([dinner.id])
      assert has_element?(view, "#person-invitation-#{dinner.id} option[selected]", "Opted out")

      {:ok, view2, _html2} = live(conn, ~p"/people/#{plus_one.id}")
      assert has_element?(view2, "#person-invitation-#{dinner.id} option[selected]", "Opted out")
    end

    test "the host's status change updates the +1's already-open page live (XC-01)",
         %{conn: conn, scope: scope, anna: anna, plus_one: plus_one, dinner: dinner} do
      {:ok, view, _html} = live(conn, ~p"/people/#{plus_one.id}")

      assert has_element?(
               view,
               "#person-invitation-#{dinner.id} option[selected]",
               "Following host (Not invited)"
             )

      {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :accepted)
      _ = :sys.get_state(view.pid)

      assert has_element?(
               view,
               "#person-invitation-#{dinner.id} option[selected]",
               "Following host (Accepted)"
             )
    end
  end

  describe "events render in manual sort order, not alphabetical (EVT-04)" do
    test "a later-created, alphabetically-earlier event still renders after an earlier one",
         %{conn: conn, scope: scope} do
      {:ok, anna} = Guests.create_person(scope, %{"first_name" => "Anna"})
      {:ok, _zebra} = Events.create_event(scope, %{"name" => "Zebra Party"})
      {:ok, _alpha} = Events.create_event(scope, %{"name" => "Alpha Party"})

      {:ok, _view, html} = live(conn, ~p"/people/#{anna.id}")

      {zebra_index, _} = :binary.match(html, "Zebra Party")
      {alpha_index, _} = :binary.match(html, "Alpha Party")

      assert zebra_index < alpha_index
    end
  end

  describe "empty state (no events yet)" do
    test "shows a link to /events", %{conn: conn, scope: scope} do
      {:ok, anna} = Guests.create_person(scope, %{"first_name" => "Anna"})

      {:ok, view, _html} = live(conn, ~p"/people/#{anna.id}")

      assert has_element?(view, "#person-invitations a", "Add one")
    end
  end

  describe "the delete confirmation names invitations removed (XC-40, DR-38)" do
    test "lists 'Also removes 1 invitation'", %{conn: conn, scope: scope} do
      {:ok, anna} = Guests.create_person(scope, %{"first_name" => "Anna"})
      {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner"})
      {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :invited)

      {:ok, view, _html} = live(conn, ~p"/people/#{anna.id}")

      view |> element("#person-delete") |> render_click()

      assert has_element?(view, "#person-delete-confirm-affected", "Also removes 1 invitation")
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
