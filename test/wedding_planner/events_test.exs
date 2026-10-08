defmodule WeddingPlanner.EventsTest do
  @moduledoc """
  `docs/modules/guests-and-events.md` EVT-01 through EVT-05, `NFR-20`, `XC-10`, `XC-01`,
  `XC-02`, `XC-12` — the events context, the exemplar vertical slice's data layer.
  """
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Events
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Log.EntityRef
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Tasks

  setup do
    user = insert_user!("Wannes")
    %{user: user, scope: Scope.for_user(user)}
  end

  describe "create_event/2 (EVT-01, EVT-03)" do
    test "creates an event with no date at all", %{scope: scope} do
      assert {:ok, event} =
               Events.create_event(scope, %{"couple_attends" => false, "name" => "Ceremony"})

      assert event.name == "Ceremony"
      assert is_nil(event.date)
      assert is_nil(event.location)
      assert is_nil(event.notes)
    end

    test "requires a name", %{scope: scope} do
      assert {:error, changeset} =
               Events.create_event(scope, %{"couple_attends" => false, "name" => ""})

      assert "can't be blank" in errors_on(changeset).name
    end

    test "is appended after the current last event (EVT-04)", %{scope: scope} do
      {:ok, first} =
        Events.create_event(scope, %{"couple_attends" => false, "name" => "Ceremony"})

      {:ok, second} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})

      assert second.sort_order > first.sort_order
    end

    test "logs the create (XC-10)", %{scope: scope, user: user} do
      assert {:ok, event} =
               Events.create_event(scope, %{"couple_attends" => false, "name" => "Ceremony"})

      entry = Repo.one!(Entry)
      assert entry.user_id == user.id
      assert entry.entity_type == "event"
      assert entry.entity_id == event.id
      assert entry.description == "Wannes created event 'Ceremony'"
    end

    test "broadcasts {:created, event} (XC-01)", %{scope: scope} do
      Realtime.subscribe(:event)

      assert {:ok, event} =
               Events.create_event(scope, %{"couple_attends" => false, "name" => "Ceremony"})

      assert_received {Realtime, :event, {:created, ^event}}
    end

    test "a date stored as 2028-05-13 reads back as the same calendar date, no shift (NFR-20)",
         %{scope: scope} do
      assert {:ok, event} =
               Events.create_event(scope, %{
                 "couple_attends" => false,
                 "name" => "Reception",
                 "date" => "2028-05-13"
               })

      assert event.date == ~D[2028-05-13]

      reloaded = Events.get_event!(event.id)
      assert reloaded.date == ~D[2028-05-13]
    end
  end

  describe "list_events/0 (EVT-04)" do
    test "renders in manual sort order, not date order", %{scope: scope} do
      # Created (and thus manually ordered) as Reception, then Ceremony — but Ceremony's
      # date is *earlier*. A date-ordered list would put Ceremony first; EVT-04 says the
      # manual order must win regardless.
      {:ok, reception} =
        Events.create_event(scope, %{
          "couple_attends" => false,
          "name" => "Reception",
          "date" => "2028-05-14"
        })

      {:ok, ceremony} =
        Events.create_event(scope, %{
          "couple_attends" => false,
          "name" => "Ceremony",
          "date" => "2028-05-13"
        })

      assert Enum.map(Events.list_events(), & &1.id) == [reception.id, ceremony.id]
    end

    test "an event with no date renders alongside dated ones, order unaffected", %{scope: scope} do
      {:ok, a} = Events.create_event(scope, %{"couple_attends" => false, "name" => "A"})

      {:ok, b} =
        Events.create_event(scope, %{
          "couple_attends" => false,
          "name" => "B",
          "date" => "2028-01-01"
        })

      assert Enum.map(Events.list_events(), & &1.id) == [a.id, b.id]
    end
  end

  describe "update_event/3" do
    setup %{scope: scope} do
      {:ok, event} = Events.create_event(scope, %{"couple_attends" => false, "name" => "Dinner"})
      %{event: event}
    end

    test "updates fields", %{scope: scope, event: event} do
      assert {:ok, updated} =
               Events.update_event(scope, event, %{
                 "location" => "Garden Hall",
                 "date" => "2028-05-13"
               })

      assert updated.location == "Garden Hall"
      assert updated.date == ~D[2028-05-13]
    end

    test "logs one entry per changed field, with 'No date yet' shown explicitly (XC-10, EVT-03)",
         %{scope: scope, event: event} do
      {:ok, _updated} = Events.update_event(scope, event, %{"date" => "2028-05-13"})

      entries = Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created"))
      assert [entry] = entries
      assert entry.entity_id == event.id

      assert entry.description ==
               "Wannes changed the date of 'Dinner': No date yet → 13/05/2028"
    end

    test "logs multiple entries when multiple fields change at once", %{
      scope: scope,
      event: event
    } do
      {:ok, _updated} =
        Events.update_event(scope, event, %{"location" => "Garden Hall", "notes" => "Bring cake"})

      entries =
        Repo.all(Entry)
        |> Enum.reject(&(&1.description =~ "created"))
        |> Enum.map(& &1.description)
        |> Enum.sort()

      assert entries == [
               "Wannes changed the location of 'Dinner': none → Garden Hall",
               "Wannes changed the notes of 'Dinner': none → Bring cake"
             ]
    end

    test "logs nothing extra when nothing user-facing changed", %{scope: scope, event: event} do
      {:ok, _updated} = Events.update_event(scope, event, %{"name" => event.name})

      entries = Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created"))
      assert entries == []
    end

    test "broadcasts {:updated, event} (XC-01)", %{scope: scope, event: event} do
      Realtime.subscribe(:event)
      assert {:ok, updated} = Events.update_event(scope, event, %{"location" => "Garden Hall"})

      assert_received {Realtime, :event, {:updated, ^updated}}
    end
  end

  describe "delete_event/2 (EVT-05)" do
    setup %{scope: scope} do
      {:ok, event} =
        Events.create_event(scope, %{"couple_attends" => false, "name" => "Reception"})

      %{event: event}
    end

    test "deletes the event", %{scope: scope, event: event} do
      assert {:ok, _} = Events.delete_event(scope, event)
      assert_raise Ecto.NoResultsError, fn -> Events.get_event!(event.id) end
    end

    test "logs the delete (XC-10)", %{scope: scope, event: event} do
      {:ok, _} = Events.delete_event(scope, event)

      entry =
        Repo.all(Entry) |> Enum.find(&(&1.description == "Wannes deleted event 'Reception'"))

      assert entry
      assert entry.entity_id == event.id
    end

    test "the entry for a deleted event still resolves, degraded to text (XC-10)", %{
      scope: scope,
      event: event
    } do
      {:ok, _} = Events.delete_event(scope, event)

      entry =
        Repo.all(Entry) |> Enum.find(&(&1.description == "Wannes deleted event 'Reception'"))

      # The event no longer exists, so it degrades to a fallback label (not its old
      # name, which is nowhere left to look up) — same shape as every other resolver's
      # "deleted entity" branch (see WeddingPlanner.Log.EntityRef).
      assert {:text, label} = WeddingPlanner.Log.resolve(entry)
      assert is_binary(label)
    end

    test "broadcasts {:deleted, id} (XC-01)", %{scope: scope, event: event} do
      Realtime.subscribe(:event)
      assert {:ok, _} = Events.delete_event(scope, event)

      id = event.id
      assert_received {Realtime, :event, {:deleted, ^id}}
    end

    test "affected_references/1 is empty when nothing references the event", %{
      event: event
    } do
      assert Events.affected_references(event) == []
    end
  end

  describe "delete_event/2 with tasks referencing it (XC-41, EVT-05, DR-26 Q1)" do
    setup %{scope: scope} do
      {:ok, event} =
        Events.create_event(scope, %{"couple_attends" => false, "name" => "Reception"})

      {:ok, anchored} =
        Tasks.create_task(scope, %{
          "title" => "Send invitations",
          "deadline_kind" => "relative",
          "deadline_amount" => "12",
          "deadline_unit" => "weeks",
          "deadline_direction" => "before",
          "deadline_event_id" => event.id
        })

      {:ok, linked} =
        Tasks.create_task(scope, %{"title" => "Book florist", "link_event_id" => event.id})

      %{event: event, anchored: anchored, linked: linked}
    end

    test "affected_references/1 lists both labels with correct counts beforehand", %{
      event: event
    } do
      assert Events.affected_references(event) ==
               [
                 %{
                   label: "1 task with a deadline relative to this event (deadline becomes none)",
                   count: 1
                 },
                 %{label: "1 task linked to this event (link removed)", count: 1}
               ]
    end

    test "clears the anchored deadline and the link, deletes the event, and keeps returning {:ok, event}",
         %{scope: scope, event: event, anchored: anchored, linked: linked} do
      assert {:ok, deleted} = Events.delete_event(scope, event)
      assert deleted.id == event.id
      assert_raise Ecto.NoResultsError, fn -> Events.get_event!(event.id) end

      reloaded_anchored = Tasks.get_task!(anchored.id)
      assert reloaded_anchored.deadline_kind == :none
      assert is_nil(reloaded_anchored.deadline_event_id)

      reloaded_linked = Tasks.get_task!(linked.id)
      assert is_nil(reloaded_linked.link_event_id)
    end

    test "writes a summary, a child entry per affected task, and the event's own entry, each visible on the task's own history",
         %{scope: scope, event: event, anchored: anchored, linked: linked} do
      {:ok, _} = Events.delete_event(scope, event)

      entries = Repo.all(Entry)
      summary = Enum.find(entries, &(&1.description == "Wannes deleted event 'Reception'"))
      assert summary
      assert is_nil(summary.entity_type)

      deadline_entry =
        Enum.find(
          entries,
          &(&1.description ==
              "Wannes cleared the deadline of 'Send invitations': 12 weeks before Reception → none (event 'Reception' was deleted)")
        )

      assert deadline_entry
      assert deadline_entry.entity_type == "task"
      assert deadline_entry.entity_id == anchored.id
      assert deadline_entry.parent_id == summary.id

      link_entry =
        Enum.find(
          entries,
          &(&1.description ==
              "Wannes cleared the link of 'Book florist': event 'Reception' → none (event 'Reception' was deleted)")
        )

      assert link_entry
      assert link_entry.entity_type == "task"
      assert link_entry.entity_id == linked.id
      assert link_entry.parent_id == summary.id

      event_entry =
        entries
        |> Enum.reverse()
        |> Enum.find(
          &(&1.description == "Wannes deleted event 'Reception'" and &1.entity_type == "event")
        )

      assert event_entry
      assert event_entry.parent_id == summary.id
    end

    test "broadcasts {:updated, task} for each detached task and {:deleted, id} for the event",
         %{scope: scope, event: event, anchored: anchored, linked: linked} do
      Realtime.subscribe(:task)
      Realtime.subscribe(:event)

      {:ok, _} = Events.delete_event(scope, event)

      assert_received {Realtime, :task, {:updated, updated_anchored}}
      assert updated_anchored.id == anchored.id
      assert_received {Realtime, :task, {:updated, updated_linked}}
      assert updated_linked.id == linked.id

      event_id = event.id
      assert_received {Realtime, :event, {:deleted, ^event_id}}
    end
  end

  describe "move_event/3 (EVT-04)" do
    setup %{scope: scope} do
      {:ok, a} = Events.create_event(scope, %{"couple_attends" => false, "name" => "A"})
      {:ok, b} = Events.create_event(scope, %{"couple_attends" => false, "name" => "B"})
      {:ok, c} = Events.create_event(scope, %{"couple_attends" => false, "name" => "C"})
      %{a: a, b: b, c: c}
    end

    test "moving the middle event up swaps it with the first", %{scope: scope, a: a, b: b, c: c} do
      assert :ok = Events.move_event(scope, b, :up)
      assert Enum.map(Events.list_events(), & &1.id) == [b.id, a.id, c.id]
    end

    test "moving the middle event down swaps it with the last", %{
      scope: scope,
      a: a,
      b: b,
      c: c
    } do
      assert :ok = Events.move_event(scope, b, :down)
      assert Enum.map(Events.list_events(), & &1.id) == [a.id, c.id, b.id]
    end

    test "the reordered position persists (a fresh read reflects it)", %{
      scope: scope,
      a: a,
      b: b,
      c: c
    } do
      :ok = Events.move_event(scope, c, :up)

      assert Enum.map(Events.list_events(), & &1.id) == [a.id, c.id, b.id]
    end

    test "moving the first event up is a no-op", %{scope: scope, a: a, b: b, c: c} do
      assert :ok = Events.move_event(scope, a, :up)
      assert Enum.map(Events.list_events(), & &1.id) == [a.id, b.id, c.id]
    end

    test "moving the last event down is a no-op", %{scope: scope, a: a, b: b, c: c} do
      assert :ok = Events.move_event(scope, c, :down)
      assert Enum.map(Events.list_events(), & &1.id) == [a.id, b.id, c.id]
    end

    test "logs one summary plus one child per affected event (XC-12)", %{
      scope: scope,
      a: a,
      b: b
    } do
      :ok = Events.move_event(scope, b, :up)

      entries = Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created"))
      {[summary], children} = Enum.split_with(entries, &is_nil(&1.entity_type))

      assert summary.description == "Wannes moved 'B' up in the event order"
      assert length(children) == 2
      assert Enum.all?(children, &(&1.parent_id == summary.id))
      assert Enum.sort(Enum.map(children, & &1.entity_id)) == Enum.sort([a.id, b.id])
    end

    test "broadcasts {:updated, _} for both affected events", %{scope: scope, a: a, b: b} do
      Realtime.subscribe(:event)
      :ok = Events.move_event(scope, b, :up)

      assert_received {Realtime, :event, {:updated, updated_a}}
      assert_received {Realtime, :event, {:updated, updated_b}}
      assert Enum.sort([updated_a.id, updated_b.id]) == Enum.sort([a.id, b.id])
    end

    test "a boundary move logs and broadcasts nothing", %{scope: scope, a: a} do
      Realtime.subscribe(:event)
      assert :ok = Events.move_event(scope, a, :up)

      assert Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created")) == []
      refute_received {Realtime, :event, {:updated, _}}
    end
  end

  describe "WeddingPlanner.Log.EntityRef 'event' resolver" do
    test "resolves an existing event to a navigable link", %{scope: scope} do
      {:ok, event} =
        Events.create_event(scope, %{"couple_attends" => false, "name" => "Ceremony"})

      assert {:link, "Ceremony", "/events/" <> _} = EntityRef.resolve("event", event.id)
    end

    test "degrades to text once the event no longer exists" do
      assert {:text, _label} = EntityRef.resolve("event", -1)
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
