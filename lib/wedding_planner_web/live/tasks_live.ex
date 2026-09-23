defmodule WeddingPlannerWeb.Live.TasksLive do
  @moduledoc """
  The couple's todo list, first form (task 31; `docs/modules/tasks-and-timeline.md`
  `TSK-01`–`TSK-04`), built toward the locked todo-list design
  (`.claude/design/ui-decisions.md` §5) so slice T3 can extend this screen — sections,
  filters, the desktop master–detail split — around the same
  `WeddingPlannerWeb.TaskComponents.task_editor/1` instead of replacing it.

  `DR-26` Q15: T1's shape is a **single list** of not-done tasks in
  `WeddingPlanner.Tasks.list_tasks/0`'s own order (own resolved deadline ascending, none
  and unresolved last), with done tasks behind a `<details>` disclosure — not the locked
  design's Overdue/This week/Later/No deadline sections, filter chips, owner filter or
  desktop master–detail (all slice T3), and not dependencies/"Waits on"/the
  blocked-completion warning (slice T2 — with no dependencies yet, completing a task
  always just completes it, `TSK-11`/`TSK-12`).

  ## One editor open at a time

  `@open` is `nil`, an existing task's id, or `:new` — never more than one of "the Add
  task editor is showing" and "row N's editor is expanded" at once. Opening one closes
  the other; see `WeddingPlannerWeb.TaskComponents`' moduledoc for why this also lets
  every editor field use one fixed, unparameterised DOM id.

  ## Live updates (`XC-01`, `TSK-03`, `XC-02`/`DR-21`)

  Subscribes to `:task`, `:event` **and** `:category` (not just `:task`): renaming an
  event or giving it a date must re-render every task whose relative deadline anchors on
  it, live, with no reload (`TSK-03`) — this is `docs/07-normative-examples.md`'s T4
  demoed end to end, tagged `@tag example: "T4"` in the test suite. `:category` is the
  same idea for task 32's category link — a renamed category must re-render any task
  linked to it, live. Also subscribes to `:activity_entry` for the open task's history.
  Every handler that changes what should
  render — a status toggle, a save, a delete, `:open` changing, or an incoming broadcast
  — calls `refresh/1`, which refetches `WeddingPlanner.Tasks.list_tasks/0`,
  `WeddingPlanner.Events.list_events/0` and `WeddingPlanner.Categories.list_categories/0`,
  and resets both task streams. Per `DR-21`/`XC-02`
  a live update is silent: no highlight, badge or "someone else changed this" affordance
  of any kind.

  ## Streams

  Not-done tasks live in the `:tasks` stream, done tasks in `:done_tasks` (behind the
  `<details>` disclosure, `@done_count` tracked separately since streams support neither
  counting nor filtering — `AGENTS.md`). Both are fully reset (`reset: true`) on every
  change rather than surgically patched: the expected scale is small (task 30's own
  moduledoc; no `NFR-33` figure is given for tasks specifically, but it is in the same
  small-dataset family as events/persons/offers) and a reset is what keeps `@open`
  driving each row's expanded/collapsed content correctly, since a stream item's
  rendered HTML only updates when that item is re-inserted, not merely because another
  assign it reads (`@open`, `@confirming_delete_id`) changed (`AGENTS.md` streams note).

  ## Dependencies (task 43, `TSK-10`-`TSK-15`, `DR-35`, `DR-36`)

  Same discipline, extended: `refresh/1` also rebuilds `WeddingPlanner.Tasks.Graph` (via
  `Tasks.list_tasks_with_graph/0`) into `@graph`/`@tasks_by_id`, which every row reads
  for its blocked pill, conflict lines, effective deadline and "Waits on"/"Waiting on
  this" trees, always fresh because they ride the same stream reset.
  `@confirming_done_id` (the `TSK-12` one-tap-complete warning) is a third per-row
  toggle alongside `@open`/`@confirming_delete_id`, flowing through `refresh/1` the
  same way.

  ## `?open=<id>` (task 30's `resolve_log_entity/1`)

  The activity log links to a task as `/tasks?open=<id>` (`WeddingPlanner.Tasks.resolve_log_entity/1`).
  `mount/3` opens that task's row expanded, exactly as if the user had tapped it.
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.TaskComponents

  alias WeddingPlanner.Accounts.Users
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Events
  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Tasks
  alias WeddingPlanner.Tasks.Graph
  alias WeddingPlanner.Tasks.Task

  on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Realtime.subscribe(:task)
      Realtime.subscribe(:event)
      Realtime.subscribe(:category)
      Realtime.subscribe(:activity_entry)
    end

    socket =
      socket
      |> assign(:page_title, "Tasks")
      |> assign(:adding, false)
      |> assign(:new_form, nil)
      |> assign(:open, nil)
      |> assign(:form, nil)
      |> assign(:activity_entries, [])
      |> assign(:confirming_delete_id, nil)
      |> assign(:confirming_done_id, nil)
      |> assign(:assignable_users, Users.list_assignable())
      |> refresh()

    socket =
      case parse_open_param(params["open"]) do
        nil -> socket
        id -> open_task(socket, id)
      end

    {:ok, socket}
  end

  defp parse_open_param(nil), do: nil

  defp parse_open_param(id_str) do
    case Integer.parse(id_str) do
      {id, ""} -> id
      _ -> nil
    end
  end

  @impl true
  def handle_event("add_new", _params, socket) do
    socket =
      socket
      |> close_open()
      |> assign(:adding, true)
      |> assign(:new_form, to_form(Tasks.change_task(%Task{}, %{})))

    {:noreply, refresh(socket)}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, socket |> assign(adding: false, new_form: nil) |> refresh()}
  end

  def handle_event("validate_new", %{"task" => params}, socket) do
    form =
      %Task{}
      |> Tasks.change_task(normalize_params(params))
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :new_form, form)}
  end

  def handle_event("save_new", %{"task" => params}, socket) do
    case Tasks.create_task(socket.assigns.current_scope, normalize_params(params)) do
      {:ok, _task} ->
        {:noreply,
         socket
         |> assign(adding: false, new_form: nil)
         |> put_flash(:info, "Task created.")
         |> refresh()}

      {:error, changeset} ->
        {:noreply, assign(socket, :new_form, to_form(changeset))}
    end
  end

  def handle_event("clear_deadline_new", _params, socket) do
    params = Map.put(socket.assigns.new_form.params, "deadline_kind", "none")
    handle_event("validate_new", %{"task" => params}, socket)
  end

  def handle_event("toggle_open", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)

    socket =
      if socket.assigns.open == id do
        close_open(socket)
      else
        socket |> close_open() |> open_task(id)
      end

    {:noreply, socket |> assign(:adding, false) |> refresh()}
  end

  # `@form` is rendered *inside* the `:tasks`/`:done_tasks` stream item for the open
  # row (`task_row/1`'s expanded content), so an ordinary `assign(socket, :form, ...)`
  # alone never reaches the already-rendered DOM — `phx-update="stream"` only ships a
  # patch for an item that is re-inserted (or the whole stream reset), never merely
  # because another assign it reads changed (`AGENTS.md` streams note). `refresh/1`
  # resets both streams, which is what makes every keystroke while editing (kind
  # switch, Clear, inline validation errors) actually show up live.
  def handle_event("validate_edit", %{"task" => params}, socket) do
    task = Tasks.get_task!(socket.assigns.open)

    form =
      task
      |> Tasks.change_task(normalize_params(params))
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, socket |> assign(:form, form) |> refresh()}
  end

  def handle_event("save_edit", %{"task" => params}, socket) do
    task = Tasks.get_task!(socket.assigns.open)

    case Tasks.update_task(socket.assigns.current_scope, task, normalize_params(params)) do
      {:ok, _task} ->
        {:noreply,
         socket
         |> close_open()
         |> put_flash(:info, "Task updated.")
         |> refresh()}

      {:error, changeset} ->
        {:noreply, socket |> assign(:form, to_form(changeset)) |> refresh()}
    end
  end

  def handle_event("clear_deadline_edit", _params, socket) do
    params = Map.put(socket.assigns.form.params, "deadline_kind", "none")
    handle_event("validate_edit", %{"task" => params}, socket)
  end

  # `TSK-12`, `DR-36`: completing a blocked task doesn't silently succeed — the circle
  # tap sets `@confirming_done_id` instead of updating the task, and the row shows an
  # inline warning with an explicit "Mark done anyway"/"Cancel" choice
  # (`done_anyway`/`cancel_done` below). Un-completing a done task, and completing a
  # non-blocked task, stay one tap.
  def handle_event("toggle_status", %{"id" => id}, socket) do
    task = Tasks.get_task!(id)

    if task.status != :done and Graph.blocked?(socket.assigns.graph, task.id) do
      {:noreply, socket |> assign(:confirming_done_id, task.id) |> refresh()}
    else
      new_status = if task.status == :done, do: "to_do", else: "done"

      {:ok, _task} =
        Tasks.update_task(socket.assigns.current_scope, task, %{"status" => new_status})

      {:noreply, socket |> assign(:confirming_done_id, nil) |> refresh()}
    end
  end

  def handle_event("done_anyway", %{"id" => id}, socket) do
    task = Tasks.get_task!(id)
    {:ok, _task} = Tasks.update_task(socket.assigns.current_scope, task, %{"status" => "done"})

    {:noreply, socket |> assign(:confirming_done_id, nil) |> refresh()}
  end

  def handle_event("cancel_done", _params, socket) do
    {:noreply, socket |> assign(:confirming_done_id, nil) |> refresh()}
  end

  # `DR-36`: each add/remove is its own immediate, logged write — not part of the
  # editor's Save. The select commits on change; a cycle rejection flashes
  # `Tasks.cycle_message/1`'s chain and leaves the graph untouched (nothing to
  # `refresh/1` for). Candidates that would close a cycle stay selectable (see
  # `TaskComponents.task_row/1`) so the rejection is reachable at all.
  def handle_event("add_dependency", %{"task_id" => _task_id, "dep_id" => ""}, socket) do
    {:noreply, socket}
  end

  def handle_event("add_dependency", %{"task_id" => task_id, "dep_id" => dep_id}, socket) do
    task = Tasks.get_task!(task_id)
    prerequisite = Tasks.get_task!(dep_id)

    case Tasks.add_dependency(socket.assigns.current_scope, task, prerequisite) do
      {:ok, _dependency} ->
        {:noreply, refresh(socket)}

      {:error, {:cycle, tasks}} ->
        message = Tasks.cycle_message(tasks) <> " Rejected — pick something else."
        {:noreply, put_flash(socket, :error, message)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_dependency", %{"id" => task_id, "dep_id" => dep_id}, socket) do
    task = Tasks.get_task!(task_id)
    prerequisite = Tasks.get_task!(dep_id)

    case Tasks.remove_dependency(socket.assigns.current_scope, task, prerequisite) do
      {:ok, _dependency} -> {:noreply, refresh(socket)}
      {:error, :not_found} -> {:noreply, socket}
    end
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    {:noreply, refresh(assign(socket, :confirming_delete_id, String.to_integer(id)))}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, refresh(assign(socket, :confirming_delete_id, nil))}
  end

  def handle_event("delete_confirmed", %{"id" => id}, socket) do
    id = String.to_integer(id)
    task = Tasks.get_task!(id)
    {:ok, _task} = Tasks.delete_task(socket.assigns.current_scope, task)

    socket =
      if socket.assigns.open == id, do: close_open(socket), else: socket

    {:noreply, socket |> assign(:confirming_delete_id, nil) |> refresh()}
  end

  @impl true
  def handle_info({Realtime, :task, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :event, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :category, _event}, socket), do: {:noreply, refresh(socket)}

  def handle_info({Realtime, :activity_entry, {:created, entry}}, socket) do
    %{open: open} = socket.assigns

    if open && entry.entity_type == "task" && entry.entity_id == open do
      entry = Query.preload_user(entry)
      {:noreply, update(socket, :activity_entries, &[entry | &1])}
    else
      {:noreply, socket}
    end
  end

  # -- helpers -------------------------------------------------------------------------

  defp refresh(socket) do
    {tasks, graph} = Tasks.list_tasks_with_graph()
    {done, open_tasks} = Enum.split_with(tasks, &(&1.status == :done))
    tasks_by_id = Map.new(tasks, &{&1.id, &1})

    socket
    |> assign(:done_count, length(done))
    |> assign(:events, Events.list_events())
    |> assign(:categories, Categories.list_categories())
    |> assign(:graph, graph)
    |> assign(:tasks_by_id, tasks_by_id)
    |> stream(:tasks, open_tasks, reset: true)
    |> stream(:done_tasks, done, reset: true)
  end

  defp close_open(socket) do
    assign(socket, open: nil, form: nil, activity_entries: [])
  end

  defp open_task(socket, id) do
    case Enum.find(Tasks.list_tasks(), &(&1.id == id)) do
      nil ->
        socket

      task ->
        socket
        |> assign(:open, task.id)
        |> assign(:form, to_form(Tasks.change_task(task, %{})))
        |> assign(:activity_entries, Query.for_entity(:task, task.id))
    end
  end

  # Translates both of the editor's combined selects — `task[owner]` and `task[link]`
  # (see `WeddingPlannerWeb.TaskComponents`' moduledoc) — back into the plain schema
  # fields `WeddingPlanner.Tasks.change_task/2` et al. expect, before params reach it.
  defp normalize_params(params), do: params |> normalize_owner() |> normalize_link()

  # `owner_id`/`owner_shared` pair (`D-28`).
  defp normalize_owner(%{"owner" => "shared"} = params) do
    params |> Map.delete("owner") |> Map.merge(%{"owner_id" => "", "owner_shared" => "true"})
  end

  defp normalize_owner(%{"owner" => ""} = params) do
    params |> Map.delete("owner") |> Map.merge(%{"owner_id" => "", "owner_shared" => "false"})
  end

  defp normalize_owner(%{"owner" => id} = params) do
    params |> Map.delete("owner") |> Map.merge(%{"owner_id" => id, "owner_shared" => "false"})
  end

  defp normalize_owner(params), do: params

  # `link_event_id`/`link_category_id` pair (`DR-26` Q17/Q18).
  defp normalize_link(%{"link" => "event:" <> id} = params) do
    params |> Map.delete("link") |> Map.merge(%{"link_event_id" => id, "link_category_id" => ""})
  end

  defp normalize_link(%{"link" => "category:" <> id} = params) do
    params |> Map.delete("link") |> Map.merge(%{"link_event_id" => "", "link_category_id" => id})
  end

  defp normalize_link(%{"link" => ""} = params) do
    params
    |> Map.delete("link")
    |> Map.merge(%{"link_event_id" => "", "link_category_id" => ""})
  end

  defp normalize_link(params), do: params

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Tasks
        <:actions>
          <.button variant="primary" id="new-task" phx-click="add_new">Add task</.button>
        </:actions>
      </.header>

      <div :if={@adding} class="mb-4 rounded-field border border-line bg-surface-raised p-4">
        <.task_editor
          id="task-editor-new"
          form={@new_form}
          assignable_users={@assignable_users}
          events={@events}
          categories={@categories}
          change_event="validate_new"
          submit_event="save_new"
          cancel_event="cancel_new"
          clear_event="clear_deadline_new"
        />
      </div>

      <ul id="tasks" phx-update="stream" class="space-y-3">
        <li
          id="tasks-empty"
          class="hidden rounded-field border border-dashed border-line-strong p-6 text-center text-sm text-ink-faint only:block"
        >
          No open tasks.
        </li>
        <li :for={{dom_id, task} <- @streams.tasks} id={dom_id}>
          <.task_row
            task={task}
            graph={@graph}
            tasks_by_id={@tasks_by_id}
            open?={@open == task.id}
            confirming?={@confirming_delete_id == task.id}
            confirming_done?={@confirming_done_id == task.id}
            form={@form}
            assignable_users={@assignable_users}
            events={@events}
            categories={@categories}
            activity_entries={@activity_entries}
            time_zone={@time_zone}
          />
        </li>
      </ul>

      <details id="tasks-done" class="mt-6 rounded-field border border-line">
        <summary
          id="tasks-done-summary"
          class="cursor-pointer select-none px-4 py-3 text-sm font-semibold text-ink-soft"
        >
          Done ({@done_count})
        </summary>
        <ul id="tasks-done-list" phx-update="stream" class="space-y-3 border-t border-line p-4">
          <li :for={{dom_id, task} <- @streams.done_tasks} id={dom_id}>
            <.task_row
              task={task}
              graph={@graph}
              tasks_by_id={@tasks_by_id}
              done?={true}
              open?={@open == task.id}
              confirming?={@confirming_delete_id == task.id}
              confirming_done?={@confirming_done_id == task.id}
              form={@form}
              assignable_users={@assignable_users}
              events={@events}
              categories={@categories}
              activity_entries={@activity_entries}
              time_zone={@time_zone}
            />
          </li>
        </ul>
      </details>
    </Layouts.app>
    """
  end
end
