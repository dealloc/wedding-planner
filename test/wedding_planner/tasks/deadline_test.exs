defmodule WeddingPlanner.Tasks.DeadlineTest do
  @moduledoc """
  `docs/modules/tasks-and-timeline.md` TSK-02, TSK-03 — pure deadline resolution.
  Normative example T4 (`docs/07-normative-examples.md`, resolution half — the timeline
  half is slice T4) is covered by the `@tag example: "T4"` test below.
  """
  use ExUnit.Case, async: true

  doctest WeddingPlanner.Tasks.Deadline

  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Tasks.Deadline
  alias WeddingPlanner.Tasks.Task

  describe "T4 — Send invitations, 12 weeks before Reception" do
    @describetag example: "T4"

    test "unresolved while Reception has no date" do
      reception = %Event{id: 1, name: "Reception", date: nil}

      task = %Task{
        title: "Send invitations",
        deadline_kind: :relative,
        deadline_amount: 12,
        deadline_unit: :weeks,
        deadline_direction: :before,
        deadline_event_id: 1
      }

      assert Deadline.resolve(task, %{1 => reception}) == {:unresolved, reception}
    end

    test "resolves to 2028-02-19 once Reception is set to 2028-05-13, with no write to the task" do
      reception = %Event{id: 1, name: "Reception", date: ~D[2028-05-13]}

      task = %Task{
        title: "Send invitations",
        deadline_kind: :relative,
        deadline_amount: 12,
        deadline_unit: :weeks,
        deadline_direction: :before,
        deadline_event_id: 1
      }

      assert Deadline.resolve(task, %{1 => reception}) == {:relative, ~D[2028-02-19]}
      # `resolve/2` is a pure function — the same `task` value, unmodified, still
      # resolves against the old (dateless) reception exactly as before. Nothing about
      # calling `resolve/2` ever writes a date back onto the task.
      assert Deadline.resolve(task, %{1 => %Event{id: 1, name: "Reception", date: nil}}) ==
               {:unresolved, %Event{id: 1, name: "Reception", date: nil}}
    end
  end

  describe "resolve/2 — none and fixed" do
    test "none is always :none, regardless of events_by_id" do
      task = %Task{deadline_kind: :none}
      assert Deadline.resolve(task, %{}) == :none
    end

    test "fixed returns the stored date verbatim" do
      task = %Task{deadline_kind: :fixed, deadline_date: ~D[2028-05-13]}
      assert Deadline.resolve(task, %{}) == {:fixed, ~D[2028-05-13]}
    end
  end

  describe "resolve/2 — relative, days vs. weeks, before vs. after" do
    setup do
      %{event: %Event{id: 7, name: "Ceremony", date: ~D[2028-06-10]}}
    end

    test "days before", %{event: event} do
      task = relative_task(5, :days, :before, event.id)
      assert Deadline.resolve(task, %{7 => event}) == {:relative, ~D[2028-06-05]}
    end

    test "days after", %{event: event} do
      task = relative_task(5, :days, :after, event.id)
      assert Deadline.resolve(task, %{7 => event}) == {:relative, ~D[2028-06-15]}
    end

    test "weeks before", %{event: event} do
      task = relative_task(2, :weeks, :before, event.id)
      assert Deadline.resolve(task, %{7 => event}) == {:relative, ~D[2028-05-27]}
    end

    test "weeks after", %{event: event} do
      task = relative_task(2, :weeks, :after, event.id)
      assert Deadline.resolve(task, %{7 => event}) == {:relative, ~D[2028-06-24]}
    end

    test "amount 0 resolves to the event's own date, before", %{event: event} do
      task = relative_task(0, :days, :before, event.id)
      assert Deadline.resolve(task, %{7 => event}) == {:relative, event.date}
    end

    test "amount 0 resolves to the event's own date, after", %{event: event} do
      task = relative_task(0, :weeks, :after, event.id)
      assert Deadline.resolve(task, %{7 => event}) == {:relative, event.date}
    end

    test "unresolved when the anchor event has no date" do
      event = %Event{id: 9, name: "Dinner", date: nil}
      task = relative_task(3, :weeks, :before, 9)

      assert Deadline.resolve(task, %{9 => event}) == {:unresolved, event}
    end
  end

  defp relative_task(amount, unit, direction, event_id) do
    %Task{
      deadline_kind: :relative,
      deadline_amount: amount,
      deadline_unit: unit,
      deadline_direction: direction,
      deadline_event_id: event_id
    }
  end
end
