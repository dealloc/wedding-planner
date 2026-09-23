defmodule WeddingPlannerWeb.HomeLiveTest do
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo

  setup %{conn: conn} do
    user = %User{} |> User.changeset(%{display_name: "Wannes"}) |> Repo.insert!()
    %{conn: log_in_user(conn, user), user: user}
  end

  describe "application shell" do
    test "mounts and renders the navigation as a data list, by DOM id", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/home")

      assert html =~ "Wedding Planner"
      assert has_element?(view, "#main-nav")
      assert has_element?(view, "#nav-home")
      assert has_element?(view, "#nav-home a", "Home")
    end

    test "shows the initial content before any broadcast", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/home")

      assert has_element?(view, "#shell-demo-message")
    end
  end

  describe "live updates via WeddingPlanner.Realtime (XC-01, XC-02)" do
    test "a broadcast updates every open session's content in place, without a refresh", %{
      conn: conn,
      user: user
    } do
      {:ok, view_a, _html} = live(conn, ~p"/home")
      {:ok, view_b, _html} = live(log_in_user(build_conn(), user), ~p"/home")

      refute has_element?(view_a, "#shell-demo-message", "Cake tasting booked!")
      refute has_element?(view_b, "#shell-demo-message", "Cake tasting booked!")

      Realtime.broadcast_change(:shell_demo, {:updated, %{message: "Cake tasting booked!"}})

      # Force each LiveView process to have finished handling the broadcast
      # before asserting on its render (per AGENTS.md test guidance: no
      # Process.sleep, synchronize via a blocking call to the process).
      _ = :sys.get_state(view_a.pid)
      _ = :sys.get_state(view_b.pid)

      # Neither session was reloaded — the same view/pid picked up the
      # change purely from the PubSub broadcast.
      assert has_element?(view_a, "#shell-demo-message", "Cake tasting booked!")
      assert has_element?(view_b, "#shell-demo-message", "Cake tasting booked!")
    end

    test "a second broadcast updates content again, same element", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/home")

      Realtime.broadcast_change(:shell_demo, {:updated, %{message: "First update"}})
      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#shell-demo-message", "First update")

      Realtime.broadcast_change(:shell_demo, {:updated, %{message: "Second update"}})
      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#shell-demo-message", "Second update")
      refute has_element?(view, "#shell-demo-message", "First update")
    end
  end
end
