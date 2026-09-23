defmodule WeddingPlannerWeb.Live.TasksLiveTest do
  @moduledoc """
  `docs/modules/tasks-and-timeline.md` `TSK-01`–`TSK-04`, `04-cross-cutting.md`
  `XC-01`/`XC-02`/`XC-10`/`XC-40`, `05-non-functional.md` `NFR-23`/`NFR-31`, `DR-21`,
  `DR-26` Q15/Q16 — the tasks LiveView, task 31.
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Events
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks

  setup %{conn: conn} do
    wannes = insert_user!("Wannes")
    insert_passkey!(wannes)
    bo = insert_user!("Bo")
    insert_passkey!(bo)
    provisional = insert_user!("Aaron")

    %{
      conn: log_in_user(conn, wannes),
      wannes: wannes,
      bo: bo,
      provisional: provisional,
      scope: Scope.for_user(wannes)
    }
  end

  describe "authentication" do
    test "an unauthenticated request redirects to /login" do
      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, ~p"/tasks")

      assert redirected_to(conn) == "/login?return_to=%2Ftasks"
    end
  end

  describe "nav" do
    test "the nav has one Tasks entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert has_element?(view, "#nav-tasks a", "Tasks")
    end
  end

  describe "index" do
    test "shows an empty state when there are no open tasks yet", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/tasks")

      assert html =~ "Tasks"
      assert has_element?(view, "#tasks-empty")
      assert has_element?(view, "#tasks-done-summary", "Done (0)")
    end
  end

  describe "owner picker (DR-22, D-28)" do
    test "lists only assignable users plus Both and Nobody", %{
      conn: conn,
      wannes: wannes,
      bo: bo,
      provisional: provisional
    } do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      view |> element("#new-task") |> render_click()

      assert has_element?(view, "#task-editor-owner option", "Nobody")
      assert has_element?(view, "#task-editor-owner option", "Both")
      assert has_element?(view, "#task-editor-owner option", wannes.display_name)
      assert has_element?(view, "#task-editor-owner option", bo.display_name)
      refute has_element?(view, "#task-editor-owner option", provisional.display_name)
    end
  end

  describe "add task (TSK-01, TSK-02)" do
    test "with no deadline", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      view |> element("#new-task") |> render_click()

      view
      |> form("#task-editor-new", task: %{"title" => "Book caterer"})
      |> render_submit()

      [task] = Tasks.list_tasks()
      assert has_element?(view, "#task-#{task.id}-row", "Book caterer")
      assert has_element?(view, "#task-#{task.id}-deadline", "No deadline")
      refute has_element?(view, "#task-editor-new")
    end

    test "with a fixed deadline, shown day-first (NFR-23)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      view |> element("#new-task") |> render_click()

      view
      |> form("#task-editor-new", task: %{"title" => "Book venue", "deadline_kind" => "fixed"})
      |> render_change()

      assert has_element?(view, "#task-editor-deadline-date")

      view
      |> form("#task-editor-new",
        task: %{
          "title" => "Book venue",
          "deadline_kind" => "fixed",
          "deadline_date" => "2028-05-13"
        }
      )
      |> render_submit()

      [task] = Tasks.list_tasks()
      assert has_element?(view, "#task-#{task.id}-deadline", "13/05/2028")
    end

    test "with a relative deadline on a dateless event shows 'date not set' (TSK-03)", %{
      conn: conn,
      scope: scope
    } do
      {:ok, event} = Events.create_event(scope, %{"name" => "Civil ceremony"})

      {:ok, view, _html} = live(conn, ~p"/tasks")

      view |> element("#new-task") |> render_click()

      view
      |> form("#task-editor-new",
        task: %{"title" => "Print signage", "deadline_kind" => "relative"}
      )
      |> render_change()

      assert has_element?(view, "#task-editor-deadline-amount")

      view
      |> form("#task-editor-new",
        task: %{
          "title" => "Print signage",
          "deadline_kind" => "relative",
          "deadline_amount" => "8",
          "deadline_unit" => "weeks",
          "deadline_direction" => "before",
          "deadline_event_id" => to_string(event.id)
        }
      )
      |> render_submit()

      [task] = Tasks.list_tasks()

      assert has_element?(
               view,
               "#task-#{task.id}-deadline",
               "8 weeks before Civil ceremony — date not set"
             )
    end
  end

  describe "relative-deadline wording (DR-26 Q16)" do
    test "12 weeks before a dated event resolves to 'date · rule'", %{conn: conn, scope: scope} do
      {:ok, reception} =
        Events.create_event(scope, %{"name" => "Reception", "date" => "2028-05-13"})

      {:ok, task} =
        Tasks.create_task(scope, %{
          "title" => "Send invitations",
          "deadline_kind" => "relative",
          "deadline_amount" => "12",
          "deadline_unit" => "weeks",
          "deadline_direction" => "before",
          "deadline_event_id" => reception.id
        })

      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert has_element?(
               view,
               "#task-#{task.id}-deadline",
               "19/02/2028 · 12 weeks before Reception"
             )
    end

    test "an amount of 0 renders 'On the day of <event>'", %{conn: conn, scope: scope} do
      {:ok, reception} =
        Events.create_event(scope, %{"name" => "Reception", "date" => "2028-05-13"})

      {:ok, task} =
        Tasks.create_task(scope, %{
          "title" => "Attend reception",
          "deadline_kind" => "relative",
          "deadline_amount" => "0",
          "deadline_unit" => "days",
          "deadline_direction" => "before",
          "deadline_event_id" => reception.id
        })

      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert has_element?(view, "#task-#{task.id}-deadline", "On the day of Reception")
    end
  end

  @tag example: "T4"
  test "a relative deadline resolves live once the event gets a date (T4, TSK-03, XC-01)", %{
    conn: conn,
    scope: scope
  } do
    {:ok, reception} = Events.create_event(scope, %{"name" => "Reception"})

    {:ok, task} =
      Tasks.create_task(scope, %{
        "title" => "Send invitations",
        "deadline_kind" => "relative",
        "deadline_amount" => "12",
        "deadline_unit" => "weeks",
        "deadline_direction" => "before",
        "deadline_event_id" => reception.id
      })

    {:ok, view, _html} = live(conn, ~p"/tasks")

    assert has_element?(
             view,
             "#task-#{task.id}-deadline",
             "12 weeks before Reception — date not set"
           )

    {:ok, _reception} = Events.update_event(scope, reception, %{"date" => "2028-05-13"})
    _ = :sys.get_state(view.pid)

    assert has_element?(
             view,
             "#task-#{task.id}-deadline",
             "19/02/2028 · 12 weeks before Reception"
           )
  end

  describe "one-tap complete (TSK-11/TSK-12 out of scope: no dependencies yet)" do
    test "moves a task into the done disclosure and writes one status log entry", %{
      conn: conn,
      scope: scope
    } do
      {:ok, task} = Tasks.create_task(scope, %{"title" => "Book caterer"})

      {:ok, view, _html} = live(conn, ~p"/tasks")

      view |> element("#task-#{task.id}-complete") |> render_click()

      refute has_element?(view, "#tasks #task-#{task.id}-row")
      assert has_element?(view, "#tasks-done-list #task-#{task.id}-row")
      assert has_element?(view, "#tasks-done-summary", "Done (1)")

      status_entries =
        Repo.all(Entry) |> Enum.filter(&(&1.description =~ "changed the status"))

      assert [entry] = status_entries
      assert entry.description == "Wannes changed the status of 'Book caterer': to do → done"
    end

    test "un-completing brings it back to the open list", %{conn: conn, scope: scope} do
      {:ok, task} = Tasks.create_task(scope, %{"title" => "Book caterer", "status" => "done"})

      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert has_element?(view, "#tasks-done-list #task-#{task.id}-row")

      view |> element("#task-#{task.id}-complete") |> render_click()

      assert has_element?(view, "#tasks #task-#{task.id}-row")
      refute has_element?(view, "#tasks-done-list #task-#{task.id}-row")
      assert has_element?(view, "#tasks-done-summary", "Done (0)")
    end
  end

  describe "Clear (deadline)" do
    test "returns a task to no deadline", %{conn: conn, scope: scope} do
      {:ok, task} =
        Tasks.create_task(scope, %{
          "title" => "Book venue",
          "deadline_kind" => "fixed",
          "deadline_date" => "2028-05-13"
        })

      {:ok, view, _html} = live(conn, ~p"/tasks")

      view |> element("#task-#{task.id}-row") |> render_click()
      assert has_element?(view, "#task-editor-#{task.id}")
      assert has_element?(view, "#task-editor-clear-deadline")

      view |> element("#task-editor-clear-deadline") |> render_click()
      refute has_element?(view, "#task-editor-deadline-date")

      view |> element("#task-editor-#{task.id}") |> render_submit()

      assert has_element?(view, "#task-#{task.id}-deadline", "No deadline")
    end
  end

  describe "link (TSK-01)" do
    test "the linked event navigates to its edit page", %{conn: conn, scope: scope} do
      {:ok, event} = Events.create_event(scope, %{"name" => "Reception"})

      {:ok, task} =
        Tasks.create_task(scope, %{"title" => "Book DJ", "link_event_id" => event.id})

      {:ok, view, _html} = live(conn, ~p"/tasks")

      link_html = view |> element("#task-#{task.id}-link") |> render()
      assert link_html =~ ~p"/events/#{event.id}/edit"
      assert link_html =~ "Reception"
    end
  end

  describe "?open=<id> deep link (activity log path)" do
    test "starts with that task expanded", %{conn: conn, scope: scope} do
      {:ok, task} = Tasks.create_task(scope, %{"title" => "Book caterer"})

      {:ok, view, _html} = live(conn, ~p"/tasks?open=#{task.id}")

      assert has_element?(view, "#task-editor-#{task.id}")
    end
  end

  describe "delete (XC-40)" do
    test "requires confirmation before deleting", %{conn: conn, scope: scope} do
      {:ok, task} = Tasks.create_task(scope, %{"title" => "Book caterer"})

      {:ok, view, _html} = live(conn, ~p"/tasks")

      view |> element("#task-#{task.id}-row") |> render_click()
      refute has_element?(view, "#task-#{task.id}-delete-confirm")

      view |> element("#task-editor-delete") |> render_click()
      assert has_element?(view, "#task-#{task.id}-delete-confirm")

      assert Tasks.get_task!(task.id)
    end

    test "confirming deletes the task and removes its row", %{conn: conn, scope: scope} do
      {:ok, task} = Tasks.create_task(scope, %{"title" => "Book caterer"})

      {:ok, view, _html} = live(conn, ~p"/tasks")

      view |> element("#task-#{task.id}-row") |> render_click()
      view |> element("#task-editor-delete") |> render_click()
      view |> element("#task-#{task.id}-delete-confirm-confirm") |> render_click()

      refute has_element?(view, "#task-#{task.id}-row")
      assert_raise Ecto.NoResultsError, fn -> Tasks.get_task!(task.id) end
    end
  end

  describe "live updates (XC-01, DR-21 no change indicator)" do
    test "a broadcast from the test process updates the list with no change indicator", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      refute render(view) =~ "Book caterer"

      {:ok, task} = Tasks.create_task(scope, %{"title" => "Book caterer"})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "Book caterer"
      assert has_element?(view, "#task-#{task.id}-row")
      # DR-21/XC-02: no highlight, badge or "new" affordance of any kind.
      refute html =~ "new-indicator"
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end

  defp insert_passkey!(user) do
    %Passkey{user_id: user.id, sign_count: 0}
    |> Passkey.registration_changeset(%{
      credential_id: :crypto.strong_rand_bytes(16),
      public_key: :crypto.strong_rand_bytes(16),
      name: "#{user.display_name}'s device",
      registered_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
