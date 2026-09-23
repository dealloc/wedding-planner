defmodule WeddingPlannerWeb.Live.EnrollmentLiveTest do
  @moduledoc """
  `AUTH-04` through `AUTH-09`, `DR-20`, `DR-22` — the public enrollment landing page.
  Drives the ceremony end to end with `WeddingPlanner.SoftwareAuthenticator`, the same
  spec-built authenticator `WebAuthnTest`, `SetupLiveTest` and `LoginLiveTest` use.

  `async: false` — mutates shared rows across processes and, in the last two tests,
  simulates two independent devices, which is easier to reason about serialized.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.EnrollmentLink
  alias WeddingPlanner.Accounts.EnrollmentLinks
  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Repo
  alias WeddingPlanner.SoftwareAuthenticator

  describe "an invalid token" do
    test "an unknown token is rejected", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/enroll/does-not-exist")

      assert html =~ "This link can&#39;t be used"
      assert has_element?(view, "#enrollment-invalid")
    end

    @tag example: "A3"
    test "AUTH-06: a used link is rejected", %{conn: conn} do
      user = insert_user!("Wannes")
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, link} = EnrollmentLinks.create_device_link(user)
      {:ok, used} = link |> EnrollmentLink.use_changeset(now) |> Repo.update()

      {:ok, view, html} = live(conn, ~p"/enroll/#{used.token}")

      assert html =~ "already been used"
      assert has_element?(view, "#enrollment-invalid")
    end

    @tag example: "A4"
    test "AUTH-06: an expired link is rejected", %{conn: conn} do
      user = insert_user!("Wannes")

      expired_at =
        DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      {:ok, link} =
        EnrollmentLink.device_link_changeset(user, %{expires_at: expired_at}) |> Repo.insert()

      {:ok, view, html} = live(conn, ~p"/enroll/#{link.token}")

      assert html =~ "expired"
      assert has_element?(view, "#enrollment-invalid")
    end

    test "AUTH-07: a revoked link is rejected", %{conn: conn} do
      user = insert_user!("Wannes")
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, link} = EnrollmentLinks.create_device_link(user)
      {:ok, revoked} = EnrollmentLinks.revoke(link, now)

      {:ok, view, html} = live(conn, ~p"/enroll/#{revoked.token}")

      assert html =~ "revoked"
      assert has_element?(view, "#enrollment-invalid")
    end
  end

  describe "AUTH-04: device flavour" do
    @tag example: "A2"
    test "registers a passkey for the issuing user, then is rejected on reuse", %{conn: conn} do
      user = insert_user!("Wannes")
      {:ok, link} = EnrollmentLinks.create_device_link(user)

      {:ok, view, html} = live(conn, ~p"/enroll/#{link.token}")
      assert html =~ "Wannes"
      assert has_element?(view, "#enrollment-register-button")

      view |> element("#enrollment-register-button") |> render_click()
      assert_push_event(view, "passkey:create", options)

      {_authenticator, credential} = SoftwareAuthenticator.create(options)
      html = render_hook(view, "passkey:registration-success", credential)

      assert has_element?(view, "#enrollment-completed")
      assert html =~ "Wannes"

      assert [passkey] = Repo.all(Passkey)
      assert passkey.user_id == user.id
      assert passkey.name == "New passkey"
      assert Repo.aggregate(User, :count) == 1

      assert %EnrollmentLink{used_at: %DateTime{}} = Repo.get(EnrollmentLink, link.id)

      entry = Repo.get_by(Entry, entity_type: "passkey", entity_id: passkey.id)
      assert entry.user_id == user.id
      assert entry.description == "Wannes registered passkey 'New passkey'"

      # Rejected on reuse.
      {:ok, view2, html2} = live(conn, ~p"/enroll/#{link.token}")
      assert html2 =~ "already been used"
      assert has_element?(view2, "#enrollment-invalid")
      assert Repo.aggregate(Passkey, :count) == 1
    end
  end

  describe "AUTH-09: recovery flavour" do
    test "behaves like a device link for its target user", %{conn: conn} do
      user = insert_user!("Wannes")
      {:ok, link} = EnrollmentLink.recovery_link_changeset(user) |> Repo.insert()

      {:ok, view, html} = live(conn, ~p"/enroll/#{link.token}")
      assert html =~ "recovery"
      assert has_element?(view, "#enrollment-register-button")

      view |> element("#enrollment-register-button") |> render_click()
      assert_push_event(view, "passkey:create", options)

      {_authenticator, credential} = SoftwareAuthenticator.create(options)
      render_hook(view, "passkey:registration-success", credential)

      assert has_element?(view, "#enrollment-completed")
      assert [passkey] = Repo.all(Passkey)
      assert passkey.user_id == user.id
      assert %EnrollmentLink{used_at: %DateTime{}} = Repo.get(EnrollmentLink, link.id)
    end
  end

  describe "AUTH-05, DR-20: user-invitation flavour" do
    test "the invitee's own chosen name creates a new user with a passkey", %{conn: conn} do
      issuer = insert_user!("Wannes")
      {:ok, link} = EnrollmentLinks.create_invitation_link(issuer)

      {:ok, view, html} = live(conn, ~p"/enroll/#{link.token}")
      assert html =~ "Wannes"
      assert has_element?(view, "#enrollment-name-form")

      view
      |> form("#enrollment-name-form", invitation: %{"display_name" => "Anna"})
      |> render_submit()

      assert_push_event(view, "passkey:create", options)
      assert Repo.aggregate(User, :count) == 2

      {_authenticator, credential} = SoftwareAuthenticator.create(options)
      html = render_hook(view, "passkey:registration-success", credential)

      assert has_element?(view, "#enrollment-completed")
      assert html =~ "Anna"

      new_user = Repo.get_by!(User, display_name: "Anna")
      assert [passkey] = Repo.all(Passkey)
      assert passkey.user_id == new_user.id

      updated_link = Repo.get(EnrollmentLink, link.id)
      assert updated_link.target_user_id == new_user.id
      assert %DateTime{} = updated_link.used_at

      entry = Repo.get_by(Entry, entity_type: "passkey", entity_id: passkey.id)
      assert entry.user_id == new_user.id
      assert entry.description == "Anna registered passkey 'New passkey'"
    end

    test "a blank name is rejected without creating a user", %{conn: conn} do
      issuer = insert_user!("Wannes")
      {:ok, link} = EnrollmentLinks.create_invitation_link(issuer)

      {:ok, view, _html} = live(conn, ~p"/enroll/#{link.token}")

      html =
        view
        |> form("#enrollment-name-form", invitation: %{"display_name" => ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Repo.aggregate(User, :count) == 1
    end

    test "cancelling the ceremony deletes the provisional user and leaves the link usable", %{
      conn: conn
    } do
      issuer = insert_user!("Wannes")
      {:ok, link} = EnrollmentLinks.create_invitation_link(issuer)

      {:ok, view, _html} = live(conn, ~p"/enroll/#{link.token}")

      view
      |> form("#enrollment-name-form", invitation: %{"display_name" => "Anna"})
      |> render_submit()

      assert Repo.aggregate(User, :count) == 2

      render_hook(view, "passkey:cancelled", %{})

      assert has_element?(view, "#enrollment-name-form")
      assert Repo.aggregate(User, :count) == 1
      assert Repo.aggregate(Passkey, :count) == 0
      assert Repo.aggregate(Entry, :count) == 0
      assert {:ok, _} = EnrollmentLinks.fetch_for_redemption(link.token)
    end

    test "a client-reported error deletes the provisional user and leaves the link usable", %{
      conn: conn
    } do
      issuer = insert_user!("Wannes")
      {:ok, link} = EnrollmentLinks.create_invitation_link(issuer)

      {:ok, view, _html} = live(conn, ~p"/enroll/#{link.token}")

      view
      |> form("#enrollment-name-form", invitation: %{"display_name" => "Anna"})
      |> render_submit()

      html = render_hook(view, "passkey:error", %{"message" => "No authenticator available."})

      assert html =~ "No authenticator available."
      assert Repo.aggregate(User, :count) == 1
      assert Repo.aggregate(Passkey, :count) == 0
      assert {:ok, _} = EnrollmentLinks.fetch_for_redemption(link.token)
    end

    test "a failed finish_registration (origin mismatch) deletes the provisional user, link stays usable",
         %{conn: conn} do
      issuer = insert_user!("Wannes")
      {:ok, link} = EnrollmentLinks.create_invitation_link(issuer)

      {:ok, view, _html} = live(conn, ~p"/enroll/#{link.token}")

      view
      |> form("#enrollment-name-form", invitation: %{"display_name" => "Anna"})
      |> render_submit()

      assert_push_event(view, "passkey:create", options)

      {_authenticator, bad_credential} =
        SoftwareAuthenticator.create(options, origin: "https://evil.example")

      html = render_hook(view, "passkey:registration-success", bad_credential)

      assert html =~ "Passkey registration failed"
      assert Repo.aggregate(User, :count) == 1
      assert Repo.aggregate(Passkey, :count) == 0
      assert Repo.aggregate(Entry, :count) == 0
      assert {:ok, _} = EnrollmentLinks.fetch_for_redemption(link.token)
    end

    test "the LiveView dying mid-ceremony deletes the provisional user (DR-22)", %{conn: conn} do
      issuer = insert_user!("Wannes")
      {:ok, link} = EnrollmentLinks.create_invitation_link(issuer)

      {:ok, view, _html} = live(conn, ~p"/enroll/#{link.token}")

      view
      |> form("#enrollment-name-form", invitation: %{"display_name" => "Anna"})
      |> render_submit()

      %{socket: %{assigns: %{setup_guard: guard, target_user: user}}} = :sys.get_state(view.pid)
      assert is_pid(guard)

      # Phoenix.LiveViewTest links the view's process to the test process so an
      # unexpected LiveView crash fails the test loudly; unlink first since this test
      # deliberately, forcibly kills it to simulate a tab closing mid-ceremony. Trapping
      # exits too is belt-and-braces: the killed view process was itself a client of the
      # shared sandboxed DB connection (it just inserted the provisional user), and
      # `:killed` is un-trappable at the target but still propagates as an ordinary EXIT
      # to *other* processes linked to it (observed as an intermittent flake otherwise —
      # the test process could receive a cascading `:killed` EXIT from the DB connection
      # owner and die with it before reaching the assertions below).
      Process.flag(:trap_exit, true)
      Process.unlink(view.pid)

      ref = Process.monitor(guard)
      Process.exit(view.pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^guard, :normal}
      refute Repo.get(User, user.id)
      assert {:ok, _} = EnrollmentLinks.fetch_for_redemption(link.token)
    end
  end

  describe "single-use under a real (sequential) race between two devices" do
    test "AUTH-06: the second device to finish a device link is rejected and rolled back", %{
      conn: conn
    } do
      user = insert_user!("Wannes")
      {:ok, link} = EnrollmentLinks.create_device_link(user)

      {:ok, view_a, _html} = live(conn, ~p"/enroll/#{link.token}")
      {:ok, view_b, _html} = live(conn, ~p"/enroll/#{link.token}")

      view_a |> element("#enrollment-register-button") |> render_click()
      assert_push_event(view_a, "passkey:create", options_a)

      view_b |> element("#enrollment-register-button") |> render_click()
      assert_push_event(view_b, "passkey:create", options_b)

      {_auth_a, credential_a} = SoftwareAuthenticator.create(options_a)
      render_hook(view_a, "passkey:registration-success", credential_a)
      assert has_element?(view_a, "#enrollment-completed")

      {_auth_b, credential_b} = SoftwareAuthenticator.create(options_b)
      html_b = render_hook(view_b, "passkey:registration-success", credential_b)

      assert html_b =~ "already been used"
      assert has_element?(view_b, "#enrollment-invalid")

      # Exactly one success: the loser's real, successfully-verified passkey is rolled
      # back rather than left as an extra credential.
      assert Repo.aggregate(Passkey, :count) == 1
      assert Repo.aggregate(User, :count) == 1
    end

    test "AUTH-06: the second invitee to finish loses the race and their user is rolled back",
         %{conn: conn} do
      issuer = insert_user!("Wannes")
      {:ok, link} = EnrollmentLinks.create_invitation_link(issuer)

      {:ok, view_a, _html} = live(conn, ~p"/enroll/#{link.token}")
      {:ok, view_b, _html} = live(conn, ~p"/enroll/#{link.token}")

      view_a
      |> form("#enrollment-name-form", invitation: %{"display_name" => "Anna"})
      |> render_submit()

      assert_push_event(view_a, "passkey:create", options_a)

      view_b
      |> form("#enrollment-name-form", invitation: %{"display_name" => "Bert"})
      |> render_submit()

      assert_push_event(view_b, "passkey:create", options_b)

      {_auth_a, credential_a} = SoftwareAuthenticator.create(options_a)
      render_hook(view_a, "passkey:registration-success", credential_a)
      assert has_element?(view_a, "#enrollment-completed")

      {_auth_b, credential_b} = SoftwareAuthenticator.create(options_b)
      html_b = render_hook(view_b, "passkey:registration-success", credential_b)

      assert html_b =~ "already been used"
      assert has_element?(view_b, "#enrollment-invalid")

      assert Repo.get_by(User, display_name: "Anna")
      refute Repo.get_by(User, display_name: "Bert")
      assert Repo.aggregate(User, :count) == 2
      assert Repo.aggregate(Passkey, :count) == 1
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
