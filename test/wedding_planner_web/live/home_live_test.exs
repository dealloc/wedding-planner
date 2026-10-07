defmodule WeddingPlannerWeb.HomeLiveTest do
  @moduledoc """
  The `/home` dashboard (`docs/modules/home.md` `HOME-01`…`HOME-07`): every card shows
  real data and updates in place when that data changes.
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import WeddingPlanner.InvoiceFixtures
  import WeddingPlanner.OfferFixtures

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Events
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Invitations
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks

  setup %{conn: conn} do
    user = %User{} |> User.changeset(%{display_name: "Wannes"}) |> Repo.insert!()
    %{conn: log_in_user(conn, user), user: user, scope: Scope.for_user(user)}
  end

  # The page coalesces broadcasts behind a short timer; tests fire the reload by hand
  # (per AGENTS.md: no sleeping) and synchronise on the LiveView process.
  defp refresh(view) do
    send(view.pid, :refresh)
    _ = :sys.get_state(view.pid)
    :ok
  end

  defp today, do: Date.utc_today()

  describe "application shell" do
    test "mounts and renders the navigation as a data list, by DOM id", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/home")

      assert html =~ "Wedding Planner"
      assert has_element?(view, "#main-nav")
      assert has_element?(view, "#nav-home a", "Home")
    end

    test "an empty installation shows an empty state in every card", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/home")

      assert has_element?(view, "#home-countdown", "No upcoming event date")
      assert has_element?(view, "#home-tasks-empty")
      assert has_element?(view, "#home-guests-no-events")
      assert has_element?(view, "#home-attention-clear")
      assert has_element?(view, "#home-money")
      assert has_element?(view, "#home-activity")
    end
  end

  describe "countdown (HOME-06)" do
    test "counts the days to the nearest event with a date", %{conn: conn, scope: scope} do
      {:ok, _} = Events.create_event(scope, %{"name" => "Later", "date" => Date.add(today(), 90)})

      {:ok, _} =
        Events.create_event(scope, %{"name" => "Ceremony", "date" => Date.add(today(), 30)})

      {:ok, _} = Events.create_event(scope, %{"name" => "Past", "date" => Date.add(today(), -5)})

      {:ok, view, _html} = live(conn, ~p"/home")

      assert has_element?(view, "#home-countdown", "30 days")
      assert has_element?(view, "#home-countdown", "Ceremony")
    end
  end

  describe "next up (HOME-02)" do
    test "lists actionable tasks overdue first and counts the blocked ones", %{
      conn: conn,
      scope: scope
    } do
      {:ok, soon} =
        Tasks.create_task(scope, %{
          "title" => "Book the photographer",
          "deadline_kind" => "fixed",
          "deadline_date" => Date.to_iso8601(Date.add(today(), 3))
        })

      {:ok, late} =
        Tasks.create_task(scope, %{
          "title" => "Pay the deposit",
          "deadline_kind" => "fixed",
          "deadline_date" => Date.to_iso8601(Date.add(today(), -2))
        })

      {:ok, blocked} = Tasks.create_task(scope, %{"title" => "Send save-the-dates"})
      {:ok, _} = Tasks.add_dependency(scope, blocked, soon)

      {:ok, view, html} = live(conn, ~p"/home")

      assert has_element?(view, "#home-task-#{late.id}", "Overdue")
      assert has_element?(view, "#home-task-#{soon.id}", "Due in 3 days")
      refute has_element?(view, "#home-task-#{blocked.id}")
      assert has_element?(view, "#home-tasks-blocked", "1 more blocked")

      # Overdue sorts before the later deadline.
      assert :binary.match(html, "home-task-#{late.id}") <
               :binary.match(html, "home-task-#{soon.id}")
    end
  end

  describe "money (HOME-03)" do
    test "shows an overdue unpaid invoice and the forecast", %{conn: conn, scope: scope} do
      category = category_fixture(scope)

      invoice =
        invoice_fixture(scope, category, %{
          "label" => "Venue deposit",
          "due_date" => Date.add(today(), -4)
        })

      {:ok, view, _html} = live(conn, ~p"/home")

      assert has_element?(view, "#home-invoice-#{invoice.id}", "overdue since")
      assert has_element?(view, "#home-money-forecast")
      assert has_element?(view, "#home-money-available", "No overall budget set")
    end
  end

  describe "guests (HOME-04)" do
    test "counts invitations per status and shows headcount per event", %{
      conn: conn,
      scope: scope
    } do
      {:ok, dinner} = Events.create_event(scope, %{"name" => "Dinner"})
      {:ok, anna} = Guests.create_person(scope, %{"first_name" => "Anna"})
      {:ok, _} = Invitations.set_invitation_status(scope, anna, dinner, :accepted)

      {:ok, view, _html} = live(conn, ~p"/home")

      assert has_element?(view, "#home-event-#{dinner.id}")
      assert has_element?(view, "#home-invitations-accepted", "1")
      assert has_element?(view, "#home-people", "1 person")
    end
  end

  describe "needs attention (HOME-05)" do
    test "flags a category with offers but none confirmed or picked", %{
      conn: conn,
      scope: scope
    } do
      category = category_fixture(scope, %{"name" => "Catering"})
      _offer = offer_fixture(scope, category, %{"vendor_name" => "Caterer A"})

      {:ok, view, _html} = live(conn, ~p"/home")

      assert has_element?(view, "#home-attention-undecided-#{category.id}", "Catering")
      refute has_element?(view, "#home-attention-clear")
    end
  end

  describe "live updates (HOME-07, XC-01, XC-02)" do
    test "a new task appears in every open session without a refresh", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      {:ok, view_a, _html} = live(conn, ~p"/home")
      {:ok, view_b, _html} = live(log_in_user(build_conn(), user), ~p"/home")

      {:ok, task} = Tasks.create_task(scope, %{"title" => "Taste the menu"})

      refresh(view_a)
      refresh(view_b)

      assert has_element?(view_a, "#home-task-#{task.id}", "Taste the menu")
      assert has_element?(view_b, "#home-task-#{task.id}", "Taste the menu")
    end

    test "the money, attention and activity cards follow later changes too", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, ~p"/home")
      refute has_element?(view, "#home-invoices")

      category = category_fixture(scope, %{"name" => "Venue"})
      offer = offer_fixture(scope, category, %{"vendor_name" => "Venue A"})
      _ = invoice_fixture(scope, category, %{"due_date" => Date.add(today(), 10)})
      refresh(view)

      assert has_element?(view, "#home-invoices")
      assert has_element?(view, "#home-attention-undecided-#{category.id}")

      {:ok, _} = Offers.confirm_offer(scope, offer)
      refresh(view)

      refute has_element?(view, "#home-attention-undecided-#{category.id}")
      assert has_element?(view, "#home-activity", "Venue A")
    end

    test "a burst of broadcasts coalesces into one pending reload", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/home")

      {:ok, _} = Tasks.create_task(scope, %{"title" => "One"})
      {:ok, _} = Tasks.create_task(scope, %{"title" => "Two"})
      _ = :sys.get_state(view.pid)

      assert %{refresh_timer: timer} = :sys.get_state(view.pid).socket.assigns
      assert is_reference(timer)
    end
  end
end
