defmodule WeddingPlannerWeb.Live.DevicesLiveTest do
  @moduledoc """
  `AUTH-08`, `AUTH-11`, `XC-40`, `DR-24` — the `/devices` screen: listing a user's own
  passkeys with name/registration/last-used, in-place renaming, revocation with
  confirmation, the disabled last-passkey control, the server-side guard against a
  crafted event bypassing it, per-user scoping, and the self-revocation sign-out.

  `async: false`, matching `WeddingPlanner.Accounts.SessionsTest`'s own note: this
  repo's suite occasionally hits "database busy" under the default test concurrency, and
  `WeddingPlanner.Accounts.Passkeys.revoke/2`'s `mode: :immediate` transaction is exactly
  the kind of write-heavy path that note calls out.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.Sessions
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Repo

  @epoch ~U[2026-09-01 12:00:00Z]

  describe "authentication" do
    test "an unauthenticated request redirects to /login" do
      # Setup (AUTH-03) is only bypassed to /login once a user exists — mirrors
      # `EventsLiveTest`'s own equivalent test.
      insert_user!("Wannes")

      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, ~p"/devices")

      assert redirected_to(conn) == "/login?return_to=%2Fdevices"
    end
  end

  describe "the nav" do
    test "has one Devices entry", %{conn: conn} do
      user = insert_user!("Wannes")
      conn = log_in_user(conn, user)
      insert_passkey!(user, "Only one", @epoch)

      {:ok, view, _html} = live(conn, ~p"/devices")

      assert has_element?(view, "#nav-devices a", "Devices")
    end
  end

  describe "listing (AUTH-08)" do
    test "shows each passkey's name, registration date and 'Never' when unused", %{conn: conn} do
      user = insert_user!("Wannes")
      conn = log_in_user(conn, user)
      pk = insert_passkey!(user, "Wannes' phone", @epoch)

      {:ok, view, _html} = live(conn, ~p"/devices")

      assert has_element?(view, "#passkey-#{pk.id}-name")
      registered = view |> element("#passkey-#{pk.id}-registered") |> render()
      assert registered =~ "01/09/2026"

      last_used = view |> element("#passkey-#{pk.id}-last-used") |> render()
      assert last_used =~ "Never"
    end

    test "shows the last-used date, dd/mm/yyyy (NFR-23), once the passkey has been used", %{
      conn: conn
    } do
      user = insert_user!("Wannes")
      conn = log_in_user(conn, user)
      pk = insert_passkey!(user, "Wannes' phone", @epoch)

      used_at = ~U[2026-09-15 08:00:00Z]
      {:ok, pk} = pk |> Passkey.usage_changeset(3, used_at) |> Repo.update()

      {:ok, view, _html} = live(conn, ~p"/devices")

      last_used = view |> element("#passkey-#{pk.id}-last-used") |> render()
      assert last_used =~ "15/09/2026"
      refute last_used =~ "Never"
    end

    test "only the signed-in user's own passkeys are listed (AUTH-08)", %{conn: conn} do
      user = insert_user!("Wannes")
      other = insert_user!("Partner")
      conn = log_in_user(conn, user)

      mine = insert_passkey!(user, "Mine", @epoch)
      theirs = insert_passkey!(other, "Not mine", @epoch)

      {:ok, view, _html} = live(conn, ~p"/devices")

      assert has_element?(view, "#passkey-#{mine.id}-name")
      refute has_element?(view, "#passkey-#{theirs.id}-name")
    end
  end

  describe "renaming (AUTH-08, AUTH-11)" do
    test "persists the new name in place and logs it", %{conn: conn} do
      user = insert_user!("Wannes")
      conn = log_in_user(conn, user)
      pk = insert_passkey!(user, "New passkey", @epoch)

      {:ok, view, _html} = live(conn, ~p"/devices")

      view
      |> form("#passkey-#{pk.id}-rename-form", passkey: %{name: "Anna's phone"})
      |> render_change()

      assert Repo.get!(Passkey, pk.id).name == "Anna's phone"

      assert [entry] = Repo.all(Entry)
      assert entry.entity_type == "passkey"
      assert entry.entity_id == pk.id
      assert entry.description == "Wannes renamed passkey 'New passkey' → 'Anna's phone'"
    end

    test "rejects a blank name inline, without persisting or logging", %{conn: conn} do
      user = insert_user!("Wannes")
      conn = log_in_user(conn, user)
      pk = insert_passkey!(user, "Laptop", @epoch)

      {:ok, view, _html} = live(conn, ~p"/devices")

      html =
        view
        |> form("#passkey-#{pk.id}-rename-form", passkey: %{name: ""})
        |> render_change()

      assert html =~ "can&#39;t be blank"
      assert Repo.get!(Passkey, pk.id).name == "Laptop"
      assert Repo.all(Entry) == []
    end
  end

  describe "revoking a non-last passkey (AUTH-08, AUTH-11, XC-40)" do
    test "confirming removes it from the list and logs it", %{conn: conn} do
      user = insert_user!("Wannes")
      conn = log_in_user(conn, user)
      keep = insert_passkey!(user, "Laptop", @epoch)
      doomed = insert_passkey!(user, "Old phone", @epoch)

      {:ok, view, _html} = live(conn, ~p"/devices")

      view |> element("#passkey-#{doomed.id}-revoke") |> render_click()
      assert has_element?(view, "#passkey-#{doomed.id}-revoke-confirm")

      view |> element("#passkey-#{doomed.id}-revoke-confirm-confirm") |> render_click()

      refute has_element?(view, "#passkey-#{doomed.id}-name")
      assert has_element?(view, "#passkey-#{keep.id}-name")

      assert Repo.get(Passkey, doomed.id) == nil

      assert [entry] = Repo.all(Entry)
      assert entry.description == "Wannes revoked passkey 'Old phone'"
    end

    test "cancelling leaves the passkey in place", %{conn: conn} do
      user = insert_user!("Wannes")
      conn = log_in_user(conn, user)
      keep = insert_passkey!(user, "Laptop", @epoch)
      other = insert_passkey!(user, "Old phone", @epoch)

      {:ok, view, _html} = live(conn, ~p"/devices")

      view |> element("#passkey-#{other.id}-revoke") |> render_click()
      assert has_element?(view, "#passkey-#{other.id}-revoke-confirm")

      view |> element("#passkey-#{other.id}-revoke-confirm-cancel") |> render_click()

      refute has_element?(view, "#passkey-#{other.id}-revoke-confirm")
      assert has_element?(view, "#passkey-#{other.id}-name")
      assert has_element?(view, "#passkey-#{keep.id}-name")
      assert Repo.get(Passkey, other.id) != nil
    end
  end

  describe "the last-passkey guard (AUTH-08)" do
    test "the revoke control is disabled, with an inline explanation, when only one passkey remains",
         %{conn: conn} do
      user = insert_user!("Wannes")
      conn = log_in_user(conn, user)
      only = insert_passkey!(user, "Only one", @epoch)

      {:ok, view, _html} = live(conn, ~p"/devices")

      assert has_element?(view, "#passkey-#{only.id}-revoke[disabled]")
      assert has_element?(view, "#passkey-#{only.id}-last-passkey-note")
    end

    test "the control re-disables once revoking gets down to one passkey", %{conn: conn} do
      user = insert_user!("Wannes")
      conn = log_in_user(conn, user)
      keep = insert_passkey!(user, "Laptop", @epoch)
      doomed = insert_passkey!(user, "Old phone", @epoch)

      {:ok, view, _html} = live(conn, ~p"/devices")

      refute has_element?(view, "#passkey-#{keep.id}-revoke[disabled]")

      view |> element("#passkey-#{doomed.id}-revoke") |> render_click()
      view |> element("#passkey-#{doomed.id}-revoke-confirm-confirm") |> render_click()

      assert has_element?(view, "#passkey-#{keep.id}-revoke[disabled]")
      assert has_element?(view, "#passkey-#{keep.id}-last-passkey-note")
    end

    test "a crafted revoke_confirmed event for the last passkey is refused server-side, bypassing the disabled UI",
         %{conn: conn} do
      user = insert_user!("Wannes")
      conn = log_in_user(conn, user)
      only = insert_passkey!(user, "Only one", @epoch)

      {:ok, view, _html} = live(conn, ~p"/devices")

      # The button in the DOM is genuinely disabled (proven above); this bypasses it
      # entirely by sending the event LiveView would receive if it weren't, exactly as a
      # crafted client message would.
      html = render_click(view, "revoke_confirmed", %{"id" => to_string(only.id)})

      assert html =~ "You can&#39;t revoke your last passkey."
      assert Repo.get(Passkey, only.id) != nil
      assert has_element?(view, "#passkey-#{only.id}-name")
      assert Repo.all(Entry) == []
    end

    test "the context-level guard is exercised directly too (belt and suspenders)", %{
      conn: _conn
    } do
      user = insert_user!("Wannes")
      only = insert_passkey!(user, "Only one", @epoch)

      assert WeddingPlanner.Accounts.Passkeys.revoke(Scope.for_user(user), only) ==
               {:error, :last_passkey}
    end
  end

  describe "another user's passkeys can never be revoked from here" do
    test "a crafted revoke_confirmed event naming another user's passkey id is a no-op", %{
      conn: conn
    } do
      user = insert_user!("Wannes")
      other = insert_user!("Partner")
      conn = log_in_user(conn, user)

      _mine = insert_passkey!(user, "Mine", @epoch)
      _mine2 = insert_passkey!(user, "Mine 2", @epoch)
      theirs = insert_passkey!(other, "Not mine", @epoch)

      {:ok, view, _html} = live(conn, ~p"/devices")

      render_click(view, "revoke_confirmed", %{"id" => to_string(theirs.id)})

      assert Repo.get(Passkey, theirs.id) != nil
      assert Repo.all(Entry) == []
    end

    test "a crafted rename event naming another user's passkey id is a no-op", %{conn: conn} do
      user = insert_user!("Wannes")
      other = insert_user!("Partner")
      conn = log_in_user(conn, user)

      _mine = insert_passkey!(user, "Mine", @epoch)
      theirs = insert_passkey!(other, "Not mine", @epoch)

      {:ok, view, _html} = live(conn, ~p"/devices")

      render_change(view, "rename", %{
        "passkey_id" => to_string(theirs.id),
        "passkey" => %{"name" => "Hijacked"}
      })

      assert Repo.get!(Passkey, theirs.id).name == "Not mine"
      assert Repo.all(Entry) == []
    end
  end

  describe "revoking the passkey that opened the current session (DR-24, self-revocation)" do
    test "broadcasts a disconnect on this very session's live_socket_id too", %{conn: conn} do
      user = insert_user!("Wannes")
      this_session_passkey = insert_passkey!(user, "This device", @epoch)
      _other_passkey = insert_passkey!(user, "Another device", @epoch)

      conn = log_in_user(conn, user, this_session_passkey)
      live_socket_id = get_session(conn, "live_socket_id")
      assert live_socket_id

      {:ok, view, _html} = live(conn, ~p"/devices")

      # Same approach `WeddingPlannerWeb.SessionControllerTest` uses for the ordinary
      # sign-out broadcast: subscribe directly to the PubSub topic rather than relying on
      # `Phoenix.LiveViewTest`'s simulated transport to actually tear itself down (the
      # real transport-level disconnect is verified end to end in the manual browser run).
      Phoenix.PubSub.subscribe(WeddingPlanner.PubSub, live_socket_id)

      view
      |> element("#passkey-#{this_session_passkey.id}-revoke")
      |> render_click()

      view
      |> element("#passkey-#{this_session_passkey.id}-revoke-confirm-confirm")
      |> render_click()

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^live_socket_id}

      # And, independently of the live socket, the underlying session row is really gone
      # — a fresh request with the same cookie lands on /login, not a crash.
      assert Sessions.fetch_by_token(get_session(conn, "user_session_token")) == :error
      conn = conn |> recycle() |> get(~p"/devices")
      assert redirected_to(conn) == "/login?return_to=%2Fdevices"
    end

    test "does not disconnect a session opened by a different passkey", %{conn: conn} do
      user = insert_user!("Wannes")
      doomed_passkey = insert_passkey!(user, "Old phone", @epoch)
      other_passkey = insert_passkey!(user, "This device", @epoch)

      conn = log_in_user(conn, user, other_passkey)
      this_live_socket_id = get_session(conn, "live_socket_id")

      {:ok, _other_session, other_token} =
        Sessions.create_session(user, doomed_passkey, now: @epoch)

      doomed_live_socket_id = WeddingPlannerWeb.UserAuth.live_socket_id(other_token)

      Phoenix.PubSub.subscribe(WeddingPlanner.PubSub, this_live_socket_id)
      Phoenix.PubSub.subscribe(WeddingPlanner.PubSub, doomed_live_socket_id)

      {:ok, view, _html} = live(conn, ~p"/devices")

      view |> element("#passkey-#{doomed_passkey.id}-revoke") |> render_click()
      view |> element("#passkey-#{doomed_passkey.id}-revoke-confirm-confirm") |> render_click()

      assert_receive %Phoenix.Socket.Broadcast{
        event: "disconnect",
        topic: ^doomed_live_socket_id
      }

      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^this_live_socket_id}
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end

  defp insert_passkey!(user, name, registered_at) do
    %Passkey{user_id: user.id, sign_count: 0}
    |> Passkey.registration_changeset(%{
      credential_id: :crypto.strong_rand_bytes(16),
      public_key: Passkey.encode_cose_key(%{1 => 2, 3 => -7, -1 => 1, -2 => <<1, 2, 3>>}),
      name: name,
      registered_at: registered_at
    })
    |> Repo.insert!()
  end
end
