defmodule WeddingPlannerWeb.Live.SettingsLiveTest do
  @moduledoc """
  The `/settings` screen (task 21; `BUD-01`, `NFR-22`, `XC-10`, `XC-01`, `DR-23`).
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Settings

  setup %{conn: conn} do
    wannes = insert_user!("Wannes")
    %{conn: log_in_user(conn, wannes), wannes: wannes}
  end

  describe "authentication" do
    test "an unauthenticated request redirects to /login" do
      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, ~p"/settings")

      assert redirected_to(conn) == "/login?return_to=%2Fsettings"
    end
  end

  describe "mounting and rendering" do
    test "shows 'Not set' for the budget and Europe/Brussels for the time zone before any row exists",
         %{conn: conn} do
      assert Repo.aggregate(Settings, :count) == 0

      {:ok, view, html} = live(conn, ~p"/settings")

      assert html =~ "Settings"
      assert has_element?(view, "#settings-budget-current", "Not set")
      assert has_element?(view, "#settings_default_time_zone")

      # get/0 creates the row on first access, so it exists once the page has mounted.
      assert Repo.aggregate(Settings, :count) == 1
    end

    test "shows the nav entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      assert has_element?(view, "#nav-settings a", "Settings")
    end

    test "pre-fills the budget input with the currently stored amount, editable text", %{
      conn: conn,
      wannes: wannes
    } do
      settings = Settings.get()

      {:ok, _} =
        Settings.update(scope(wannes), settings, %{"overall_budget_input" => "45.000,50"})

      {:ok, view, _html} = live(conn, ~p"/settings")

      assert view
             |> element("#settings_overall_budget_input")
             |> render() =~ "45.000,50"
    end
  end

  describe "DR-23 — rejecting the dot-as-decimal trap, accepting the nl-BE form" do
    test "submitting 1500.50 is refused with the comma message and nothing is saved", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#settings-form",
          settings: %{overall_budget_input: "1500.50", default_time_zone: "Europe/Brussels"}
        )
        |> render_submit()

      assert html =~ "Use a comma for the decimal part"
      assert has_element?(view, "#settings-budget-current", "Not set")
      assert Settings.get().overall_budget == nil
    end

    test "submitting 45.000,50 is accepted and shown as € 45.000,50", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#settings-form",
        settings: %{overall_budget_input: "45.000,50", default_time_zone: "Europe/Brussels"}
      )
      |> render_submit()

      assert has_element?(view, "#settings-budget-current", "€ 45.000,50")
      assert Settings.get().overall_budget == WeddingPlanner.Money.new(Decimal.new("45000.50"))
    end
  end

  describe "editing the default time zone" do
    test "an invalid time zone is rejected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # `form/3` validates the submitted value against the <select>'s own rendered
      # <option>s (a real browser would never let a dropdown submit an option it
      # doesn't have), so this bypasses the DOM helper and posts the event directly —
      # the server must still refuse it, since nothing stops an arbitrary POST.
      html =
        render_submit(view, "save", %{
          "settings" => %{"default_time_zone" => "Mars/Olympus_Mons"}
        })

      assert html =~ "is not a recognized time zone"
      assert Settings.get().default_time_zone == "Europe/Brussels"
    end

    test "a valid time zone is saved", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#settings-form", settings: %{default_time_zone: "Europe/Amsterdam"})
      |> render_submit()

      assert Settings.get().default_time_zone == "Europe/Amsterdam"
    end
  end

  describe "activity history (XC-11)" do
    test "shows an empty state before any edit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      assert has_element?(view, "#settings-history-empty")
    end

    test "a save appears in the page's own history live, without a refresh", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#settings-form", settings: %{overall_budget_input: "1000"})
      |> render_submit()

      assert has_element?(view, "#settings-history", "Wannes changed the overall budget")
      refute has_element?(view, "#settings-history-empty")
    end
  end

  describe "live updates (XC-01, XC-02 — no concurrent-edit indicator)" do
    test "a change saved in one session appears in a second open session without a refresh", %{
      conn: conn,
      wannes: wannes
    } do
      {:ok, view_a, _html} = live(conn, ~p"/settings")
      {:ok, view_b, _html} = live(log_in_user(build_conn(), wannes), ~p"/settings")

      view_a
      |> form("#settings-form", settings: %{overall_budget_input: "45.000,50"})
      |> render_submit()

      _ = :sys.get_state(view_b.pid)

      assert has_element?(view_b, "#settings-budget-current", "€ 45.000,50")
      assert has_element?(view_b, "#settings-history", "Wannes changed the overall budget")
    end
  end

  defp scope(user), do: WeddingPlanner.Accounts.Scope.for_user(user)

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
