defmodule WeddingPlanner.Tasks.DependenciesTest do
  @moduledoc """
  `docs/modules/tasks-and-timeline.md` TSK-10 through TSK-15, `06-decisions.md` DR-35/
  DR-36 (task 42) — dependency storage behind `WeddingPlanner.Tasks`: cycle rejection,
  delete cleanup, effective-deadline listing. Normative example T1
  (`docs/07-normative-examples.md`) is exercised end to end through the context, tagged
  `@tag example: "T1"`.
  """
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Tasks
  alias WeddingPlanner.Tasks.Dependency

  setup do
    wannes = insert_user!("Wannes")
    insert_passkey!(wannes)

    %{scope: Scope.for_user(wannes)}
  end

  defp task!(scope, title) do
    {:ok, task} = Tasks.create_task(scope, %{"title" => title})
    task
  end

  describe "add_dependency/3 and cycle_message/1 — example T1" do
    @describetag example: "T1"

    test "A depends on B, B depends on C; proposing C depends on A is rejected naming A → B → C → A",
         %{scope: scope} do
      a = task!(scope, "A")
      b = task!(scope, "B")
      c = task!(scope, "C")

      assert {:ok, _} = Tasks.add_dependency(scope, a, b)
      assert {:ok, _} = Tasks.add_dependency(scope, b, c)

      dep_count_before = Repo.aggregate(Dependency, :count)
      entry_count_before = Repo.all(Entry) |> length()

      assert {:error, {:cycle, [^a, ^b, ^c, ^a]}} = Tasks.add_dependency(scope, c, a)

      assert Tasks.cycle_message([a, b, c, a]) ==
               "That would create a dependency cycle: A → B → C → A."

      # nothing persisted for the rejected add
      assert Repo.aggregate(Dependency, :count) == dep_count_before
      assert Repo.all(Entry) |> length() == entry_count_before
    end
  end

  describe "add_dependency/3" do
    test "writes one dependency row and one entry on the waiting task", %{scope: scope} do
      caterer = task!(scope, "Book caterer")
      venue = task!(scope, "Confirm venue")

      Realtime.subscribe(:task)
      assert {:ok, _dep} = Tasks.add_dependency(scope, caterer, venue)

      assert Repo.aggregate(Dependency, :count) == 1
      assert [dep] = Repo.all(Dependency)
      assert dep.task_id == caterer.id
      assert dep.depends_on_id == venue.id

      task_entries = Repo.all(Entry) |> Enum.filter(&(&1.entity_type == "task"))
      # one entry from create_task/2 for each of the two tasks, plus one for the edge
      assert length(task_entries) == 3

      edge_entry =
        Enum.find(task_entries, &(&1.entity_id == caterer.id and &1.description =~ "wait on"))

      assert edge_entry.description ==
               "Wannes made 'Book caterer' wait on 'Confirm venue'"

      assert_received {Realtime, :task, {:updated, updated}}
      assert updated.id == caterer.id
    end

    test "a duplicate add returns :already_exists and writes nothing", %{scope: scope} do
      caterer = task!(scope, "Book caterer")
      venue = task!(scope, "Confirm venue")

      assert {:ok, _} = Tasks.add_dependency(scope, caterer, venue)
      count_before = Repo.aggregate(Dependency, :count)
      entries_before = Repo.all(Entry) |> length()

      assert {:error, :already_exists} = Tasks.add_dependency(scope, caterer, venue)

      assert Repo.aggregate(Dependency, :count) == count_before
      assert Repo.all(Entry) |> length() == entries_before
    end

    test "a self-dependency is the cycle [task, task]", %{scope: scope} do
      caterer = task!(scope, "Book caterer")
      entries_before = Repo.all(Entry) |> length()

      assert {:error, {:cycle, [^caterer, ^caterer]}} =
               Tasks.add_dependency(scope, caterer, caterer)

      assert Repo.aggregate(Dependency, :count) == 0
      assert Repo.all(Entry) |> length() == entries_before
    end

    test "a missing task returns :not_found and writes nothing", %{scope: scope} do
      caterer = task!(scope, "Book caterer")
      {:ok, deleted} = Tasks.create_task(scope, %{"title" => "Deleted"})
      {:ok, _} = Tasks.delete_task(scope, deleted)

      assert {:error, :not_found} = Tasks.add_dependency(scope, caterer, deleted)
      assert {:error, :not_found} = Tasks.add_dependency(scope, deleted, caterer)

      assert Repo.aggregate(Dependency, :count) == 0
    end
  end

  describe "remove_dependency/3" do
    test "writes one entry on the waiting task", %{scope: scope} do
      caterer = task!(scope, "Book caterer")
      venue = task!(scope, "Confirm venue")
      {:ok, _} = Tasks.add_dependency(scope, caterer, venue)

      entries_before = Repo.all(Entry) |> length()

      Realtime.subscribe(:task)
      assert {:ok, _} = Tasks.remove_dependency(scope, caterer, venue)

      assert Repo.aggregate(Dependency, :count) == 0
      assert Repo.all(Entry) |> length() == entries_before + 1

      entry = Repo.all(Entry) |> Enum.max_by(& &1.id)

      assert entry.description ==
               "Wannes removed 'Confirm venue' from what 'Book caterer' waits on"

      assert entry.entity_type == "task"
      assert entry.entity_id == caterer.id

      assert_received {Realtime, :task, {:updated, updated}}
      assert updated.id == caterer.id
    end

    test "removing a non-existent edge returns :not_found", %{scope: scope} do
      caterer = task!(scope, "Book caterer")
      venue = task!(scope, "Confirm venue")

      assert {:error, :not_found} = Tasks.remove_dependency(scope, caterer, venue)
    end
  end

  describe "database constraints (bypassing the changeset)" do
    test "the CHECK rejects a raw self-edge insert", %{scope: scope} do
      caterer = task!(scope, "Book caterer")

      assert_raise Ecto.ConstraintError, fn ->
        %Dependency{task_id: caterer.id, depends_on_id: caterer.id}
        |> Ecto.Changeset.change()
        |> Repo.insert()
      end
    end

    test "the unique index rejects a raw duplicate", %{scope: scope} do
      caterer = task!(scope, "Book caterer")
      venue = task!(scope, "Confirm venue")
      {:ok, _} = Tasks.add_dependency(scope, caterer, venue)

      assert_raise Ecto.ConstraintError, fn ->
        %Dependency{task_id: caterer.id, depends_on_id: venue.id}
        |> Ecto.Changeset.change()
        |> Repo.insert()
      end
    end
  end

  describe "delete_task/2 with waiters (DR-36)" do
    test "deleting a prerequisite with two waiters logs a summary, one child per waiter, and its own entry",
         %{scope: scope} do
      venue = task!(scope, "Confirm venue")
      caterer = task!(scope, "Book caterer")
      menus = task!(scope, "Print menus")

      {:ok, _} = Tasks.add_dependency(scope, caterer, venue)
      {:ok, _} = Tasks.add_dependency(scope, menus, venue)

      assert Tasks.task_deletion_effects(venue) == [
               %{
                 label:
                   "2 tasks wait on this: 'Book caterer', 'Print menus' (the dependency is removed)",
                 count: 2
               }
             ]

      Realtime.subscribe(:task)
      assert {:ok, deleted} = Tasks.delete_task(scope, venue)
      assert deleted.id == venue.id

      assert Repo.aggregate(Dependency, :count) == 0

      entries =
        Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created"))

      summary =
        Enum.find(
          entries,
          &(is_nil(&1.parent_id) and &1.description == "Wannes deleted task 'Confirm venue'")
        )

      assert summary
      assert is_nil(summary.entity_type)

      children = Enum.filter(entries, &(&1.parent_id == summary.id))
      descriptions = children |> Enum.map(& &1.description) |> Enum.sort()

      assert descriptions == [
               "'Book caterer' no longer waits on 'Confirm venue' (task deleted)",
               "'Print menus' no longer waits on 'Confirm venue' (task deleted)",
               "Wannes deleted task 'Confirm venue'"
             ]

      own_entry =
        Enum.find(children, &(&1.description == "Wannes deleted task 'Confirm venue'"))

      assert own_entry.entity_type == "task"
      assert own_entry.entity_id == venue.id

      caterer_entry =
        Enum.find(
          children,
          &(&1.description == "'Book caterer' no longer waits on 'Confirm venue' (task deleted)")
        )

      assert caterer_entry.entity_type == "task"
      assert caterer_entry.entity_id == caterer.id

      id = venue.id
      assert_received {Realtime, :task, {:updated, updated_1}}
      assert_received {Realtime, :task, {:updated, updated_2}}
      assert_received {Realtime, :task, {:deleted, ^id}}

      assert Enum.map([updated_1, updated_2], & &1.id) |> Enum.sort() ==
               Enum.sort([caterer.id, menus.id])
    end

    test "deleting a waiter removes its own edges with a single delete entry", %{scope: scope} do
      venue = task!(scope, "Confirm venue")
      caterer = task!(scope, "Book caterer")
      {:ok, _} = Tasks.add_dependency(scope, caterer, venue)

      Realtime.subscribe(:task)
      assert {:ok, _} = Tasks.delete_task(scope, caterer)

      assert Repo.aggregate(Dependency, :count) == 0

      entry =
        Repo.all(Entry) |> Enum.find(&(&1.description == "Wannes deleted task 'Book caterer'"))

      assert entry
      assert entry.entity_id == caterer.id

      id = caterer.id
      assert_received {Realtime, :task, {:deleted, ^id}}
      refute_received {Realtime, :task, {:updated, _}}
    end

    test "task_deletion_effects/1 is [] when nothing waits on the task", %{scope: scope} do
      venue = task!(scope, "Confirm venue")
      assert Tasks.task_deletion_effects(venue) == []
    end
  end

  describe "list_tasks_with_graph/0 (TSK-13) — example T2" do
    @describetag example: "T2"

    test "Confirm venue (no deadline) sorts at Book caterer's 1 March, not last", %{
      scope: scope
    } do
      {:ok, caterer} =
        Tasks.create_task(scope, %{
          "title" => "Book caterer",
          "deadline_kind" => "fixed",
          "deadline_date" => "2027-03-01"
        })

      venue = task!(scope, "Confirm venue")
      {:ok, _} = Tasks.add_dependency(scope, caterer, venue)

      # a later-dated distractor: under the old own-deadline sort, dateless "Confirm
      # venue" would sort last (after this); under TSK-13's effective-deadline sort it
      # must sort at 1 March instead, ahead of it.
      {:ok, later} =
        Tasks.create_task(scope, %{
          "title" => "Send thank-you cards",
          "deadline_kind" => "fixed",
          "deadline_date" => "2027-06-01"
        })

      {tasks, graph} = Tasks.list_tasks_with_graph()

      # caterer and venue tie at 2027-03-01; title tiebreak ("book caterer" < "confirm
      # venue") orders caterer first, both ahead of the later-dated distractor.
      assert Enum.map(tasks, & &1.id) == [caterer.id, venue.id, later.id]
      assert WeddingPlanner.Tasks.Graph.effective_deadline(graph, venue.id) == ~D[2027-03-01]
    end

    test "list_tasks/0 delegates and returns just the sorted tasks", %{scope: scope} do
      {:ok, caterer} =
        Tasks.create_task(scope, %{
          "title" => "Book caterer",
          "deadline_kind" => "fixed",
          "deadline_date" => "2027-03-01"
        })

      venue = task!(scope, "Confirm venue")
      {:ok, _} = Tasks.add_dependency(scope, caterer, venue)

      assert Enum.map(Tasks.list_tasks(), & &1.id) == [caterer.id, venue.id]
    end
  end

  describe "list_tasks_with_graph/0 query count is bounded" do
    test "issues the same number of Repo queries for 3 tasks as for 30", %{scope: scope} do
      count_3 = count_queries_for(scope, 3)
      count_30 = count_queries_for(scope, 30)

      assert count_3 == count_30
    end

    defp count_queries_for(scope, n) do
      for i <- 1..n, do: task!(scope, "Task #{i}")

      test_pid = self()
      ref = make_ref()

      handler = fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: send(test_pid, {:query, ref})
      end

      handler_id = {:dependencies_test, ref}

      :telemetry.attach(
        handler_id,
        [:wedding_planner, :repo, :query],
        handler,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Tasks.list_tasks_with_graph()

      :telemetry.detach(handler_id)

      count = count_messages(ref, 0)
      count
    end

    defp count_messages(ref, acc) do
      receive do
        {:query, ^ref} -> count_messages(ref, acc + 1)
      after
        0 -> acc
      end
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
