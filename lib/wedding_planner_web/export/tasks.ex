defmodule WeddingPlannerWeb.Export.Tasks do
  @moduledoc """
  The tasks export (`XC-30`, `TSK-01`…`TSK-03`, `TSK-11`, `TSK-13`, `TSK-23`, `DR-88`):
  every task, in `WeddingPlanner.Tasks.list_tasks_with_graph/0`'s order (effective
  deadline ascending, `TSK-13`).

  Columns: `Title, Status, Owner, Deadline, Deadline date, Effective deadline, Blocked,
  Overdue, Waits on, Link, Notes`.

    * `Owner` = `WeddingPlannerWeb.TaskComponents.owner_text/1`.
    * `Deadline` = `WeddingPlannerWeb.TaskComponents.deadline_text/1`'s wording for
      `:none`/`:relative` (resolved or not, `TSK-03`), and the fixed date **as a
      `%Date{}`** for `:fixed` (so the encoder renders it `dd/mm/yyyy`, `NFR-23`, rather
      than duplicating `Format.date/1`'s call here).
    * `Deadline date` = the task's own resolved deadline
      (`WeddingPlanner.Tasks.Graph.own_deadline/2` — exactly
      `WeddingPlanner.Tasks.Deadline.resolve/2`'s `{:fixed, d}`/`{:relative, d}` collapsed
      the same way the graph already does, `:none`/unresolved → blank; reusing the
      engine's own precomputed value instead of re-resolving avoids needing a second,
      export-only `events_by_id` map).
    * `Effective deadline` = `WeddingPlanner.Tasks.Graph.effective_deadline/2`.
    * `Blocked`/`Overdue` are shown only for a **not-done** task (`DR-35`, `TSK-23`) —
      blank on a done one.
    * `Waits on` = direct prerequisites' titles (`WeddingPlanner.Tasks.Graph.waits_on/2`),
      joined `"; "`, blank when none.
    * `Link` names whichever of the task's four polymorphic link targets is set, or
      blank.

  No money is exported here, so there is no `Currency` column.
  """

  @behaviour WeddingPlannerWeb.Export.Exporter

  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Tasks
  alias WeddingPlanner.Tasks.Graph
  alias WeddingPlanner.Tasks.Task
  alias WeddingPlanner.Tasks.TodoList
  alias WeddingPlannerWeb.Export.Table
  alias WeddingPlannerWeb.TaskComponents

  @impl true
  @spec load() :: {[Task.t()], Graph.t()}
  def load, do: Tasks.list_tasks_with_graph()

  @impl true
  @spec table({[Task.t()], Graph.t()}, Date.t()) :: Table.t()
  def table({tasks, graph}, %Date{} = today) do
    tasks_by_id = Map.new(tasks, &{&1.id, &1})
    rows = Enum.map(tasks, &row(&1, graph, tasks_by_id, today))

    %{
      stem: "tasks",
      headers: [
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
      ],
      rows: rows
    }
  end

  defp row(%Task{} = task, graph, tasks_by_id, today) do
    done? = task.status == :done

    [
      task.title,
      status_label(task.status),
      TaskComponents.owner_text(task),
      deadline_cell(task),
      Graph.own_deadline(graph, task.id),
      Graph.effective_deadline(graph, task.id),
      unless(done?, do: Graph.blocked?(graph, task.id)),
      unless(done?, do: TodoList.section_of(graph, task, today) == :overdue),
      waits_on_cell(graph, task.id, tasks_by_id),
      link_cell(task),
      task.notes
    ]
  end

  defp status_label(:to_do), do: "to do"
  defp status_label(:in_progress), do: "in progress"
  defp status_label(:done), do: "done"

  defp deadline_cell(%Task{deadline_kind: :fixed, deadline_date: %Date{} = date}), do: date
  defp deadline_cell(%Task{} = task), do: TaskComponents.deadline_text(task)

  defp waits_on_cell(graph, id, tasks_by_id) do
    case Graph.waits_on(graph, id) do
      [] -> nil
      ids -> ids |> Enum.map(&title_for(tasks_by_id, &1)) |> Enum.join("; ")
    end
  end

  defp title_for(tasks_by_id, id) do
    case Map.get(tasks_by_id, id) do
      %Task{title: title} -> title
      nil -> "a deleted task"
    end
  end

  defp link_cell(%Task{link_event: %Event{name: name}}), do: "Event: #{name}"
  defp link_cell(%Task{link_category: %Category{name: name}}), do: "Category: #{name}"

  defp link_cell(%Task{
         link_offer: %Offer{category: %Category{name: category}, vendor_name: vendor}
       }) do
    "Offer: #{category} — #{vendor}"
  end

  defp link_cell(%Task{link_invoice: %Invoice{category: %Category{name: category}, label: label}}) do
    "Invoice: #{category} — #{label}"
  end

  defp link_cell(%Task{}), do: nil
end
