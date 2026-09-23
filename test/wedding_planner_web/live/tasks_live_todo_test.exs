defmodule WeddingPlannerWeb.Live.TasksLiveTodoTest do
  @moduledoc """
  `docs/modules/tasks-and-timeline.md` `TSK-20`/`TSK-23`, `05-non-functional.md`
  `NFR-22`/`NFR-31`, `.claude/plans/roadmap.md` `DR-44` — the `/tasks` screen's locked
  todo-list rebuild (task 48): urgency sections, filter chips, the owner filter, URL
  persistence of filter/`open` state, and the desktop (`≥ lg`) master–detail split built
  around `WeddingPlannerWeb.TaskComponents.task_detail/1`.
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks
  alias WeddingPlanner.Tasks.TodoList
  alias WeddingPlannerWeb.Format

  setup %{conn: conn} do
    wannes = insert_user!("Wannes")
    insert_passkey!(wannes)
    bo = insert_user!("Bo")
    insert_passkey!(bo)

    %{conn: log_in_user(conn, wannes), wannes: wannes, bo: bo, scope: Scope.for_user(wannes)}
  end

  defp task!(scope, title, attrs \\ %{}) do
    {:ok, task} = Tasks.create_task(scope, Map.merge(%{"title" => title}, attrs))
    task
  end

  defp today, do: TodoList.today(Format.default_time_zone())

  defp fixed(date), do: %{"deadline_kind" => "fixed", "deadline_date" => Date.to_iso8601(date)}

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

  describe "sections (TSK-20, TSK-23, DR-44)" do
    test "tasks land in the section matching their effective deadline", %{
      conn: conn,
      scope: scope
    } do
      overdue = task!(scope, "Overdue task", fixed(Date.add(today(), -1)))
      this_week = task!(scope, "This week task", fixed(Date.add(today(), 3)))
      later = task!(scope, "Later task", fixed(Date.add(today(), 10)))
      no_deadline = task!(scope, "No deadline task")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert has_element?(view, "#todo-section-overdue-list #task-#{overdue.id}-row")
      assert has_element?(view, "#todo-section-this-week-list #task-#{this_week.id}-row")
      assert has_element?(view, "#todo-section-later-list #task-#{later.id}-row")
      assert has_element?(view, "#todo-section-no-deadline-list #task-#{no_deadline.id}-row")

      assert has_element?(view, "#todo-section-overdue h2", "Overdue (1)")
      assert has_element?(view, "#todo-section-this-week h2", "This week (1)")
      assert has_element?(view, "#todo-section-later h2", "Later (1)")
      assert has_element?(view, "#todo-section-no-deadline h2", "No deadline (1)")
    end

    test "an empty section is omitted entirely", %{conn: conn, scope: scope} do
      _no_deadline = task!(scope, "Only task")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      refute has_element?(view, "#todo-section-overdue")
      refute has_element?(view, "#todo-section-this-week")
      refute has_element?(view, "#todo-section-later")
      assert has_element?(view, "#todo-section-no-deadline")
    end
  end

  describe "filter chips (TSK-20, DR-44)" do
    test "toggling a chip narrows the list and patches the URL", %{conn: conn, scope: scope} do
      prerequisite = task!(scope, "Confirm guest list")
      blocked = task!(scope, "Send invitations")
      {:ok, _} = Tasks.add_dependency(scope, blocked, prerequisite)
      actionable = task!(scope, "Write thank you cards")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert has_element?(view, "#task-#{blocked.id}-row")
      assert has_element?(view, "#task-#{actionable.id}-row")
      assert has_element?(view, "#todo-chip-blocked[aria-pressed=false]")

      view |> element("#todo-chip-blocked") |> render_click()
      assert_patch(view, ~p"/tasks?filter=blocked")

      assert has_element?(view, "#todo-chip-blocked[aria-pressed=true]")
      assert has_element?(view, "#task-#{blocked.id}-row")
      refute has_element?(view, "#task-#{actionable.id}-row")
      assert has_element?(view, "#todo-shown-count", "1 of 3 shown")
    end

    test "actionable and blocked are mutually exclusive", %{conn: conn, scope: scope} do
      prerequisite = task!(scope, "Confirm guest list")
      blocked = task!(scope, "Send invitations")
      {:ok, _} = Tasks.add_dependency(scope, blocked, prerequisite)
      actionable = task!(scope, "Write thank you cards")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      view |> element("#todo-chip-blocked") |> render_click()
      assert_patch(view, ~p"/tasks?filter=blocked")

      view |> element("#todo-chip-actionable") |> render_click()
      assert_patch(view, ~p"/tasks?filter=actionable")

      assert has_element?(view, "#todo-chip-actionable[aria-pressed=true]")
      assert has_element?(view, "#todo-chip-blocked[aria-pressed=false]")
      refute has_element?(view, "#task-#{blocked.id}-row")
      assert has_element?(view, "#task-#{actionable.id}-row")
    end

    test "overdue and this week are mutually exclusive", %{conn: conn, scope: scope} do
      _overdue = task!(scope, "Overdue task", fixed(Date.add(today(), -1)))
      _this_week = task!(scope, "This week task", fixed(Date.add(today(), 3)))

      {:ok, view, _html} = live(conn, ~p"/tasks")

      view |> element("#todo-chip-overdue") |> render_click()
      assert_patch(view, ~p"/tasks?filter=overdue")
      assert has_element?(view, "#todo-chip-overdue[aria-pressed=true]")

      view |> element("#todo-chip-this-week") |> render_click()
      assert_patch(view, ~p"/tasks?filter=this_week")
      assert has_element?(view, "#todo-chip-overdue[aria-pressed=false]")
      assert has_element?(view, "#todo-chip-this-week[aria-pressed=true]")
    end

    test "Clear filters only shows while a filter is active and resets the view", %{
      conn: conn,
      scope: scope
    } do
      _task = task!(scope, "Write thank you cards")

      {:ok, view, _html} = live(conn, ~p"/tasks")
      refute has_element?(view, "#todo-clear-filters")

      view |> element("#todo-chip-actionable") |> render_click()
      assert has_element?(view, "#todo-clear-filters")

      view |> element("#todo-clear-filters") |> render_click()
      assert_patch(view, ~p"/tasks")
      refute has_element?(view, "#todo-clear-filters")
    end
  end

  describe "owner filter (TSK-01, DR-44)" do
    test "filters by a specific owner, including shared tasks", %{
      conn: conn,
      scope: scope,
      bo: bo
    } do
      bos_task = task!(scope, "Bo's task", %{"owner_id" => bo.id})
      shared_task = task!(scope, "Shared task", %{"owner_shared" => "true"})
      unassigned_task = task!(scope, "Unassigned task")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      view
      |> form("#todo-owner-form", filter: %{"owner" => to_string(bo.id)})
      |> render_change()

      assert_patch(view, ~p"/tasks?owner=#{bo.id}")

      assert has_element?(view, "#task-#{bos_task.id}-row")
      assert has_element?(view, "#task-#{shared_task.id}-row")
      refute has_element?(view, "#task-#{unassigned_task.id}-row")
    end

    test "filters to unassigned", %{conn: conn, scope: scope, bo: bo} do
      bos_task = task!(scope, "Bo's task", %{"owner_id" => bo.id})
      unassigned_task = task!(scope, "Unassigned task")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      view
      |> form("#todo-owner-form", filter: %{"owner" => "unassigned"})
      |> render_change()

      assert_patch(view, ~p"/tasks?owner=unassigned")

      refute has_element?(view, "#task-#{bos_task.id}-row")
      assert has_element?(view, "#task-#{unassigned_task.id}-row")
    end
  end

  describe "reload persistence (DR-44)" do
    test "a fresh mount on a filtered URL renders already filtered", %{
      conn: conn,
      scope: scope,
      bo: bo
    } do
      prerequisite = task!(scope, "Confirm guest list")
      blocked = task!(scope, "Send invitations", %{"owner_id" => bo.id})
      {:ok, _} = Tasks.add_dependency(scope, blocked, prerequisite)
      _actionable = task!(scope, "Write thank you cards", %{"owner_id" => bo.id})
      _other_owner_blocked_alike = task!(scope, "Someone else's task")

      {:ok, view, _html} = live(conn, ~p"/tasks?filter=blocked&owner=#{bo.id}")

      assert has_element?(view, "#todo-chip-blocked[aria-pressed=true]")
      assert has_element?(view, "#task-#{blocked.id}-row")
      refute has_element?(view, "#task-#{prerequisite.id}-row")
    end
  end

  describe "desktop master–detail split (DR-44)" do
    test "the layout hook toggles the view mode and the editor renders in exactly one place",
         %{conn: conn, scope: scope} do
      task = task!(scope, "Book caterer")

      {:ok, view, _html} = live(conn, ~p"/tasks?open=#{task.id}")

      stacked_html = render(view)
      assert count_occurrences(stacked_html, ~s(id="task-editor-title")) == 1
      assert has_element?(view, "#todo-section-no-deadline-list #task-editor-title")
      refute has_element?(view, "#todo-detail-panel")

      render_hook(view, "layout", %{"split" => true})

      split_html = render(view)
      assert count_occurrences(split_html, ~s(id="task-editor-title")) == 1
      assert has_element?(view, "#todo-detail-panel #task-editor-title")
      refute has_element?(view, "#todo-section-no-deadline-list #task-editor-title")

      render_hook(view, "layout", %{"split" => false})

      back_to_stacked = render(view)
      assert count_occurrences(back_to_stacked, ~s(id="task-editor-title")) == 1
      assert has_element?(view, "#todo-section-no-deadline-list #task-editor-title")
    end

    test "?open=<id> selects the task in the split layout too", %{conn: conn, scope: scope} do
      task = task!(scope, "Book caterer")

      {:ok, view, _html} = live(conn, ~p"/tasks?open=#{task.id}")
      render_hook(view, "layout", %{"split" => true})

      assert has_element?(view, "#todo-detail-panel #task-editor-#{task.id}")
      refute has_element?(view, "#todo-detail-empty")
    end

    test "with nothing open, the panel shows the empty state", %{conn: conn, scope: scope} do
      _task = task!(scope, "Book caterer")

      {:ok, view, _html} = live(conn, ~p"/tasks")
      render_hook(view, "layout", %{"split" => true})

      assert has_element?(view, "#todo-detail-empty")
    end

    test "TSK-12's one-tap-complete warning is reachable in the panel", %{
      conn: conn,
      scope: scope
    } do
      prerequisite = task!(scope, "Confirm guest list")
      dependent = task!(scope, "Send invitations")
      {:ok, _} = Tasks.add_dependency(scope, dependent, prerequisite)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      render_hook(view, "layout", %{"split" => true})

      view |> element("#task-#{dependent.id}-complete") |> render_click()

      assert has_element?(
               view,
               "#todo-detail-panel #task-#{dependent.id}-done-warning",
               "Still waiting on: 'Confirm guest list'."
             )

      assert Tasks.get_task!(dependent.id).status == :to_do
    end
  end

  describe "one-tap complete inside sections" do
    test "moves a task out of its section into the done disclosure", %{
      conn: conn,
      scope: scope
    } do
      task = task!(scope, "Book caterer", fixed(Date.add(today(), 3)))

      {:ok, view, _html} = live(conn, ~p"/tasks")
      assert has_element?(view, "#todo-section-this-week-list #task-#{task.id}-row")

      view |> element("#task-#{task.id}-complete") |> render_click()

      refute has_element?(view, "#todo-section-this-week")
      assert has_element?(view, "#tasks-done-list #task-#{task.id}-row")
    end
  end

  defp count_occurrences(html, substring) do
    html
    |> String.split(substring)
    |> length()
    |> Kernel.-(1)
  end
end
