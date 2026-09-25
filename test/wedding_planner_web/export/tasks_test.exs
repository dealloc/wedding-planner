defmodule WeddingPlannerWeb.Export.TasksTest do
  @moduledoc """
  `WeddingPlannerWeb.Export.Tasks` (`TSK-01`…`TSK-03`, `TSK-11`, `TSK-13`, `TSK-23`,
  `DR-88`) — pure, in-memory: `WeddingPlanner.Tasks.Graph.build/3` over hand-built
  `%Task{}` structs, no database.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Tasks.Graph
  alias WeddingPlanner.Tasks.Task
  alias WeddingPlannerWeb.Export.Tasks

  @today ~D[2026-09-25]

  # Row column indices (`Tasks.table/2`'s row shape).
  @status 1
  @owner 2
  @deadline 3
  @deadline_date 4
  @effective_deadline 5
  @blocked 6
  @overdue 7
  @waits_on 8
  @link 9

  # Associations Ecto defaults to `%Ecto.Association.NotLoaded{}` on a bare struct
  # literal — every one this exporter reads must be explicitly `nil` (or set) here,
  # exactly as `WeddingPlanner.Tasks.list_tasks_with_graph/0`'s real preloads guarantee.
  defp task(attrs) do
    struct!(
      %Task{
        status: :to_do,
        deadline_kind: :none,
        owner_id: nil,
        owner_shared: false,
        deadline_event: nil,
        link_event: nil,
        link_category: nil,
        link_offer: nil,
        link_invoice: nil,
        notes: nil
      },
      attrs
    )
  end

  defp table_for(tasks, edges \\ [], events_by_id \\ %{}) do
    graph = Graph.build(tasks, edges, events_by_id)
    Tasks.table({tasks, graph}, @today)
  end

  test "headers" do
    table = table_for([])

    assert table.stem == "tasks"

    assert table.headers == [
             "Title",
             "Status",
             "Owner",
             "Deadline",
             "Deadline date",
             "Effective deadline",
             "Blocked",
             "Overdue",
             "Waits on",
             "Link",
             "Notes"
           ]
  end

  test "status labels" do
    tasks = [
      task(id: 1, title: "A", status: :to_do),
      task(id: 2, title: "B", status: :in_progress),
      task(id: 3, title: "C", status: :done)
    ]

    rows = table_for(tasks).rows
    assert Enum.map(rows, &Enum.at(&1, @status)) == ["to do", "in progress", "done"]
  end

  test "owner: shared and nobody" do
    shared = task(id: 1, title: "A", owner_shared: true)
    nobody = task(id: 2, title: "B")

    [shared_row, nobody_row] = table_for([shared, nobody]).rows

    assert Enum.at(shared_row, @owner) == "Both"
    assert Enum.at(nobody_row, @owner) == "Nobody"
  end

  test "a done blocked-looking task has blank Blocked/Overdue (DR-35)" do
    done_task = task(id: 1, title: "Book flowers", status: :done)
    prereq = task(id: 2, title: "Pick vendor", status: :to_do)
    # `done_task` waits on `prereq`, which is not done — Graph.blocked?/2 itself would
    # say `true`; the export must still leave the Blocked/Overdue cells blank because
    # `done_task` is done (`DR-35`).
    edges = [{1, 2}]

    table = table_for([done_task, prereq], edges)
    [done_row, prereq_row] = table.rows

    assert Enum.at(done_row, @blocked) == nil
    assert Enum.at(done_row, @overdue) == nil
    # a not-done task still shows its (false) Blocked/Overdue
    assert Enum.at(prereq_row, @blocked) == false
    assert Enum.at(prereq_row, @overdue) == false

    graph = Graph.build([done_task, prereq], edges, %{})
    assert Graph.blocked?(graph, 1) == true
  end

  test "an unresolved relative deadline has the '— date not set' text and blank Deadline date / Effective deadline" do
    reception = %Event{id: 100, name: "Reception", date: nil}

    relative =
      task(
        id: 1,
        title: "Send invites",
        deadline_kind: :relative,
        deadline_amount: 12,
        deadline_unit: :weeks,
        deadline_direction: :before,
        deadline_event_id: 100,
        deadline_event: reception
      )

    [row] = table_for([relative], [], %{100 => reception}).rows

    assert Enum.at(row, @deadline) == "12 weeks before Reception — date not set"
    assert Enum.at(row, @deadline_date) == nil
    assert Enum.at(row, @effective_deadline) == nil
  end

  test "a resolved relative deadline renders its date and phrase" do
    reception = %Event{id: 100, name: "Reception", date: ~D[2027-05-13]}

    relative =
      task(
        id: 1,
        title: "Send invites",
        deadline_kind: :relative,
        deadline_amount: 12,
        deadline_unit: :weeks,
        deadline_direction: :before,
        deadline_event_id: 100,
        deadline_event: reception
      )

    [row] = table_for([relative], [], %{100 => reception}).rows

    assert Enum.at(row, @deadline) == "18/02/2027 · 12 weeks before Reception"
    assert Enum.at(row, @deadline_date) == ~D[2027-02-18]
    assert Enum.at(row, @effective_deadline) == ~D[2027-02-18]
  end

  test "a fixed deadline renders as a %Date{} in the Deadline column (so it goes dd/mm/yyyy)" do
    fixed =
      task(id: 1, title: "Pay deposit", deadline_kind: :fixed, deadline_date: ~D[2027-01-01])

    [row] = table_for([fixed]).rows

    assert Enum.at(row, @deadline) == ~D[2027-01-01]
    assert Enum.at(row, @deadline_date) == ~D[2027-01-01]
  end

  test "a prerequisite with a dependent due earlier gets the dependent's date as Effective deadline (TSK-13)" do
    prereq = task(id: 10, title: "Confirm venue", deadline_kind: :none)

    dependent =
      task(id: 11, title: "Book caterer", deadline_kind: :fixed, deadline_date: ~D[2027-01-01])

    # `dependent` (11) waits on `prereq` (10) — the edge convention is {task_id, depends_on_id}.
    edges = [{11, 10}]

    [prereq_row, dependent_row] = table_for([prereq, dependent], edges).rows

    assert Enum.at(prereq_row, @deadline) == "No deadline"
    assert Enum.at(prereq_row, @deadline_date) == nil
    assert Enum.at(prereq_row, @effective_deadline) == ~D[2027-01-01]

    assert Enum.at(dependent_row, @waits_on) == "Confirm venue"
    assert Enum.at(prereq_row, @waits_on) == nil
  end

  test "Waits on joins multiple prerequisite titles with '; '" do
    a = task(id: 1, title: "A")
    b = task(id: 2, title: "B")
    c = task(id: 3, title: "C")
    edges = [{3, 1}, {3, 2}]

    [_a_row, _b_row, c_row] = table_for([a, b, c], edges).rows
    assert Enum.at(c_row, @waits_on) == "A; B"
  end

  test "Link names whichever of the four polymorphic targets is set, or blank" do
    event = %Event{id: 1, name: "Ceremony"}
    category = %Category{id: 1, name: "Venue"}
    offer = %Offer{id: 1, vendor_name: "Kasteel Heers", category: %Category{id: 1, name: "Venue"}}
    invoice = %Invoice{id: 1, label: "Deposit", category: %Category{id: 1, name: "Venue"}}

    tasks = [
      task(id: 1, title: "A", link_event: event),
      task(id: 2, title: "B", link_category: category),
      task(id: 3, title: "C", link_offer: offer),
      task(id: 4, title: "D", link_invoice: invoice),
      task(id: 5, title: "E")
    ]

    rows = table_for(tasks).rows

    assert Enum.map(rows, &Enum.at(&1, @link)) == [
             "Event: Ceremony",
             "Category: Venue",
             "Offer: Venue — Kasteel Heers",
             "Invoice: Venue — Deposit",
             nil
           ]
  end

  test "no money is exported, so there is no Currency column" do
    refute "Currency" in table_for([]).headers
  end
end
