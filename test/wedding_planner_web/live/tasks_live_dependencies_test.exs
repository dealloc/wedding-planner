defmodule WeddingPlannerWeb.Live.TasksLiveDependenciesTest do
  @moduledoc """
  `docs/modules/tasks-and-timeline.md` `TSK-10`–`TSK-15`, `06-decisions.md` `DR-35`/
  `DR-36`, `04-cross-cutting.md` `XC-01`/`XC-40` — the `/tasks` screen's dependency
  editor, Blocked badge, effective deadlines, conflicts and `TSK-12` warnings (task 43).
  Normative examples T1–T3 (`docs/07-normative-examples.md`) are exercised end to end
  through the UI, tagged `@tag example: "T1"`/`"T2"`/`"T3"`.
  """
  use WeddingPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks

  setup %{conn: conn} do
    wannes = insert_user!("Wannes")
    insert_passkey!(wannes)

    %{conn: log_in_user(conn, wannes), scope: Scope.for_user(wannes)}
  end

  defp task!(scope, title, attrs \\ %{}) do
    {:ok, task} = Tasks.create_task(scope, Map.merge(%{"title" => title}, attrs))
    task
  end

  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp empty?(html, selector), do: html |> find(selector) |> Enum.empty?()

  @tag example: "T1"
  test "proposing a dependency that would close a loop is rejected, naming the chain, and adds no chip",
       %{conn: conn, scope: scope} do
    a = task!(scope, "A")
    b = task!(scope, "B")
    c = task!(scope, "C")

    {:ok, _} = Tasks.add_dependency(scope, a, b)
    {:ok, _} = Tasks.add_dependency(scope, b, c)

    {:ok, view, _html} = live(conn, ~p"/tasks?open=#{c.id}")

    view
    |> form("#task-#{c.id}-dep-add-form", %{"task_id" => c.id, "dep_id" => a.id})
    |> render_change()

    assert render(view) =~
             "That would create a dependency cycle: A → B → C → A. Rejected — pick something else."

    refute has_element?(view, "#task-#{c.id}-dep-#{a.id}")
  end

  @tag example: "T2"
  test "a no-deadline task gains its dependent's effective deadline and sorts next to it", %{
    conn: conn,
    scope: scope
  } do
    venue = task!(scope, "Confirm venue")

    caterer =
      task!(scope, "Book caterer", %{"deadline_kind" => "fixed", "deadline_date" => "2030-03-01"})

    unrelated = task!(scope, "Write thank you notes")

    {:ok, _} = Tasks.add_dependency(scope, caterer, venue)

    {:ok, view, _html} = live(conn, ~p"/tasks")

    assert has_element?(view, "#task-#{venue.id}-deadline", "01/03/2030")
    assert has_element?(view, "#task-#{venue.id}-deadline", "needed by 'Book caterer'")

    row_order =
      render(view)
      |> then(&Regex.scan(~r/id="task-(\d+)-row"/, &1))
      |> Enum.map(fn [_, id] -> String.to_integer(id) end)

    venue_index = Enum.find_index(row_order, &(&1 == venue.id))
    caterer_index = Enum.find_index(row_order, &(&1 == caterer.id))
    unrelated_index = Enum.find_index(row_order, &(&1 == unrelated.id))

    assert abs(venue_index - caterer_index) == 1
    assert unrelated_index > caterer_index and unrelated_index > venue_index
  end

  @tag example: "T3"
  test "a conflicting own deadline shows a warning and disappears once moved earlier", %{
    conn: conn,
    scope: scope
  } do
    venue =
      task!(scope, "Confirm venue", %{"deadline_kind" => "fixed", "deadline_date" => "2030-03-15"})

    caterer =
      task!(scope, "Book caterer", %{"deadline_kind" => "fixed", "deadline_date" => "2030-03-01"})

    {:ok, _} = Tasks.add_dependency(scope, caterer, venue)

    {:ok, view, _html} = live(conn, ~p"/tasks")

    assert has_element?(view, "#task-#{venue.id}-conflict", "Book caterer")

    view |> element("#task-#{venue.id}-row") |> render_click()

    view
    |> form("#task-editor-#{venue.id}",
      task: %{
        "title" => "Confirm venue",
        "deadline_kind" => "fixed",
        "deadline_date" => "2030-02-01"
      }
    )
    |> render_submit()

    refute has_element?(view, "#task-#{venue.id}-conflict")
  end

  describe "dependency chips" do
    test "adding then removing toggles the chip and the Blocked badge, not-done only", %{
      conn: conn,
      scope: scope
    } do
      dependent = task!(scope, "Send invitations")
      prerequisite = task!(scope, "Confirm guest list")

      {:ok, view, _html} = live(conn, ~p"/tasks?open=#{dependent.id}")

      refute has_element?(view, "#task-#{dependent.id}-blocked")

      view
      |> form("#task-#{dependent.id}-dep-add-form", %{
        "task_id" => dependent.id,
        "dep_id" => prerequisite.id
      })
      |> render_change()

      assert has_element?(view, "#task-#{dependent.id}-dep-#{prerequisite.id}")
      assert has_element?(view, "#task-#{dependent.id}-blocked")

      {:ok, _} = Tasks.update_task(scope, prerequisite, %{"status" => "done"})
      _ = :sys.get_state(view.pid)
      refute has_element?(view, "#task-#{dependent.id}-blocked")

      view |> element("#task-#{dependent.id}-dep-#{prerequisite.id}-remove") |> render_click()
      refute has_element?(view, "#task-#{dependent.id}-dep-#{prerequisite.id}")
    end

    test "a blocked done task never shows the Blocked badge (DR-35 shown only on not-done)", %{
      conn: conn,
      scope: scope
    } do
      prerequisite = task!(scope, "Confirm guest list")
      done_task = task!(scope, "Print place cards", %{"status" => "done"})
      {:ok, _} = Tasks.add_dependency(scope, done_task, prerequisite)

      {:ok, view, _html} = live(conn, ~p"/tasks")

      refute has_element?(view, "#task-#{done_task.id}-blocked")
    end
  end

  describe "TSK-12 — completing a blocked task" do
    test "the circle shows a warning naming the prerequisite instead of completing it, with Cancel/Mark done anyway",
         %{conn: conn, scope: scope} do
      dependent = task!(scope, "Send invitations")
      prerequisite = task!(scope, "Confirm guest list")
      {:ok, _} = Tasks.add_dependency(scope, dependent, prerequisite)

      {:ok, view, _html} = live(conn, ~p"/tasks")

      view |> element("#task-#{dependent.id}-complete") |> render_click()

      assert has_element?(
               view,
               "#task-#{dependent.id}-done-warning",
               "Still waiting on: 'Confirm guest list'."
             )

      assert Tasks.get_task!(dependent.id).status == :to_do
      assert has_element?(view, "#tasks #task-#{dependent.id}-row")

      view |> element("#task-#{dependent.id}-done-cancel") |> render_click()
      refute has_element?(view, "#task-#{dependent.id}-done-warning")
      assert Tasks.get_task!(dependent.id).status == :to_do

      view |> element("#task-#{dependent.id}-complete") |> render_click()
      view |> element("#task-#{dependent.id}-done-anyway") |> render_click()

      assert Tasks.get_task!(dependent.id).status == :done
      assert has_element?(view, "#tasks-done-list #task-#{dependent.id}-row")
    end

    test "a non-blocked task still completes in one tap", %{conn: conn, scope: scope} do
      task = task!(scope, "Write thank you notes")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      view |> element("#task-#{task.id}-complete") |> render_click()

      assert Tasks.get_task!(task.id).status == :done
      refute has_element?(view, "#task-#{task.id}-done-warning")
    end
  end

  describe "TSK-12 — in the editor" do
    test "selecting Done on a blocked task shows the inline warning under the status select", %{
      conn: conn,
      scope: scope
    } do
      dependent = task!(scope, "Send invitations")
      prerequisite = task!(scope, "Confirm guest list")
      {:ok, _} = Tasks.add_dependency(scope, dependent, prerequisite)

      {:ok, view, _html} = live(conn, ~p"/tasks?open=#{dependent.id}")

      view
      |> form("#task-editor-#{dependent.id}",
        task: %{"title" => "Send invitations", "status" => "done"}
      )
      |> render_change()

      assert has_element?(
               view,
               "#task-editor-blocked-warning",
               "Still waiting on: 'Confirm guest list'."
             )
    end
  end

  describe "no nested form (design bug, .claude/design/ui-decisions.md §5)" do
    test "the dependency add form is a sibling of the editor form, not nested inside it", %{
      conn: conn,
      scope: scope
    } do
      task = task!(scope, "Send invitations")
      _other = task!(scope, "Confirm guest list")

      {:ok, view, _html} = live(conn, ~p"/tasks?open=#{task.id}")

      html = render(view)
      assert empty?(html, "#task-editor-#{task.id} #task-#{task.id}-dep-add-form")
      refute empty?(html, "#task-#{task.id}-dep-add-form")
    end
  end

  describe "TSK-15 — transitive trees" do
    test "a 3-deep chain shows the grandchild inside a nested <details> under 'Waits on'", %{
      conn: conn,
      scope: scope
    } do
      a = task!(scope, "A")
      b = task!(scope, "B")
      c = task!(scope, "C")

      {:ok, _} = Tasks.add_dependency(scope, a, b)
      {:ok, _} = Tasks.add_dependency(scope, b, c)

      {:ok, view, _html} = live(conn, ~p"/tasks?open=#{a.id}")

      assert has_element?(view, "#task-#{a.id}-waits-on-tree details", "C")
    end
  end

  describe "delete confirmation (XC-40)" do
    test "lists the tasks waiting on it", %{conn: conn, scope: scope} do
      prerequisite = task!(scope, "Confirm guest list")
      dependent = task!(scope, "Send invitations")
      {:ok, _} = Tasks.add_dependency(scope, dependent, prerequisite)

      {:ok, view, _html} = live(conn, ~p"/tasks?open=#{prerequisite.id}")

      view |> element("#task-editor-delete") |> render_click()

      assert has_element?(
               view,
               "#task-#{prerequisite.id}-delete-confirm",
               "Send invitations"
             )
    end
  end

  describe "live updates (XC-01)" do
    test "a dependency added through the context re-renders the Blocked badge with no interaction",
         %{conn: conn, scope: scope} do
      dependent = task!(scope, "Send invitations")
      prerequisite = task!(scope, "Confirm guest list")

      {:ok, view, _html} = live(conn, ~p"/tasks")
      refute has_element?(view, "#task-#{dependent.id}-blocked")

      {:ok, _} = Tasks.add_dependency(scope, dependent, prerequisite)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#task-#{dependent.id}-blocked")
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
