defmodule WeddingPlanner.TasksTest do
  @moduledoc """
  `docs/modules/tasks-and-timeline.md` TSK-01 through TSK-04, `04-cross-cutting.md`
  XC-10/XC-01/XC-02/XC-12/XC-41, `04-cross-cutting.md`/`guests-and-events.md` EVT-05,
  `06-decisions.md` D-10/D-28, `DR-22`, `DR-26` Q1/Q16/Q17 — the tasks context, task 30's
  data layer.
  """
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Accounts.Passkey
  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Events
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Log.EntityRef
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Tasks

  setup do
    wannes = insert_user!("Wannes")
    insert_passkey!(wannes)
    bo = insert_user!("Bo")
    insert_passkey!(bo)
    provisional = insert_user!("Aaron")

    %{wannes: wannes, bo: bo, provisional: provisional, scope: Scope.for_user(wannes)}
  end

  describe "create_task/2" do
    test "creates a task with just a title, defaulting status/deadline/owner", %{scope: scope} do
      assert {:ok, task} = Tasks.create_task(scope, %{"title" => "Book caterer"})

      assert task.title == "Book caterer"
      assert task.status == :to_do
      assert task.deadline_kind == :none
      assert is_nil(task.owner_id)
      assert task.owner_shared == false
    end

    test "requires a title", %{scope: scope} do
      assert {:error, changeset} = Tasks.create_task(scope, %{"title" => ""})
      assert "can't be blank" in errors_on(changeset).title
    end

    test "logs the create (XC-10)", %{scope: scope, wannes: wannes} do
      assert {:ok, task} = Tasks.create_task(scope, %{"title" => "Book caterer"})

      entry = Repo.one!(Entry)
      assert entry.user_id == wannes.id
      assert entry.entity_type == "task"
      assert entry.entity_id == task.id
      assert entry.description == "Wannes created task 'Book caterer'"
    end

    test "broadcasts {:created, task} (XC-01)", %{scope: scope} do
      Realtime.subscribe(:task)
      assert {:ok, task} = Tasks.create_task(scope, %{"title" => "Book caterer"})

      assert_received {Realtime, :task, {:created, ^task}}
    end

    test "accepts an assignable owner", %{scope: scope, bo: bo} do
      assert {:ok, task} =
               Tasks.create_task(scope, %{"title" => "Book caterer", "owner_id" => bo.id})

      assert task.owner_id == bo.id
    end

    test "accepts a shared owner", %{scope: scope} do
      assert {:ok, task} =
               Tasks.create_task(scope, %{"title" => "Book caterer", "owner_shared" => true})

      assert task.owner_shared == true
      assert is_nil(task.owner_id)
    end

    test "rejects an owner with no passkey (DR-22, provisional user)", %{
      scope: scope,
      provisional: provisional
    } do
      assert {:error, changeset} =
               Tasks.create_task(scope, %{"title" => "Book caterer", "owner_id" => provisional.id})

      assert "must be a user with a registered passkey" in errors_on(changeset).owner_id
    end

    test "rejects an owner id that does not exist at all", %{scope: scope} do
      assert {:error, changeset} =
               Tasks.create_task(scope, %{"title" => "Book caterer", "owner_id" => -1})

      assert "must be a user with a registered passkey" in errors_on(changeset).owner_id
    end
  end

  describe "list_tasks/0 ordering" do
    test "orders chronologically across a month boundary, not by day-of-month", %{scope: scope} do
      # Regression guard: comparing raw %Date{} structs with the default term ordering
      # sorts by field order (day before month before year), which would put
      # "2028-02-01" (day 1) before "2028-01-05" (day 5) — the wrong, non-chronological
      # order. `Tasks.list_tasks/0` must sort by actual calendar order.
      {:ok, later} =
        Tasks.create_task(scope, %{
          "title" => "Later in Feb",
          "deadline_kind" => "fixed",
          "deadline_date" => "2028-02-01"
        })

      {:ok, earlier} =
        Tasks.create_task(scope, %{
          "title" => "Earlier in Jan",
          "deadline_kind" => "fixed",
          "deadline_date" => "2028-01-05"
        })

      assert Enum.map(Tasks.list_tasks(), & &1.id) == [earlier.id, later.id]
    end

    test "a resolved relative deadline sorts alongside fixed deadlines by actual date", %{
      scope: scope
    } do
      {:ok, reception} =
        Events.create_event(scope, %{"name" => "Reception", "date" => "2028-05-13"})

      {:ok, relative} =
        Tasks.create_task(scope, %{
          "title" => "Send invitations",
          "deadline_kind" => "relative",
          "deadline_amount" => "12",
          "deadline_unit" => "weeks",
          "deadline_direction" => "before",
          "deadline_event_id" => reception.id
        })

      {:ok, fixed_before} =
        Tasks.create_task(scope, %{
          "title" => "Book venue",
          "deadline_kind" => "fixed",
          "deadline_date" => "2028-01-01"
        })

      {:ok, fixed_after} =
        Tasks.create_task(scope, %{
          "title" => "Send thank-you cards",
          "deadline_kind" => "fixed",
          "deadline_date" => "2028-06-01"
        })

      # relative resolves to 2028-02-19: between fixed_before (01-01) and fixed_after (06-01)
      assert Enum.map(Tasks.list_tasks(), & &1.id) == [
               fixed_before.id,
               relative.id,
               fixed_after.id
             ]
    end

    test "none and unresolved deadlines sort last, after every dated task, then by title", %{
      scope: scope
    } do
      {:ok, dateless} = Events.create_event(scope, %{"name" => "Reception"})

      {:ok, unresolved} =
        Tasks.create_task(scope, %{
          "title" => "Zzz unresolved",
          "deadline_kind" => "relative",
          "deadline_amount" => "1",
          "deadline_unit" => "weeks",
          "deadline_direction" => "before",
          "deadline_event_id" => dateless.id
        })

      {:ok, no_deadline_b} = Tasks.create_task(scope, %{"title" => "B task, no deadline"})
      {:ok, no_deadline_a} = Tasks.create_task(scope, %{"title" => "A task, no deadline"})

      {:ok, dated} =
        Tasks.create_task(scope, %{
          "title" => "Dated task",
          "deadline_kind" => "fixed",
          "deadline_date" => "2028-01-01"
        })

      assert Enum.map(Tasks.list_tasks(), & &1.id) == [
               dated.id,
               no_deadline_a.id,
               no_deadline_b.id,
               unresolved.id
             ]
    end

    test "title tiebreak is case-insensitive", %{scope: scope} do
      {:ok, upper} = Tasks.create_task(scope, %{"title" => "Zebra"})
      {:ok, lower} = Tasks.create_task(scope, %{"title" => "apple"})

      assert Enum.map(Tasks.list_tasks(), & &1.id) == [lower.id, upper.id]
    end

    test "preloads owner, deadline event and link event", %{scope: scope, bo: bo} do
      {:ok, reception} = Events.create_event(scope, %{"name" => "Reception"})

      {:ok, _task} =
        Tasks.create_task(scope, %{
          "title" => "Book venue",
          "owner_id" => bo.id,
          "link_event_id" => reception.id
        })

      [task] = Tasks.list_tasks()
      assert %User{} = task.owner
      assert %Event{} = task.link_event
    end
  end

  describe "update_task/3 per-field logging (XC-10)" do
    setup %{scope: scope} do
      {:ok, task} = Tasks.create_task(scope, %{"title" => "Book caterer"})
      %{task: task}
    end

    defp entries_after_create do
      Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created"))
    end

    test "status change", %{scope: scope, task: task} do
      {:ok, _updated} = Tasks.update_task(scope, task, %{"status" => "done"})

      assert [entry] = entries_after_create()
      assert entry.description == "Wannes changed the status of 'Book caterer': to do → done"
    end

    test "owner change from nobody to a user", %{scope: scope, task: task, bo: bo} do
      {:ok, _updated} = Tasks.update_task(scope, task, %{"owner_id" => bo.id})

      assert [entry] = entries_after_create()
      assert entry.description == "Wannes changed the owner of 'Book caterer': Nobody → Bo"
    end

    test "owner change to shared", %{scope: scope, task: task} do
      {:ok, _updated} = Tasks.update_task(scope, task, %{"owner_shared" => true})

      assert [entry] = entries_after_create()
      assert entry.description == "Wannes changed the owner of 'Book caterer': Nobody → Both"
    end

    test "rejects a non-assignable owner on update", %{
      scope: scope,
      task: task,
      provisional: provisional
    } do
      assert {:error, changeset} = Tasks.update_task(scope, task, %{"owner_id" => provisional.id})
      assert "must be a user with a registered passkey" in errors_on(changeset).owner_id
    end

    test "deadline change counts as one entry however many columns changed", %{
      scope: scope,
      task: task
    } do
      {:ok, reception} = Events.create_event(scope, %{"name" => "Reception"})

      {:ok, _updated} =
        Tasks.update_task(scope, task, %{
          "deadline_kind" => "relative",
          "deadline_amount" => "12",
          "deadline_unit" => "weeks",
          "deadline_direction" => "before",
          "deadline_event_id" => reception.id
        })

      entries = entries_after_create() |> Enum.reject(&(&1.description =~ "created event"))
      assert [entry] = entries

      assert entry.description ==
               "Wannes changed the deadline of 'Book caterer': none → 12 weeks before Reception"
    end

    test "link change (event)", %{scope: scope, task: task} do
      {:ok, reception} = Events.create_event(scope, %{"name" => "Reception"})
      {:ok, _updated} = Tasks.update_task(scope, task, %{"link_event_id" => reception.id})

      entries = entries_after_create() |> Enum.reject(&(&1.description =~ "created event"))
      assert [entry] = entries

      assert entry.description ==
               "Wannes changed the link of 'Book caterer': none → event 'Reception'"
    end

    test "link change (category, task 32/DR-26 Q18)", %{scope: scope, task: task} do
      {:ok, venue} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, _updated} = Tasks.update_task(scope, task, %{"link_category_id" => venue.id})

      entries = entries_after_create() |> Enum.reject(&(&1.description =~ "created category"))
      assert [entry] = entries

      assert entry.description ==
               "Wannes changed the link of 'Book caterer': none → category 'Venue'"
    end

    test "switching the link from an event to a category counts as one entry", %{
      scope: scope,
      task: task
    } do
      {:ok, reception} = Events.create_event(scope, %{"name" => "Reception"})
      {:ok, task} = Tasks.update_task(scope, task, %{"link_event_id" => reception.id})

      {:ok, venue} = Categories.create_category(scope, %{"name" => "Venue"})

      {:ok, _updated} =
        Tasks.update_task(scope, task, %{
          "link_event_id" => "",
          "link_category_id" => venue.id
        })

      entries =
        entries_after_create()
        |> Enum.reject(
          &(&1.description =~ "created event" or &1.description =~ "created category")
        )

      assert [_first, second] = entries

      assert second.description ==
               "Wannes changed the link of 'Book caterer': event 'Reception' → category 'Venue'"
    end

    test "title change", %{scope: scope, task: task} do
      {:ok, _updated} = Tasks.update_task(scope, task, %{"title" => "Book the caterer"})

      assert [entry] = entries_after_create()

      assert entry.description ==
               "Wannes changed the title of 'Book caterer': Book caterer → Book the caterer"
    end

    test "notes change, 'none' shown for a blank starting value", %{scope: scope, task: task} do
      {:ok, _updated} = Tasks.update_task(scope, task, %{"notes" => "Ask about vegan options"})

      assert [entry] = entries_after_create()

      assert entry.description ==
               "Wannes changed the notes of 'Book caterer': none → Ask about vegan options"
    end

    test "logs nothing when nothing user-facing changed", %{scope: scope, task: task} do
      {:ok, _updated} = Tasks.update_task(scope, task, %{"title" => task.title})

      assert entries_after_create() == []
    end

    test "broadcasts {:updated, task} (XC-01)", %{scope: scope, task: task} do
      Realtime.subscribe(:task)
      assert {:ok, updated} = Tasks.update_task(scope, task, %{"status" => "done"})

      assert_received {Realtime, :task, {:updated, ^updated}}
    end
  end

  describe "delete_task/2" do
    test "deletes, logs and broadcasts", %{scope: scope} do
      {:ok, task} = Tasks.create_task(scope, %{"title" => "Book caterer"})
      Realtime.subscribe(:task)

      assert {:ok, _} = Tasks.delete_task(scope, task)
      assert_raise Ecto.NoResultsError, fn -> Tasks.get_task!(task.id) end

      entry =
        Repo.all(Entry) |> Enum.find(&(&1.description == "Wannes deleted task 'Book caterer'"))

      assert entry
      assert entry.entity_id == task.id

      id = task.id
      assert_received {Realtime, :task, {:deleted, ^id}}
    end
  end

  describe "detach_event/2 (XC-41, EVT-05, DR-26 Q1)" do
    test "a task both anchored and linked to the same event gets one update and two log entries",
         %{scope: scope} do
      {:ok, event} = Events.create_event(scope, %{"name" => "Reception", "date" => "2028-05-13"})

      {:ok, task} =
        Tasks.create_task(scope, %{
          "title" => "Both",
          "deadline_kind" => "relative",
          "deadline_amount" => "1",
          "deadline_unit" => "weeks",
          "deadline_direction" => "before",
          "deadline_event_id" => event.id,
          "link_event_id" => event.id
        })

      assert [updated] = Tasks.detach_event(scope, event)
      assert updated.id == task.id
      assert updated.deadline_kind == :none
      assert is_nil(updated.deadline_event_id)
      assert is_nil(updated.link_event_id)

      descriptions =
        Repo.all(Entry)
        |> Enum.map(& &1.description)
        |> Enum.filter(&(&1 =~ "cleared"))
        |> Enum.sort()

      assert descriptions == [
               "Wannes cleared the deadline of 'Both': 1 week before Reception → none (event 'Reception' was deleted)",
               "Wannes cleared the link of 'Both': event 'Reception' → none (event 'Reception' was deleted)"
             ]
    end

    test "a task unrelated to the event is left untouched", %{scope: scope} do
      {:ok, event} = Events.create_event(scope, %{"name" => "Reception"})
      {:ok, other_event} = Events.create_event(scope, %{"name" => "Ceremony"})

      {:ok, unrelated} =
        Tasks.create_task(scope, %{"title" => "Unrelated", "link_event_id" => other_event.id})

      assert Tasks.detach_event(scope, event) == []

      reloaded = Tasks.get_task!(unrelated.id)
      assert reloaded.link_event_id == other_event.id
    end
  end

  describe "event_deadline_reference/1 (EVT-05 provider)" do
    test "nil when no task anchors a deadline on the event", %{scope: scope} do
      {:ok, event} = Events.create_event(scope, %{"name" => "Reception"})
      assert Tasks.event_deadline_reference(event) == nil
    end

    test "singular wording for exactly one", %{scope: scope} do
      {:ok, event} = Events.create_event(scope, %{"name" => "Reception"})

      {:ok, _task} =
        Tasks.create_task(scope, %{
          "title" => "Send invitations",
          "deadline_kind" => "relative",
          "deadline_amount" => "1",
          "deadline_unit" => "weeks",
          "deadline_direction" => "before",
          "deadline_event_id" => event.id
        })

      assert Tasks.event_deadline_reference(event) == %{
               label: "1 task with a deadline relative to this event (deadline becomes none)",
               count: 1
             }
    end

    test "plural wording for more than one", %{scope: scope} do
      {:ok, event} = Events.create_event(scope, %{"name" => "Reception"})

      for title <- ["A", "B"] do
        Tasks.create_task(scope, %{
          "title" => title,
          "deadline_kind" => "relative",
          "deadline_amount" => "1",
          "deadline_unit" => "weeks",
          "deadline_direction" => "before",
          "deadline_event_id" => event.id
        })
      end

      assert Tasks.event_deadline_reference(event) == %{
               label: "2 tasks with a deadline relative to this event (deadline becomes none)",
               count: 2
             }
    end
  end

  describe "event_link_reference/1 (EVT-05 provider)" do
    test "nil when no task links to the event", %{scope: scope} do
      {:ok, event} = Events.create_event(scope, %{"name" => "Reception"})
      assert Tasks.event_link_reference(event) == nil
    end

    test "singular wording for exactly one", %{scope: scope} do
      {:ok, event} = Events.create_event(scope, %{"name" => "Reception"})

      {:ok, _task} =
        Tasks.create_task(scope, %{"title" => "Book florist", "link_event_id" => event.id})

      assert Tasks.event_link_reference(event) == %{
               label: "1 task linked to this event (link removed)",
               count: 1
             }
    end

    test "plural wording for more than one", %{scope: scope} do
      {:ok, event} = Events.create_event(scope, %{"name" => "Reception"})

      for title <- ["A", "B"] do
        Tasks.create_task(scope, %{"title" => title, "link_event_id" => event.id})
      end

      assert Tasks.event_link_reference(event) == %{
               label: "2 tasks linked to this event (link removed)",
               count: 2
             }
    end
  end

  describe "detach_category/2 (DR-26 Q11/Q18, task 32)" do
    test "a task linked to the category gets its link cleared and logged", %{scope: scope} do
      {:ok, venue} = Categories.create_category(scope, %{"name" => "Venue"})

      {:ok, task} =
        Tasks.create_task(scope, %{"title" => "Book florist", "link_category_id" => venue.id})

      assert [updated] = Tasks.detach_category(scope, venue)
      assert updated.id == task.id
      assert is_nil(updated.link_category_id)

      entry =
        Repo.all(Entry)
        |> Enum.find(&(&1.description =~ "removed the link"))

      assert entry.description ==
               "Wannes removed the link from 'Book florist' to category 'Venue' (category deleted)"
    end

    test "a task unrelated to the category is left untouched", %{scope: scope} do
      {:ok, venue} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, catering} = Categories.create_category(scope, %{"name" => "Catering"})

      {:ok, unrelated} =
        Tasks.create_task(scope, %{"title" => "Unrelated", "link_category_id" => catering.id})

      assert Tasks.detach_category(scope, venue) == []

      reloaded = Tasks.get_task!(unrelated.id)
      assert reloaded.link_category_id == catering.id
    end
  end

  describe "category_link_reference/1 (DR-26 Q11/Q18 provider, task 32)" do
    test "nil when no task links to the category", %{scope: scope} do
      {:ok, venue} = Categories.create_category(scope, %{"name" => "Venue"})
      assert Tasks.category_link_reference(venue) == nil
    end

    test "singular wording for exactly one", %{scope: scope} do
      {:ok, venue} = Categories.create_category(scope, %{"name" => "Venue"})

      {:ok, _task} =
        Tasks.create_task(scope, %{"title" => "Book florist", "link_category_id" => venue.id})

      assert Tasks.category_link_reference(venue) == %{
               label: "1 task linked to this category (link removed)",
               count: 1
             }
    end

    test "plural wording for more than one", %{scope: scope} do
      {:ok, venue} = Categories.create_category(scope, %{"name" => "Venue"})

      for title <- ["A", "B"] do
        Tasks.create_task(scope, %{"title" => title, "link_category_id" => venue.id})
      end

      assert Tasks.category_link_reference(venue) == %{
               label: "2 tasks linked to this category (link removed)",
               count: 2
             }
    end
  end

  describe "on_delete: :restrict (FK enforced)" do
    test "a raw Repo.delete of an event anchoring a task's deadline raises", %{scope: scope} do
      {:ok, event} = Events.create_event(scope, %{"name" => "Reception"})

      {:ok, _task} =
        Tasks.create_task(scope, %{
          "title" => "Send invitations",
          "deadline_kind" => "relative",
          "deadline_amount" => "1",
          "deadline_unit" => "weeks",
          "deadline_direction" => "before",
          "deadline_event_id" => event.id
        })

      assert_raise Ecto.ConstraintError, fn -> Repo.delete(event) end
    end

    test "a raw Repo.delete of an event a task links to raises", %{scope: scope} do
      {:ok, event} = Events.create_event(scope, %{"name" => "Reception"})

      {:ok, _task} =
        Tasks.create_task(scope, %{"title" => "Book florist", "link_event_id" => event.id})

      assert_raise Ecto.ConstraintError, fn -> Repo.delete(event) end
    end

    test "a raw Repo.delete of a user owning a task raises", %{scope: scope, bo: bo} do
      {:ok, _task} = Tasks.create_task(scope, %{"title" => "Book caterer", "owner_id" => bo.id})

      assert_raise Ecto.ConstraintError, fn -> Repo.delete(bo) end
    end

    test "a raw Repo.delete of a category a task links to raises (task 32)", %{scope: scope} do
      {:ok, venue} = Categories.create_category(scope, %{"name" => "Venue"})

      {:ok, _task} =
        Tasks.create_task(scope, %{"title" => "Book florist", "link_category_id" => venue.id})

      assert_raise Ecto.ConstraintError, fn -> Repo.delete(venue) end
    end
  end

  describe "owner_shared implies no owner_id (D-28, DB CHECK)" do
    test "the database rejects the invalid state even bypassing the changeset", %{scope: scope} do
      {:ok, task} = Tasks.create_task(scope, %{"title" => "Book caterer"})

      assert_raise Ecto.ConstraintError, fn ->
        task
        |> Ecto.Changeset.change(owner_id: scope.user.id, owner_shared: true)
        |> Repo.update()
      end
    end
  end

  describe "at most one link set (DR-26 Q17/Q18, task 32 — DB CHECK spanning link_event_id/link_category_id)" do
    test "the changeset rejects both an event and a category link", %{scope: scope} do
      {:ok, reception} = Events.create_event(scope, %{"name" => "Reception"})
      {:ok, venue} = Categories.create_category(scope, %{"name" => "Venue"})

      assert {:error, changeset} =
               Tasks.create_task(scope, %{
                 "title" => "Book florist",
                 "link_event_id" => reception.id,
                 "link_category_id" => venue.id
               })

      assert "at most one link may be set" in errors_on(changeset).link_event_id
      assert "at most one link may be set" in errors_on(changeset).link_category_id
    end

    test "the database CHECK rejects the invalid state even bypassing the changeset", %{
      scope: scope
    } do
      {:ok, reception} = Events.create_event(scope, %{"name" => "Reception"})
      {:ok, venue} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, task} = Tasks.create_task(scope, %{"title" => "Book florist"})

      assert_raise Ecto.ConstraintError, fn ->
        task
        |> Ecto.Changeset.change(link_event_id: reception.id, link_category_id: venue.id)
        |> Repo.update()
      end
    end
  end

  describe "WeddingPlanner.Log.EntityRef 'task' resolver" do
    test "resolves an existing task to its title and /tasks?open=<id>", %{scope: scope} do
      {:ok, task} = Tasks.create_task(scope, %{"title" => "Book caterer"})

      assert {:link, "Book caterer", "/tasks?open=" <> id_str} =
               EntityRef.resolve("task", task.id)

      assert String.to_integer(id_str) == task.id
    end

    test "degrades to text once the task no longer exists", %{scope: scope} do
      {:ok, task} = Tasks.create_task(scope, %{"title" => "Book caterer"})
      {:ok, _} = Tasks.delete_task(scope, task)

      assert {:text, _label} = EntityRef.resolve("task", task.id)
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
