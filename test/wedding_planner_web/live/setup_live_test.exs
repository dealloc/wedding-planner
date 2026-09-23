defmodule WeddingPlannerWeb.Live.SetupLiveTest do
  @moduledoc """
  `AUTH-03`, `D-33`, `DR-22` — the one-time bootstrap setup screen. Runs `async: false`:
  every test here mutates the shared `:wedding_planner, :setup_token` application
  environment key (per `config/runtime.exs`'s own comment, tests must set it per case
  rather than rely on the ambient env), which is process-global state that would race
  under `async: true`.
  """
  use WeddingPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.SetupGuard
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Repo
  alias WeddingPlanner.SoftwareAuthenticator

  @valid_token String.duplicate("a", 32)

  setup do
    previous = Application.get_env(:wedding_planner, :setup_token)
    Application.delete_env(:wedding_planner, :setup_token)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:wedding_planner, :setup_token)
        value -> Application.put_env(:wedding_planner, :setup_token, value)
      end
    end)

    :ok
  end

  describe "no users exist, no token configured" do
    @tag example: "A1"
    test "only the explanatory page is reachable", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/setup")

      assert html =~ "Setup is not available"
      assert has_element?(view, "#setup-unavailable")
      refute has_element?(view, "#setup-form")
      assert Repo.aggregate(User, :count) == 0
    end
  end

  describe "no users exist, a token is configured" do
    setup do
      Application.put_env(:wedding_planner, :setup_token, @valid_token)
      :ok
    end

    test "the setup form renders", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      assert has_element?(view, "#setup-form-card")
      assert has_element?(view, "#setup-form")
      assert has_element?(view, "#setup-form input[name='setup[setup_token]']")
      assert has_element?(view, "#setup-form input[name='setup[display_name]']")
      assert has_element?(view, "#setup-form input[name='setup[passkey_name]']")
      assert has_element?(view, "#setup-submit")
    end

    test "a missing field is rejected without creating a user", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      html = submit_setup(view, valid_params(%{"display_name" => ""}))

      assert html =~ "can&#39;t be blank"
      assert has_element?(view, "#setup-form")
      assert Repo.aggregate(User, :count) == 0
    end

    test "an incorrect token is rejected, not echoed back, and creates no user", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      html = submit_setup(view, valid_params(%{"setup_token" => String.duplicate("b", 32)}))

      assert html =~ "is incorrect"
      assert has_element?(view, "#setup-form")

      document = LazyHTML.from_fragment(html)

      [token_value] =
        document
        |> LazyHTML.query("input[name='setup[setup_token]']")
        |> LazyHTML.attribute("value")

      assert token_value == ""
      assert Repo.aggregate(User, :count) == 0
    end

    test "a too-short configured token is refused as if unavailable", %{conn: conn} do
      Application.put_env(:wedding_planner, :setup_token, "too-short")

      {:ok, view, _html} = live(conn, ~p"/setup")

      assert has_element?(view, "#setup-unavailable")
      refute has_element?(view, "#setup-form")
    end

    test "a correct token starts the passkey ceremony", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      submit_setup(view, valid_params())

      assert has_element?(view, "#setup-ceremony-card")
      assert_push_event(view, "passkey:create", %{challenge: _})
      assert Repo.aggregate(User, :count) == 1

      # Leave no guard process dangling past this test — it would otherwise still be
      # monitoring `view.pid` when the test (and its sandboxed connection) ends, and
      # could try (and fail) a `Repo` call against an already-torn-down connection once
      # the view eventually goes down.
      %{socket: %{assigns: %{setup_guard: guard}}} = :sys.get_state(view.pid)
      SetupGuard.disarm(guard)
    end

    test "completing the ceremony registers the passkey, logs it (AUTH-11), and takes the user to sign in",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      submit_setup(view, valid_params())
      assert_push_event(view, "passkey:create", options)

      {_authenticator, credential} = SoftwareAuthenticator.create(options)

      {:ok, login_view, _html} =
        view
        |> render_hook("passkey:registration-success", credential)
        |> follow_redirect(conn, ~p"/login")

      assert has_element?(login_view, "#login-card")

      assert has_element?(
               login_view,
               "#flash-info",
               "You're all set — sign in with your new passkey."
             )

      assert [user] = Repo.all(User)
      assert user.display_name == "Wannes"

      assert [passkey] = Repo.all(Passkey)
      assert passkey.user_id == user.id
      assert passkey.name == "Laptop"

      assert [entry] = Repo.all(Entry)
      assert entry.user_id == user.id
      assert entry.entity_type == "passkey"
      assert entry.entity_id == passkey.id
      assert entry.description == "Wannes registered passkey 'Laptop'"
    end

    test "once a user exists, /setup is not found regardless of the token", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")
      submit_setup(view, valid_params())
      assert_push_event(view, "passkey:create", options)
      {_authenticator, credential} = SoftwareAuthenticator.create(options)

      assert {:error, {:live_redirect, %{to: "/login"}}} =
               render_hook(view, "passkey:registration-success", credential)

      assert_error_sent(404, fn -> get(build_conn(), ~p"/setup") end)
    end

    test "cancelling the ceremony deletes the provisional user and returns to the form, with no log entry",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")
      submit_setup(view, valid_params())
      assert Repo.aggregate(User, :count) == 1

      render_hook(view, "passkey:cancelled", %{})

      assert has_element?(view, "#setup-form")
      refute has_element?(view, "#setup-form", "This browser")
      assert Repo.aggregate(User, :count) == 0
      assert Repo.aggregate(Entry, :count) == 0

      # The display name and passkey name survive the reset — only the token is cleared.
      assert has_element?(
               view,
               "#setup-form input[name='setup[display_name]'][value='Wannes']"
             )
    end

    test "a client-reported error deletes the provisional user, flashes, and returns to the form",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")
      submit_setup(view, valid_params())

      html = render_hook(view, "passkey:error", %{"message" => "No authenticator available."})

      assert html =~ "No authenticator available."
      assert has_element?(view, "#setup-form")
      assert Repo.aggregate(User, :count) == 0
      assert Repo.aggregate(Entry, :count) == 0
    end

    test "an unsupported browser reported before any ceremony just flashes, with no user to delete",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      html = render_hook(view, "passkey:unsupported", %{})

      assert html =~ "does not support passkeys"
      assert has_element?(view, "#setup-form")
      assert Repo.aggregate(User, :count) == 0
    end

    test "an unsupported browser reported mid-ceremony deletes the provisional user", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/setup")
      submit_setup(view, valid_params())
      assert Repo.aggregate(User, :count) == 1

      render_hook(view, "passkey:unsupported", %{})

      assert has_element?(view, "#setup-form")
      assert Repo.aggregate(User, :count) == 0
    end

    test "a server-side registration failure (e.g. origin mismatch) deletes the provisional user",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")
      submit_setup(view, valid_params())
      assert_push_event(view, "passkey:create", options)

      {_authenticator, bad_credential} =
        SoftwareAuthenticator.create(options, origin: "https://evil.example")

      html = render_hook(view, "passkey:registration-success", bad_credential)

      assert html =~ "Passkey registration failed"
      assert has_element?(view, "#setup-form")
      assert Repo.aggregate(User, :count) == 0
      assert Repo.aggregate(Passkey, :count) == 0
      assert Repo.aggregate(Entry, :count) == 0
    end

    test "the LiveView dying mid-ceremony deletes the provisional user (DR-22)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")
      submit_setup(view, valid_params())
      assert Repo.aggregate(User, :count) == 1

      %{socket: %{assigns: %{setup_guard: guard, user: user}}} = :sys.get_state(view.pid)
      assert is_pid(guard)

      # Phoenix.LiveViewTest links the view's process to the test process so an
      # unexpected LiveView crash fails the test loudly; unlink first since this test
      # deliberately, forcibly kills it to simulate a tab closing mid-ceremony. Trapping
      # exits too: the killed view was a client of the shared sandboxed DB connection, and
      # the kill can cascade to the test process as an EXIT before the assertions run
      # (the same flake EnrollmentLiveTest's equivalent test guards against).
      Process.flag(:trap_exit, true)
      Process.unlink(view.pid)

      ref = Process.monitor(guard)
      Process.exit(view.pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^guard, :normal}
      refute Repo.get(User, user.id)
    end
  end

  defp valid_params(overrides \\ %{}) do
    Map.merge(
      %{"setup_token" => @valid_token, "display_name" => "Wannes", "passkey_name" => "Laptop"},
      overrides
    )
  end

  defp submit_setup(view, params) do
    view |> form("#setup-form", setup: params) |> render_submit()
  end
end
