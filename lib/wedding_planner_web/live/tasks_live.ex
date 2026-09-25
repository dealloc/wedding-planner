defmodule WeddingPlannerWeb.Live.TasksLive do
  @moduledoc """
  The couple's todo list (task 31; dependencies task 43; slice T3 sections/filters/
  master-detail), built to the locked design (`.claude/design/ui-decisions.md` §5 "Todo
  list" and "Todo list v2") around `WeddingPlannerWeb.TaskComponents.task_editor/1` and
  `task_detail/1` — one shared editor and one shared detail component for both layouts,
  so mobile/desktop editing can't drift.

  ## Filter and `open` state live in the URL (`DR-44`)

  `?filter=blocked&owner=12&open=5` is the single source of truth for the active chip
  filters, owner filter and which task is selected — never held only in an assign — so a
  reload keeps them and a `push_patch` is how every one of those three things changes.
  `handle_params/3` (not `mount/3`) is where all three are parsed and applied, on every
  navigation including the very first one:

    * `WeddingPlanner.Tasks.TodoList.from_params/1` / `to_params/1` own the filter
      round-trip entirely (chip semantics, exclusive pairs, owner semantics) — this
      module never re-implements any of that, only builds/reads the query string
      (`todo_path/2`, `open_param/1`, `filter_form/1`).
    * `@open` is `nil` or an existing task's id — **never** `:new` anymore now that it is
      URL-driven; the separate "Add task" editor is `@adding`/`@new_form`, local assigns
      not tracked in the URL (nothing in the locked design asks for that to survive a
      reload).
    * `open_task/2`/`close_open/1` (unchanged from task 31) still own `@form`/
      `@activity_entries`; `handle_params/3` is now the only caller.

  ## Sections (`DR-44`) and the four fixed streams

  `WeddingPlanner.Tasks.TodoList.build/4` sections not-done tasks into Overdue/This
  week/Later/No deadline (an empty section is omitted). Streams cannot be filtered or
  counted (`AGENTS.md`), so each section is its own stream —
  `:tasks_overdue`/`:tasks_this_week`/`:tasks_later`/`:tasks_no_deadline` — plus the
  existing `:done_tasks`, all five reset (`reset: true`) on every `refresh/1`, same
  discipline as before, now per section. The atom names are fixed in code (`refresh/1`),
  never built from a section id string. `@sections` (the plain list `TodoList.build/4`
  returns) drives the section headers' labels/counts/visibility; `@shown`/
  `@total_not_done` drive the "N of M shown" line.

  ## Desktop master–detail via a viewport hook (`DR-44`)

  `@view_mode` is `:stacked` (the default, and what every test sees — the hook never fires
  without a real browser) or `:split`, set by the `.TodoLayout` colocated hook on
  `#todo-layout` (`window.matchMedia("(min-width: 1024px)")`, `pushEvent("layout",
  %{"split" => bool})` on mount and every media-query change — see `handle_event/3`'s
  `"layout"` clause). `task_row/1` never renders `TaskComponents.task_detail/1` both
  inline *and* in `#todo-detail-panel` for the same task — see that module's moduledoc —
  `:show_detail?`/`:confirming_done?` are computed here as `@view_mode == :stacked and ...`
  so the stacked layout keeps today's inline behaviour untouched and the split layout's
  panel (rendered once, in `render/1`, picking whichever task is open or has
  `@confirming_done_id` set) is the only other place either ever renders.

  ## Live updates (`XC-01`, `TSK-03`, `XC-02`/`DR-21`)

  Subscribes to `:task`, `:event`, `:category`, `:offer`, `:invoice` and
  `:activity_entry` — renaming or deleting an event, category, offer or invoice must
  re-render every task that reads it, live, no reload (`TSK-03`, task 32's category
  link, task 78's offer/invoice links, `DR-8`/`DR-69`). Every handler that changes what
  should render calls `refresh/1` (directly, or indirectly via `push_patch` →
  `handle_params/3` → `refresh/1` for the three URL-driven changes above), which
  refetches `WeddingPlanner.Tasks.list_tasks_with_graph/0`,
  `WeddingPlanner.Events.list_events/0`, `WeddingPlanner.Categories.list_categories/0`,
  every offer/invoice (category preloaded, for the link picker's Offers/Invoices
  optgroups, `DR-69`) and `WeddingPlanner.Tasks.TodoList.build/4`'s sectioning, then
  resets every stream. Per `DR-21`/`XC-02` a live update is silent: no highlight, badge
  or "someone else changed this" affordance of any kind.

  ## `TSK-12` in two places

  Completing a blocked task shows "Still waiting on: …" with "Mark done anyway"/"Cancel"
  (`TaskComponents.done_warning/1`) — inline under the row in the stacked layout
  (`confirming_done?` passed straight through), or in `#todo-detail-panel` in the split
  layout (rendered directly in `render/1`, ahead of the normal open-task detail, for
  whichever task has `@confirming_done_id` set — reachable even if that task isn't the
  currently "open"/selected one). The editor's own inline warning
  (`task-editor-blocked-warning`, shown when picking "Done" from the Status select) is a
  second, independent `TSK-12` surface inside `task_editor/1` itself, unaffected by any
  of this.

  ## `today` (`NFR-22`)

  `WeddingPlannerWeb.Live.TimeZoneHook.probe/1` reports the browser's IANA zone once
  connected; `refresh/1` calls `TodoList.today(@time_zone)` fresh every time so sections
  always reflect the viewer's "today", not the server's.
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.TaskComponents
  import WeddingPlannerWeb.Components.ExportComponents, only: [export_link: 1]

  alias WeddingPlanner.Accounts.Users
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Events
  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks
  alias WeddingPlanner.Tasks.Graph
  alias WeddingPlanner.Tasks.Task
  alias WeddingPlanner.Tasks.TodoList

  on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Realtime.subscribe(:task)
      Realtime.subscribe(:event)
      Realtime.subscribe(:category)
      Realtime.subscribe(:offer)
      Realtime.subscribe(:invoice)
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
      |> assign(:view_mode, :stacked)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = TodoList.from_params(params)

    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:filter_form, filter_form(filters))
      |> refresh()

    socket =
      case parse_open_param(params["open"]) do
        nil ->
          close_open(socket)

        id ->
          socket
          |> close_open()
          |> open_task(id)
          |> assign(:adding, false)
          |> assign(:new_form, nil)
      end

    {:noreply, socket}
  end

  defp parse_open_param(nil), do: nil

  defp parse_open_param(id_str) do
    case Integer.parse(id_str) do
      {id, ""} -> id
      _ -> nil
    end
  end

  # `AGENTS.md`'s streams note: a stream item only re-renders when re-inserted, never
  # merely because another assign it reads (here, `:show_detail?`/`:dense?`/
  # `:confirming_done?`, all derived from `@view_mode`) changed — so switching layout
  # must `refresh/1` (a full stream reset) or the previous layout's inline
  # `task_detail/1` would keep rendering stale, alongside the new layout's panel one,
  # which is exactly the "never both at once" invariant this module's moduledoc and
  # `TaskComponents`' moduledoc both call out.
  @impl true
  def handle_event("layout", %{"split" => split?}, socket) do
    socket = assign(socket, :view_mode, if(split?, do: :split, else: :stacked))
    {:noreply, refresh(socket)}
  end

  def handle_event("add_new", _params, socket) do
    socket =
      socket
      |> assign(:adding, true)
      |> assign(:new_form, to_form(Tasks.change_task(%Task{}, %{})))

    socket =
      if socket.assigns.open do
        push_patch(socket, to: todo_path(socket.assigns.filters, open_param(nil)))
      else
        socket
      end

    {:noreply, socket}
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
    new_open = if socket.assigns.open == id, do: nil, else: id

    {:noreply, push_patch(socket, to: todo_path(socket.assigns.filters, open_param(new_open)))}
  end

  def handle_event("owner_change", %{"filter" => %{"owner" => owner_str}}, socket) do
    params = socket.assigns.filters |> TodoList.to_params() |> Map.put("owner", owner_str)
    new_filters = TodoList.from_params(params)

    socket =
      push_patch(socket, to: todo_path(new_filters, open_param(socket.assigns.open)))

    {:noreply, socket}
  end

  # `@form` is rendered *inside* the `:tasks_*`/`:done_tasks` stream item for the open
  # row (`task_row/1`'s `task_detail/1`), or in `#todo-detail-panel` in the split
  # layout — either way an ordinary `assign(socket, :form, ...)` alone never reaches
  # already-rendered stream DOM — `phx-update="stream"` only ships a patch for an item
  # that is re-inserted (or the whole stream reset), never merely because another assign
  # it reads changed (`AGENTS.md` streams note). `refresh/1` resets every stream, which
  # is what makes every keystroke while editing (kind switch, Clear, inline validation
  # errors) actually show up live — the panel isn't inside a stream, so it always sees
  # the fresh `@form` regardless, but resetting stays correct for the stacked layout.
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
         |> put_flash(:info, "Task updated.")
         |> push_patch(to: todo_path(socket.assigns.filters, open_param(nil)))}

      {:error, changeset} ->
        {:noreply, socket |> assign(:form, to_form(changeset)) |> refresh()}
    end
  end

  def handle_event("clear_deadline_edit", _params, socket) do
    params = Map.put(socket.assigns.form.params, "deadline_kind", "none")
    handle_event("validate_edit", %{"task" => params}, socket)
  end

  # `TSK-12`, `DR-36`: completing a blocked task doesn't silently succeed — the circle
  # tap sets `@confirming_done_id` instead of updating the task, and
  # `TaskComponents.done_warning/1` shows with an explicit "Mark done
  # anyway"/"Cancel" choice (`done_anyway`/`cancel_done` below). Un-completing a done
  # task, and completing a non-blocked task, stay one tap.
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
  # `TaskComponents.task_detail/1`) so the rejection is reachable at all.
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

    socket = assign(socket, :confirming_delete_id, nil)

    if socket.assigns.open == id do
      {:noreply, push_patch(socket, to: todo_path(socket.assigns.filters, open_param(nil)))}
    else
      {:noreply, refresh(socket)}
    end
  end

  @impl true
  def handle_info({Realtime, :task, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :event, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :category, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :offer, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :invoice, _event}, socket), do: {:noreply, refresh(socket)}

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
    tasks_by_id = Map.new(tasks, &{&1.id, &1})
    today = TodoList.today(socket.assigns.time_zone)
    todo = TodoList.build(tasks, graph, socket.assigns.filters, today)
    sections_by_id = Map.new(todo.sections, &{&1.id, &1})

    categories = Categories.list_categories()

    offers =
      categories
      |> Enum.flat_map(&Offers.list_offers/1)
      |> Repo.preload(:category)

    invoices = Invoices.list_invoices() |> Repo.preload(:category)

    socket
    |> assign(:events, Events.list_events())
    |> assign(:categories, categories)
    |> assign(:offers, offers)
    |> assign(:invoices, invoices)
    |> assign(:graph, graph)
    |> assign(:tasks_by_id, tasks_by_id)
    |> assign(:sections, todo.sections)
    |> assign(:shown, todo.shown)
    |> assign(:total_not_done, todo.total_not_done)
    |> assign(:done_count, length(todo.done))
    |> stream(:tasks_overdue, section_tasks(sections_by_id, :overdue), reset: true)
    |> stream(:tasks_this_week, section_tasks(sections_by_id, :this_week), reset: true)
    |> stream(:tasks_later, section_tasks(sections_by_id, :later), reset: true)
    |> stream(:tasks_no_deadline, section_tasks(sections_by_id, :no_deadline), reset: true)
    |> stream(:done_tasks, todo.done, reset: true)
  end

  defp section_tasks(sections_by_id, id) do
    case Map.get(sections_by_id, id) do
      %{tasks: tasks} -> tasks
      nil -> []
    end
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

  # `link_event_id`/`link_category_id`/`link_offer_id`/`link_invoice_id` (`DR-26`
  # Q17/Q18, `DR-8`/`DR-69`) — exactly one gets the chosen id, the other three are
  # explicitly cleared so switching the link's target never leaves a stale FK behind.
  @cleared_link_ids %{
    "link_event_id" => "",
    "link_category_id" => "",
    "link_offer_id" => "",
    "link_invoice_id" => ""
  }

  defp normalize_link(%{"link" => "event:" <> id} = params) do
    set_link(params, "link_event_id", id)
  end

  defp normalize_link(%{"link" => "category:" <> id} = params) do
    set_link(params, "link_category_id", id)
  end

  defp normalize_link(%{"link" => "offer:" <> id} = params) do
    set_link(params, "link_offer_id", id)
  end

  defp normalize_link(%{"link" => "invoice:" <> id} = params) do
    set_link(params, "link_invoice_id", id)
  end

  defp normalize_link(%{"link" => ""} = params) do
    params |> Map.delete("link") |> Map.merge(@cleared_link_ids)
  end

  defp normalize_link(params), do: params

  defp set_link(params, field, id) do
    params
    |> Map.delete("link")
    |> Map.merge(@cleared_link_ids)
    |> Map.put(field, id)
  end

  # -- URL round-trip (`DR-44`) --------------------------------------------------------
  #
  # `TodoList.to_params/1`/`from_params/1` own every filter semantic; the helpers below
  # only ever build/read the `open` query key and merge the two together — no chip/owner
  # rule is re-implemented here.

  defp todo_path(filters, extra) do
    params =
      filters
      |> TodoList.to_params()
      |> Map.merge(extra)
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    ~p"/tasks?#{params}"
  end

  defp open_param(nil), do: %{}
  defp open_param(id) when is_integer(id), do: %{"open" => to_string(id)}

  defp filter_form(filters) do
    to_form(%{"owner" => Map.get(TodoList.to_params(filters), "owner", "")}, as: "filter")
  end

  defp filters_active?(%{chips: chips, owner: owner}) do
    MapSet.size(chips) > 0 or owner != :everyone
  end

  defp owner_filter_options(users) do
    [{"Everyone", ""}] ++
      Enum.map(users, &{&1.display_name, to_string(&1.id)}) ++ [{"Unassigned", "unassigned"}]
  end

  defp section(sections, id), do: Enum.find(sections, &(&1.id == id))

  # -- local components ------------------------------------------------------------------

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :chip, :atom, required: true
  attr :filters, :map, required: true
  attr :open, :any, required: true

  defp todo_chip(assigns) do
    assigns = assign(assigns, :active?, MapSet.member?(assigns.filters.chips, assigns.chip))

    ~H"""
    <.link
      patch={todo_path(TodoList.toggle_chip(@filters, @chip), open_param(@open))}
      id={@id}
      aria-pressed={to_string(@active?)}
      class={[
        "rounded-chip px-3 py-1.5 text-sm font-medium transition",
        @active? && "bg-accent text-white",
        not @active? && "border border-line-strong text-ink-soft hover:bg-surface hover:text-ink"
      ]}
    >
      {@label}
    </.link>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      width={if @view_mode == :split, do: "wide", else: "default"}
    >
      <WeddingPlannerWeb.Live.TimeZoneHook.probe id="tasks-time-zone-probe" />

      <.header>
        Tasks
        <:actions>
          <.button variant="primary" id="new-task" phx-click="add_new">Add task</.button>
          <.export_link kind="tasks" time_zone={@time_zone} />
        </:actions>
      </.header>

      <div
        id="todo-layout"
        phx-hook=".TodoLayout"
        class={[
          @view_mode == :split && "lg:grid lg:grid-cols-[minmax(0,1fr)_22rem] lg:items-start lg:gap-6"
        ]}
      >
        <div class="space-y-4">
          <div class="flex flex-wrap items-center gap-2">
            <.todo_chip
              id="todo-chip-actionable"
              label="Actionable"
              chip={:actionable}
              filters={@filters}
              open={@open}
            />
            <.todo_chip
              id="todo-chip-blocked"
              label="Blocked"
              chip={:blocked}
              filters={@filters}
              open={@open}
            />
            <.todo_chip
              id="todo-chip-overdue"
              label="Overdue"
              chip={:overdue}
              filters={@filters}
              open={@open}
            />
            <.todo_chip
              id="todo-chip-this-week"
              label="This week"
              chip={:this_week}
              filters={@filters}
              open={@open}
            />

            <.form for={@filter_form} id="todo-owner-form" phx-change="owner_change" class="contents">
              <.input
                type="select"
                id="todo-owner-filter"
                field={@filter_form[:owner]}
                options={owner_filter_options(@assignable_users)}
              />
            </.form>
          </div>

          <div :if={filters_active?(@filters)} class="flex flex-wrap items-center gap-3 text-sm">
            <p id="todo-shown-count" class="text-ink-soft">{@shown} of {@total_not_done} shown</p>
            <.link
              patch={todo_path(TodoList.default_filters(), open_param(@open))}
              id="todo-clear-filters"
              class="font-medium text-accent hover:underline"
            >
              Clear filters
            </.link>
          </div>

          <div
            :if={@adding and @view_mode == :stacked}
            class="rounded-field border border-line bg-surface-raised p-4"
          >
            <.task_editor
              id="task-editor-new"
              form={@new_form}
              assignable_users={@assignable_users}
              events={@events}
              categories={@categories}
              offers={@offers}
              invoices={@invoices}
              change_event="validate_new"
              submit_event="save_new"
              cancel_event="cancel_new"
              clear_event="clear_deadline_new"
            />
          </div>

          <div id="tasks" class="space-y-6">
            <p
              :if={@sections == [] and @total_not_done == 0}
              id="tasks-empty"
              class="rounded-field border border-dashed border-line-strong p-6 text-center text-sm text-ink-faint"
            >
              No open tasks.
            </p>
            <p
              :if={@sections == [] and @total_not_done > 0}
              id="todo-filtered-empty"
              class="rounded-field border border-dashed border-line-strong p-6 text-center text-sm text-ink-faint"
            >
              No tasks match the current filters.
            </p>

            <div :if={section(@sections, :overdue)} id="todo-section-overdue">
              <h2 class="mb-2 text-sm font-semibold text-bad">
                Overdue ({length(section(@sections, :overdue).tasks)})
              </h2>
              <ul id="todo-section-overdue-list" phx-update="stream" class="space-y-3">
                <li :for={{dom_id, task} <- @streams.tasks_overdue} id={dom_id}>
                  <.task_row
                    task={task}
                    graph={@graph}
                    tasks_by_id={@tasks_by_id}
                    open?={@open == task.id}
                    show_detail?={@view_mode == :stacked and @open == task.id}
                    dense?={@view_mode == :split}
                    confirming?={@confirming_delete_id == task.id}
                    confirming_done?={@view_mode == :stacked and @confirming_done_id == task.id}
                    form={@form}
                    assignable_users={@assignable_users}
                    events={@events}
                    categories={@categories}
                    offers={@offers}
                    invoices={@invoices}
                    activity_entries={@activity_entries}
                    time_zone={@time_zone}
                  />
                </li>
              </ul>
            </div>

            <div :if={section(@sections, :this_week)} id="todo-section-this-week">
              <h2 class="mb-2 text-sm font-semibold text-ink-soft">
                This week ({length(section(@sections, :this_week).tasks)})
              </h2>
              <ul id="todo-section-this-week-list" phx-update="stream" class="space-y-3">
                <li :for={{dom_id, task} <- @streams.tasks_this_week} id={dom_id}>
                  <.task_row
                    task={task}
                    graph={@graph}
                    tasks_by_id={@tasks_by_id}
                    open?={@open == task.id}
                    show_detail?={@view_mode == :stacked and @open == task.id}
                    dense?={@view_mode == :split}
                    confirming?={@confirming_delete_id == task.id}
                    confirming_done?={@view_mode == :stacked and @confirming_done_id == task.id}
                    form={@form}
                    assignable_users={@assignable_users}
                    events={@events}
                    categories={@categories}
                    offers={@offers}
                    invoices={@invoices}
                    activity_entries={@activity_entries}
                    time_zone={@time_zone}
                  />
                </li>
              </ul>
            </div>

            <div :if={section(@sections, :later)} id="todo-section-later">
              <h2 class="mb-2 text-sm font-semibold text-ink-soft">
                Later ({length(section(@sections, :later).tasks)})
              </h2>
              <ul id="todo-section-later-list" phx-update="stream" class="space-y-3">
                <li :for={{dom_id, task} <- @streams.tasks_later} id={dom_id}>
                  <.task_row
                    task={task}
                    graph={@graph}
                    tasks_by_id={@tasks_by_id}
                    open?={@open == task.id}
                    show_detail?={@view_mode == :stacked and @open == task.id}
                    dense?={@view_mode == :split}
                    confirming?={@confirming_delete_id == task.id}
                    confirming_done?={@view_mode == :stacked and @confirming_done_id == task.id}
                    form={@form}
                    assignable_users={@assignable_users}
                    events={@events}
                    categories={@categories}
                    offers={@offers}
                    invoices={@invoices}
                    activity_entries={@activity_entries}
                    time_zone={@time_zone}
                  />
                </li>
              </ul>
            </div>

            <div :if={section(@sections, :no_deadline)} id="todo-section-no-deadline">
              <h2 class="mb-2 text-sm font-semibold text-ink-soft">
                No deadline ({length(section(@sections, :no_deadline).tasks)})
              </h2>
              <ul id="todo-section-no-deadline-list" phx-update="stream" class="space-y-3">
                <li :for={{dom_id, task} <- @streams.tasks_no_deadline} id={dom_id}>
                  <.task_row
                    task={task}
                    graph={@graph}
                    tasks_by_id={@tasks_by_id}
                    open?={@open == task.id}
                    show_detail?={@view_mode == :stacked and @open == task.id}
                    dense?={@view_mode == :split}
                    confirming?={@confirming_delete_id == task.id}
                    confirming_done?={@view_mode == :stacked and @confirming_done_id == task.id}
                    form={@form}
                    assignable_users={@assignable_users}
                    events={@events}
                    categories={@categories}
                    offers={@offers}
                    invoices={@invoices}
                    activity_entries={@activity_entries}
                    time_zone={@time_zone}
                  />
                </li>
              </ul>
            </div>
          </div>

          <details id="tasks-done" class="rounded-field border border-line">
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
                  show_detail?={@view_mode == :stacked and @open == task.id}
                  dense?={@view_mode == :split}
                  confirming?={@confirming_delete_id == task.id}
                  confirming_done?={@view_mode == :stacked and @confirming_done_id == task.id}
                  form={@form}
                  assignable_users={@assignable_users}
                  events={@events}
                  categories={@categories}
                  offers={@offers}
                  invoices={@invoices}
                  activity_entries={@activity_entries}
                  time_zone={@time_zone}
                />
              </li>
            </ul>
          </details>
        </div>

        <div
          :if={@view_mode == :split}
          id="todo-detail-panel"
          class="mt-6 rounded-field border border-line bg-surface-raised p-4 lg:sticky lg:top-4 lg:mt-0 lg:self-start"
        >
          <%= cond do %>
            <% @adding -> %>
              <.task_editor
                id="task-editor-new"
                form={@new_form}
                assignable_users={@assignable_users}
                events={@events}
                categories={@categories}
                offers={@offers}
                invoices={@invoices}
                change_event="validate_new"
                submit_event="save_new"
                cancel_event="cancel_new"
                clear_event="clear_deadline_new"
              />
            <% @confirming_done_id && Map.has_key?(@tasks_by_id, @confirming_done_id) -> %>
              <.done_warning
                task={Map.fetch!(@tasks_by_id, @confirming_done_id)}
                unfinished_dependency_titles={
                  unfinished_titles(
                    @graph,
                    @tasks_by_id,
                    Map.fetch!(@tasks_by_id, @confirming_done_id)
                  )
                }
              />
            <% is_integer(@open) && Map.has_key?(@tasks_by_id, @open) -> %>
              <.task_detail
                id={"task-detail-panel-#{@open}"}
                task={Map.fetch!(@tasks_by_id, @open)}
                graph={@graph}
                tasks_by_id={@tasks_by_id}
                confirming?={@confirming_delete_id == @open}
                form={@form}
                assignable_users={@assignable_users}
                events={@events}
                categories={@categories}
                offers={@offers}
                invoices={@invoices}
                activity_entries={@activity_entries}
                time_zone={@time_zone}
              />
            <% true -> %>
              <p id="todo-detail-empty" class="text-sm text-ink-faint">
                Select a task to see its details.
              </p>
          <% end %>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".TodoLayout">
          export default {
            mounted() {
              this.mq = window.matchMedia("(min-width: 1024px)")
              this.report = () => this.pushEvent("layout", {split: this.mq.matches})
              this.report()
              this.mq.addEventListener("change", this.report)
            },
            destroyed() {
              if (this.mq && this.report) {
                this.mq.removeEventListener("change", this.report)
              }
            }
          }
        </script>
      </div>
    </Layouts.app>
    """
  end
end
