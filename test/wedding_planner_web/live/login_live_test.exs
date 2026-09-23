defmodule WeddingPlannerWeb.Live.LoginLiveTest do
  @moduledoc """
  `AUTH-01`, `AUTH-02` — the usernameless passkey login screen. Drives the ceremony end
  to end with `WeddingPlanner.SoftwareAuthenticator`, the same spec-built authenticator
  `WebAuthnTest` and `SetupLiveTest` use, so a passing test here proves the real
  `navigator.credentials.get()` byte layout, not just that this module agrees with
  itself.

  `async: false` — see `WeddingPlanner.Accounts.SessionsTest`'s moduledoc for why: a
  pre-existing "database busy" flake under this repo's default test concurrency,
  mitigated (not fixed — that's a `config/test.exs` capacity question outside this
  task's boundary) by keeping write-heavy new files out of the async pool.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Accounts.WebAuthn
  alias WeddingPlanner.Repo
  alias WeddingPlanner.SoftwareAuthenticator

  describe "the idle screen" do
    test "shows one button, no username or password field", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/login")

      assert html =~ "Sign in with passkey"
      assert has_element?(view, "#login-button")
      refute has_element?(view, "input[type=text]")
      refute has_element?(view, "input[type=password]")
    end
  end

  describe "a successful ceremony" do
    test "establishes a session and lands on the originally requested page", %{conn: conn} do
      user = insert_user!("Wannes")
      {_passkey, authenticator} = register!(user)

      {:ok, view, _html} = live(conn, ~p"/login?return_to=%2Fhome")

      view |> element("#login-button") |> render_click()
      assert_push_event(view, "passkey:get", options)

      {_authenticator, params} = SoftwareAuthenticator.get(authenticator, options)
      html = render_hook(view, "passkey:authentication-success", params)

      # The bridge form carries the session token to WeddingPlannerWeb.SessionController,
      # which is what actually sets the cookie — see LoginLive's moduledoc. Submitting it
      # here is the same thing `phx-trigger-action` does in a real browser.
      document = LazyHTML.from_fragment(html)

      [token] =
        document
        |> LazyHTML.query("#login-session-form input[name='token']")
        |> LazyHTML.attribute("value")

      [return_to] =
        document
        |> LazyHTML.query("#login-session-form input[name='return_to']")
        |> LazyHTML.attribute("value")

      assert return_to == "/home"
      refute token == ""

      conn = post(conn, ~p"/session", %{"token" => token, "return_to" => return_to})
      assert redirected_to(conn) == "/home"
      assert get_session(conn, "user_session_token")

      assert Repo.aggregate(WeddingPlanner.Accounts.UserSession, :count) == 1
    end

    test "defaults return_to to /home with no query param", %{conn: conn} do
      user = insert_user!("Wannes")
      {_passkey, authenticator} = register!(user)

      {:ok, view, _html} = live(conn, ~p"/login")
      view |> element("#login-button") |> render_click()
      assert_push_event(view, "passkey:get", options)

      {_authenticator, params} = SoftwareAuthenticator.get(authenticator, options)
      html = render_hook(view, "passkey:authentication-success", params)

      document = LazyHTML.from_fragment(html)

      [return_to] =
        document
        |> LazyHTML.query("#login-session-form input[name='return_to']")
        |> LazyHTML.attribute("value")

      assert return_to == "/home"
    end

    test "rejects an absolute/external return_to, falling back to /home", %{conn: conn} do
      user = insert_user!("Wannes")
      {_passkey, authenticator} = register!(user)

      {:ok, view, _html} =
        live(conn, ~p"/login?#{[return_to: "https://evil.example/steal"]}")

      view |> element("#login-button") |> render_click()
      assert_push_event(view, "passkey:get", options)

      {_authenticator, params} = SoftwareAuthenticator.get(authenticator, options)
      html = render_hook(view, "passkey:authentication-success", params)

      document = LazyHTML.from_fragment(html)

      [return_to] =
        document
        |> LazyHTML.query("#login-session-form input[name='return_to']")
        |> LazyHTML.attribute("value")

      assert return_to == "/home"
    end
  end

  describe "the challenge is single-use" do
    test "a second finish attempt with the same challenge/assertion is a no-op, not a crash",
         %{conn: conn} do
      user = insert_user!("Wannes")
      {_passkey, authenticator} = register!(user)

      {:ok, view, _html} = live(conn, ~p"/login")
      view |> element("#login-button") |> render_click()
      assert_push_event(view, "passkey:get", options)

      {_authenticator, params} = SoftwareAuthenticator.get(authenticator, options)

      # First attempt succeeds, discards the challenge (assign -> nil) and moves state
      # off :ceremony (LoginLive's own single-use guard, mirroring WebAuthn's moduledoc:
      # "a challenge MUST be discarded after one finish_* attempt").
      html = render_hook(view, "passkey:authentication-success", params)
      assert html =~ "taking you there"
      assert Repo.aggregate(WeddingPlanner.Accounts.UserSession, :count) == 1

      # Replaying the exact same assertion now (e.g. a duplicate client message) must
      # not reach WebAuthn.finish_authentication/3 with the already-discarded challenge
      # (that would raise, since it no longer holds a %Wax.Challenge{}) and must not
      # create a second session.
      html2 = render_hook(view, "passkey:authentication-success", params)
      assert html2 == html
      assert Repo.aggregate(WeddingPlanner.Accounts.UserSession, :count) == 1
    end
  end

  describe "a failed ceremony" do
    test "usernameless login resolves the correct user among several with passkeys", %{
      conn: conn
    } do
      wannes = insert_user!("Wannes")
      {_passkey, wannes_authenticator} = register!(wannes)
      partner = insert_user!("Partner")
      {_passkey, _partner_authenticator} = register!(partner)

      {:ok, view, _html} = live(conn, ~p"/login")
      view |> element("#login-button") |> render_click()
      assert_push_event(view, "passkey:get", options)

      {_authenticator, params} = SoftwareAuthenticator.get(wannes_authenticator, options)
      render_hook(view, "passkey:authentication-success", params)

      assert [session] = Repo.all(WeddingPlanner.Accounts.UserSession)
      assert session.user_id == wannes.id
    end

    test "a tampered assertion is rejected, flashes, and returns to the idle screen", %{
      conn: conn
    } do
      user = insert_user!("Wannes")
      {_passkey, authenticator} = register!(user)

      {:ok, view, _html} = live(conn, ~p"/login")
      view |> element("#login-button") |> render_click()
      assert_push_event(view, "passkey:get", options)

      {_authenticator, params} = SoftwareAuthenticator.get(authenticator, options)

      forged =
        params
        |> get_in(["response", "signature"])
        |> Base.url_decode64!(padding: false)
        |> flip_last_byte()
        |> Base.url_encode64(padding: false)

      params = put_in(params, ["response", "signature"], forged)

      html = render_hook(view, "passkey:authentication-success", params)

      assert html =~ "Sign-in failed"
      assert has_element?(view, "#login-button")
    end

    test "cancelling resets quietly, with no flash", %{conn: conn} do
      user = insert_user!("Wannes")
      {_passkey, _authenticator} = register!(user)

      {:ok, view, _html} = live(conn, ~p"/login")
      view |> element("#login-button") |> render_click()
      assert_push_event(view, "passkey:get", %{})

      render_hook(view, "passkey:cancelled", %{})

      assert has_element?(view, "#login-button")
      refute has_element?(view, "#flash-error")
    end

    test "a client-reported error flashes the message verbatim", %{conn: conn} do
      user = insert_user!("Wannes")
      {_passkey, _authenticator} = register!(user)

      {:ok, view, _html} = live(conn, ~p"/login")
      view |> element("#login-button") |> render_click()
      assert_push_event(view, "passkey:get", %{})

      html = render_hook(view, "passkey:error", %{"message" => "No authenticator available."})

      assert html =~ "No authenticator available."
      assert has_element?(view, "#login-button")
    end

    test "an unsupported browser flashes and shows no button state change beyond idle", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/login")

      html = render_hook(view, "passkey:unsupported", %{})

      assert html =~ "does not support passkeys"
      assert has_element?(view, "#login-button")
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end

  defp register!(user) do
    {challenge, options} = WebAuthn.begin_registration(user)
    {authenticator, params} = SoftwareAuthenticator.create(options)
    {:ok, passkey} = WebAuthn.finish_registration(user, challenge, params, name: "Passkey")
    {passkey, authenticator}
  end

  defp flip_last_byte(bin) do
    size = byte_size(bin) - 1
    <<head::binary-size(^size), last>> = bin
    <<head::binary, Bitwise.bxor(last, 1)>>
  end
end
