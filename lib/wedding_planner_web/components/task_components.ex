defmodule WeddingPlannerWeb.TaskComponents do
  @moduledoc """
  The shared task editor (`task_editor/1`) and the todo-list row (`task_row/1`) — task
  31's building blocks for `WeddingPlannerWeb.Live.TasksLive` (`/tasks`), built toward the
  locked todo-list design (`.claude/design/ui-decisions.md` §5) so slice T3 can extend
  this screen instead of replacing it.

  ## `task_editor/1` is shared, on purpose

  The locked design uses **one** editor for both the phone inline-expand and the future
  desktop master-detail panel, "so mobile/desktop editing can't drift apart". This module
  is where that lives: `task_editor/1` takes only a form and the two lookup lists it
  needs (assignable owners, events) plus the event names its host wants pushed on
  change/submit/cancel/clear/delete — it does not know or care whether it is rendered
  inline under a row (task 31, today) or in a sticky side panel (slice T3, later). A
  future desktop detail panel is expected to call this same function unchanged.

  ## No nested `<form>` (a real bug from the design prototype)

  `task_editor/1` renders exactly one `<.form>`. Cancel, Clear and Delete are plain
  `<button type="button">` elements (not `<.button>` — see the note on that function
  below) inside that same form, not separate forms and not raw `<button>`s that default
  to `type="submit"`, which would otherwise silently trigger a save.

  ### Why not `<.button>` for Cancel/Clear/Delete

  `WeddingPlannerWeb.CoreComponents.button/1`'s `:rest` global attribute does not include
  `type` (Phoenix's default global attribute set does not, and the component's own
  `:include` list does not add it), so `<.button type="button">` silently drops the
  `type` attribute. Used inside a `<form>`, the resulting `<button>` has no `type`
  attribute and a browser defaults that to `type="submit"` — exactly the nested-form-class
  of bug this module's moduledoc warns readers about. `task_editor/1` therefore renders
  its own non-submitting buttons directly, styled to match `CoreComponents.button/1`'s
  `secondary`/`destructive` variants without going through it.

  ## Link is not a form field either (`TSK-01`, `DR-26` Q17/Q18)

  Same shape as owner, one level down: `link_event_id` and `link_category_id` (task 32)
  are two schema fields for one user-facing choice, so the editor exposes a single
  `task[link]` select — `""` for none, `"event:<id>"`, or `"category:<id>"` — grouped
  into `<optgroup>`s "Events" and "Categories", built and read outside `@form`'s own
  fields exactly like `task[owner]`; the host LiveView translates it back to
  `link_event_id`/`link_category_id` before handing params to
  `WeddingPlanner.Tasks.change_task/2` et al. — see `link_value/1`/`link_options/2`.
  Offer and invoice groups join later (slice T4).

  ## Owner is not a form field (`TSK-01`, `D-28`)

  `owner_id` + `owner_shared` together encode four choices (nobody / shared / one of N
  users) that must not become a hard-coded four-value enum (`D-28`). The editor exposes
  this as a single `task[owner]` select (`""` nobody, `"shared"` both, or a user id) built
  and read outside `@form`'s own fields; the host LiveView is expected to translate that
  key back to `owner_id`/`owner_shared` before handing params to
  `WeddingPlanner.Tasks.change_task/2` et al. — see `owner_value/1`/`owner_options/1`.

  ## Stable ids

  Because only one `task_editor/1` is ever mounted at a time (`TasksLive` closes any
  other open editor before opening a new one, and the "Add task" editor and a row's
  editor are mutually exclusive), every *internal* field keeps a fixed, unparameterised
  id (`task-editor-title`, `task-editor-deadline-kind`, ...) rather than one built from
  the task's id — only the outer container's id (the `:id` attr) varies
  (`task-editor-<id>` / `task-editor-new`), so tests can always find "the" editor's
  fields by the same selector regardless of which task is open.
  """
  use WeddingPlannerWeb, :html

  import WeddingPlannerWeb.ActivityComponents, only: [entity_history: 1]

  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Tasks
  alias WeddingPlanner.Tasks.Deadline
  alias WeddingPlanner.Tasks.Graph
  alias WeddingPlanner.Tasks.Task
  alias WeddingPlannerWeb.Format

  @deadline_kind_options [
    {"No deadline", "none"},
    {"Fixed date", "fixed"},
    {"Relative to an event", "relative"}
  ]

  @doc """
  The shared task form (`TSK-01`–`TSK-03`): title, notes, status, owner, deadline (kind
  plus the fields for that kind, and Clear), link, Save/Cancel, and — when `:delete_event`
  is set — Delete. See the moduledoc for why this is the one editor for both today's
  inline row and slice T3's future desktop detail panel.

  ## Attrs

    * `:id` — the outer `<.form>`'s DOM id (`task-editor-<id>` / `task-editor-new`); its
      *fields* keep fixed ids (see moduledoc).
    * `:form` — a `to_form/2` of a `WeddingPlanner.Tasks.change_task/2` changeset.
    * `:assignable_users` — `WeddingPlanner.Accounts.Users.list_assignable/0`'s result,
      for the owner picker (`DR-22`).
    * `:events` — `WeddingPlanner.Events.list_events/0`'s result, for the relative-deadline
      event picker and the link picker.
    * `:categories` — `WeddingPlanner.Categories.list_categories/0`'s result, for the
      link picker's Categories group.
    * `:change_event` / `:submit_event` — the `phx-change`/`phx-submit` event names.
    * `:cancel_event` (+ optional `:cancel_value`) — the Cancel button's `phx-click`
      (and `phx-value-id`, forwarded only when given).
    * `:clear_event` — the Clear button's `phx-click` (only rendered while a deadline
      kind other than "none" is selected).
    * `:delete_event` (+ optional `:delete_value`) — when set, renders a Delete button;
      `nil` (the default, for the "new task" editor) renders none.
    * `:blocked_dependency_titles` — `TSK-12`: the unfinished direct-dependency titles
      (`WeddingPlanner.Tasks.Graph.unfinished_dependencies/2`, titled), or `nil`. While
      the selected status is Done and this is non-empty, an inline warning
      (`task-editor-blocked-warning`) renders under the Status select — the same
      wording as the one-tap-complete warning on the row. `nil` (the default, for the
      "new task" editor — it has no dependencies yet) renders nothing.
  """
  attr :id, :string, required: true
  attr :form, :any, required: true
  attr :assignable_users, :list, required: true
  attr :events, :list, required: true
  attr :categories, :list, required: true
  attr :change_event, :string, required: true
  attr :submit_event, :string, required: true
  attr :cancel_event, :string, required: true
  attr :cancel_value, :any, default: nil
  attr :clear_event, :string, required: true
  attr :delete_event, :string, default: nil
  attr :delete_value, :any, default: nil
  attr :blocked_dependency_titles, :list, default: nil

  def task_editor(assigns) do
    ~H"""
    <.form
      for={@form}
      id={@id}
      phx-change={@change_event}
      phx-submit={@submit_event}
      class="space-y-4"
    >
      <.input field={@form[:title]} type="text" label="Title" id="task-editor-title" />
      <.input field={@form[:notes]} type="textarea" label="Notes" id="task-editor-notes" />

      <.input
        field={@form[:status]}
        type="select"
        label="Status"
        id="task-editor-status"
        options={[{"To do", "to_do"}, {"In progress", "in_progress"}, {"Done", "done"}]}
      />

      <p
        :if={status_value(@form) == "done" and @blocked_dependency_titles not in [nil, []]}
        id="task-editor-blocked-warning"
        class="-mt-2 text-sm text-warn"
      >
        {still_waiting_text(@blocked_dependency_titles)}
      </p>

      <.input
        type="select"
        id="task-editor-owner"
        name="task[owner]"
        label="Owner"
        value={owner_value(@form)}
        options={owner_options(@assignable_users)}
      />

      <div>
        <div class="mb-1 flex items-center justify-between">
          <span class="block text-sm font-medium text-ink-soft">Deadline</span>
          <button
            :if={deadline_kind(@form) != "none"}
            type="button"
            id="task-editor-clear-deadline"
            phx-click={@clear_event}
            class="text-sm font-medium text-accent hover:underline"
          >
            Clear
          </button>
        </div>

        <.input
          field={@form[:deadline_kind]}
          type="select"
          id="task-editor-deadline-kind"
          options={deadline_kind_options()}
        />

        <div :if={deadline_kind(@form) == "fixed"} class="mt-3">
          <.input
            field={@form[:deadline_date]}
            type="date"
            label="Due date"
            id="task-editor-deadline-date"
          />
        </div>

        <div
          :if={deadline_kind(@form) == "relative"}
          class="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-4"
        >
          <.input
            field={@form[:deadline_amount]}
            type="number"
            label="Amount"
            id="task-editor-deadline-amount"
            min="0"
          />
          <.input
            field={@form[:deadline_unit]}
            type="select"
            label="Unit"
            id="task-editor-deadline-unit"
            options={[{"Days", "days"}, {"Weeks", "weeks"}]}
          />
          <.input
            field={@form[:deadline_direction]}
            type="select"
            label="Before/after"
            id="task-editor-deadline-direction"
            options={[{"Before", "before"}, {"After", "after"}]}
          />
          <.input
            field={@form[:deadline_event_id]}
            type="select"
            label="Event"
            id="task-editor-deadline-event"
            prompt="Choose an event"
            options={Enum.map(@events, &{&1.name, &1.id})}
          />
        </div>
      </div>

      <.input
        type="select"
        id="task-editor-link"
        name="task[link]"
        label="Link"
        value={link_value(@form)}
        prompt="No link"
        options={link_options(@events, @categories)}
      />

      <div class="flex flex-wrap items-center gap-2 pt-2">
        <.button variant="primary" id="task-editor-save">Save</.button>
        <button
          type="button"
          id="task-editor-cancel"
          phx-click={@cancel_event}
          phx-value-id={@cancel_value}
          class={secondary_button_class()}
        >
          Cancel
        </button>
        <button
          :if={@delete_event}
          type="button"
          id="task-editor-delete"
          phx-click={@delete_event}
          phx-value-id={@delete_value}
          class={"ml-auto " <> destructive_button_class()}
        >
          Delete
        </button>
      </div>
    </.form>
    """
  end

  # `@name` inside a `~H` template always means `assigns.name`, never a module
  # attribute — this wraps `@deadline_kind_options` in an ordinary function so the
  # template can reach it via a plain call (`{deadline_kind_options()}`) instead.
  defp deadline_kind_options, do: @deadline_kind_options

  @doc """
  The todo-list row (task 31; dependencies added task 43): a leading one-tap complete
  circle, the row body (title, effective deadline text, owner, link — tapping it expands
  `task_editor/1` inline), a `TSK-11` **Blocked** badge and `TSK-14` conflict line on
  not-done tasks only (`DR-35`), and, while expanded, the editor itself, the `TSK-15`
  dependencies section, this task's own delete confirmation and activity history.

  ## Attrs

    * `:task` — a `WeddingPlanner.Tasks.Task.t()`,
      `:owner`/`:deadline_event`/`:link_event`/`:link_category` preloaded
      (`WeddingPlanner.Tasks.list_tasks_with_graph/0` always does this).
    * `:graph` — the `WeddingPlanner.Tasks.Graph.t()` built from every task
      (`WeddingPlanner.Tasks.list_tasks_with_graph/0`).
    * `:tasks_by_id` — every task, by id (`%{id => Task.t()}`) — titles for the
      dependency chips, add-select, trees and conflict wording all come from here since
      `Graph.t()` itself is opaque and only ever hands back ids.
    * `:done?` — struck-through title styling for a row inside the Done disclosure.
    * `:open?` — whether this row's editor is expanded.
    * `:confirming?` — whether this row's delete confirmation is showing.
    * `:confirming_done?` — `TSK-12`: whether this row's one-tap-complete warning is
      showing (set by tapping `task-<id>-complete` on a blocked, not-done task).
    * `:form` / `:assignable_users` / `:events` / `:categories` — forwarded to
      `task_editor/1` while open.
    * `:activity_entries` / `:time_zone` — forwarded to `entity_history/1` while open.
  """
  attr :task, Task, required: true
  attr :graph, Graph, required: true
  attr :tasks_by_id, :map, required: true
  attr :done?, :boolean, default: false
  attr :open?, :boolean, required: true
  attr :confirming?, :boolean, required: true
  attr :confirming_done?, :boolean, required: true
  attr :form, :any, default: nil
  attr :assignable_users, :list, required: true
  attr :events, :list, required: true
  attr :categories, :list, required: true
  attr :activity_entries, :list, default: []
  attr :time_zone, :string, default: nil

  def task_row(assigns) do
    %{graph: graph, tasks_by_id: tasks_by_id, task: task} = assigns
    direct_dependency_ids = Graph.waits_on(graph, task.id)

    assigns =
      assigns
      |> assign(:blocked?, Graph.blocked?(graph, task.id))
      |> assign(:unfinished_dependency_titles, unfinished_titles(graph, tasks_by_id, task))
      |> assign(:conflict_lines, conflict_lines(graph, tasks_by_id, task))
      |> assign(:effective_deadline_text, effective_deadline_text(graph, tasks_by_id, task))
      |> assign(
        :direct_dependencies,
        Enum.map(direct_dependency_ids, &Map.fetch!(tasks_by_id, &1))
      )
      |> assign(
        :dependency_candidates,
        tasks_by_id
        |> Map.values()
        |> Enum.reject(&(&1.id == task.id or &1.id in direct_dependency_ids))
        |> Enum.sort_by(&String.downcase(&1.title))
      )
      |> assign(:waits_on_tree, Graph.waits_on_tree(graph, task.id))
      |> assign(:waited_on_by_tree, Graph.waited_on_by_tree(graph, task.id))

    ~H"""
    <div class="rounded-field border border-line bg-surface-raised p-4">
      <div class="flex items-start gap-3">
        <button
          type="button"
          id={"task-#{@task.id}-complete"}
          phx-click="toggle_status"
          phx-value-id={@task.id}
          aria-label={complete_label(@task)}
          class={[
            "mt-0.5 flex size-6 shrink-0 items-center justify-center rounded-full border-2 transition",
            if(@task.status == :done,
              do: "border-accent bg-accent text-white",
              else: "border-line-strong text-transparent hover:border-accent"
            )
          ]}
        >
          <.icon name="hero-check" class="size-4" />
        </button>

        <div
          id={"task-#{@task.id}-row"}
          phx-click="toggle_open"
          phx-value-id={@task.id}
          class="min-w-0 flex-1 cursor-pointer"
        >
          <p class={["font-medium text-ink", @done? && "line-through decoration-ink-faint"]}>
            {@task.title}
          </p>
          <p class="text-sm text-ink-soft">
            <span id={"task-#{@task.id}-deadline"}>{@effective_deadline_text}</span>
            <span aria-hidden="true">&middot;</span>
            <span id={"task-#{@task.id}-owner"}>{owner_text(@task)}</span>
          </p>

          <div :if={@task.status != :done and @blocked?} class="mt-1">
            <.status_pill id={"task-#{@task.id}-blocked"} label="Blocked" tone={:warn} />
          </div>

          <div
            :if={@task.status != :done and @conflict_lines != []}
            id={"task-#{@task.id}-conflict"}
            class="mt-1 space-y-0.5 text-sm text-warn"
          >
            <p :for={line <- @conflict_lines}>{line}</p>
          </div>

          <p :if={@task.link_event} class="mt-0.5 text-sm">
            <.link
              navigate={~p"/events/#{@task.link_event.id}/edit"}
              id={"task-#{@task.id}-link"}
              class="text-accent hover:underline"
            >
              {@task.link_event.name}
            </.link>
          </p>
          <p :if={@task.link_category} class="mt-0.5 text-sm">
            <.link
              navigate={~p"/categories/#{@task.link_category.id}"}
              id={"task-#{@task.id}-link"}
              class="text-accent hover:underline"
            >
              {@task.link_category.name}
            </.link>
          </p>
        </div>
      </div>

      <div
        :if={@confirming_done?}
        id={"task-#{@task.id}-done-warning"}
        class="mt-3 ml-9 rounded-field border border-warn/30 bg-warn-soft p-3 text-sm text-ink"
      >
        <p>{still_waiting_text(@unfinished_dependency_titles)}</p>
        <div class="mt-2 flex flex-wrap gap-2">
          <.button
            variant="primary"
            id={"task-#{@task.id}-done-anyway"}
            phx-click="done_anyway"
            phx-value-id={@task.id}
          >
            Mark done anyway
          </.button>
          <.button variant="secondary" id={"task-#{@task.id}-done-cancel"} phx-click="cancel_done">
            Cancel
          </.button>
        </div>
      </div>

      <div :if={@open?} class="mt-4 border-t border-line pt-4">
        <.task_editor
          id={"task-editor-#{@task.id}"}
          form={@form}
          assignable_users={@assignable_users}
          events={@events}
          categories={@categories}
          change_event="validate_edit"
          submit_event="save_edit"
          cancel_event="toggle_open"
          cancel_value={@task.id}
          clear_event="clear_deadline_edit"
          delete_event="confirm_delete"
          delete_value={@task.id}
          blocked_dependency_titles={@unfinished_dependency_titles}
        />

        <div class="mt-6 space-y-4">
          <div>
            <.header>Waits on</.header>

            <div id={"task-#{@task.id}-deps"} class="mt-2 flex flex-wrap gap-2">
              <span
                :for={dep <- @direct_dependencies}
                id={"task-#{@task.id}-dep-#{dep.id}"}
                class={chip_class()}
              >
                <span>{dep.title} &middot; {dependency_status_label(dep.status)}</span>
                <button
                  type="button"
                  id={"task-#{@task.id}-dep-#{dep.id}-remove"}
                  phx-click="remove_dependency"
                  phx-value-id={@task.id}
                  phx-value-dep_id={dep.id}
                  aria-label={"Remove '#{dep.title}' from what '#{@task.title}' waits on"}
                  class="text-ink-faint hover:text-bad"
                >
                  <.icon name="hero-x-mark" class="size-3.5" />
                </button>
              </span>
            </div>

            <form id={"task-#{@task.id}-dep-add-form"} phx-change="add_dependency" class="mt-2">
              <input type="hidden" name="task_id" value={@task.id} />
              <select
                id={"task-#{@task.id}-dep-add"}
                name="dep_id"
                class="block w-full rounded-field border border-line-strong bg-surface-raised px-3 py-2 text-sm text-ink focus:border-accent focus:outline-none focus:ring-1 focus:ring-accent"
              >
                <option value="">Add a task this waits on…</option>
                <option :for={c <- @dependency_candidates} value={c.id}>{c.title}</option>
              </select>
            </form>

            <div
              :if={@waits_on_tree != []}
              id={"task-#{@task.id}-waits-on-tree"}
              class="mt-3 text-sm"
            >
              <.dependency_tree nodes={@waits_on_tree} tasks_by_id={@tasks_by_id} />
            </div>
          </div>

          <div>
            <.header>Waiting on this</.header>

            <div id={"task-#{@task.id}-waited-on-by"} class="mt-2 text-sm">
              <p :if={@waited_on_by_tree == []} class="text-ink-faint">Nothing waits on this.</p>
              <.dependency_tree
                :if={@waited_on_by_tree != []}
                nodes={@waited_on_by_tree}
                tasks_by_id={@tasks_by_id}
              />
            </div>
          </div>
        </div>

        <.destructive_confirm
          :if={@confirming?}
          id={"task-#{@task.id}-delete-confirm"}
          title={"Delete '#{@task.title}'?"}
          body="This cannot be undone."
          affected={Tasks.task_deletion_effects(@task)}
          confirm="delete_confirmed"
          confirm_value={@task.id}
          cancel="cancel_delete"
        />

        <div class="mt-6">
          <.header>History</.header>
          <.entity_history
            id={"task-editor-#{@task.id}-history"}
            entity={{:task, @task.id}}
            entries={@activity_entries}
            time_zone={@time_zone}
          />
        </div>
      </div>
    </div>
    """
  end

  defp complete_label(%Task{status: :done} = task), do: "Mark '#{task.title}' as to do"
  defp complete_label(%Task{} = task), do: "Mark '#{task.title}' as done"

  # -- deadline display (TSK-02/03, DR-26 Q16) ----------------------------------------

  @doc """
  The row/editor-summary deadline text (`TSK-02`/`TSK-03`, `DR-26` Q16):

    * `:none` — "No deadline"
    * `:fixed` — the date via `WeddingPlannerWeb.Format.date/1` (`dd/mm/yyyy`, `NFR-23`)
    * `:relative`, resolved — `"19/02/2028 · 12 weeks before Reception"`; amount `0` is
      `"On the day of Reception"`
    * `:relative`, unresolved — `"12 weeks before Reception — date not set"`, `TSK-03`'s
      own wording verbatim — **never** `Format.date(nil)`'s "No date yet", which is
      `EVT-03`'s wording for a different situation (see `Format.date/1`'s moduledoc)
  """
  @spec deadline_text(Task.t()) :: String.t()
  def deadline_text(%Task{deadline_kind: :none}), do: "No deadline"
  def deadline_text(%Task{deadline_kind: :fixed, deadline_date: date}), do: Format.date(date)

  def deadline_text(%Task{deadline_kind: :relative} = task) do
    events_by_id =
      case task.deadline_event do
        %Event{} = event -> %{event.id => event}
        nil -> %{}
      end

    case Deadline.resolve(task, events_by_id) do
      {:relative, date} -> "#{Format.date(date)} · #{relative_phrase(task)}"
      {:unresolved, _event} -> "#{relative_phrase(task)} — date not set"
    end
  end

  defp relative_phrase(%Task{deadline_amount: 0} = task), do: "On the day of #{event_name(task)}"

  defp relative_phrase(%Task{} = task) do
    "#{task.deadline_amount} #{unit_word(task.deadline_unit, task.deadline_amount)} " <>
      "#{direction_word(task.deadline_direction)} #{event_name(task)}"
  end

  defp event_name(%Task{deadline_event: %Event{name: name}}), do: name
  defp event_name(%Task{}), do: "a deleted event"

  defp unit_word(:days, 1), do: "day"
  defp unit_word(:days, _amount), do: "days"
  defp unit_word(:weeks, 1), do: "week"
  defp unit_word(:weeks, _amount), do: "weeks"

  defp direction_word(:before), do: "before"
  defp direction_word(:after), do: "after"

  # -- effective deadline / blocked / conflicts (TSK-11/13/14, DR-35/36) --------------

  @doc """
  The row's deadline text once dependencies are in play (`TSK-13`, `DR-36`): when
  `task`'s effective deadline is its own (`Graph.effective_source/2` is `nil`), this is
  exactly `deadline_text/1` — none/fixed/relative wording unchanged, resolved or not.
  Otherwise (some dependent's deadline pulls this task's effective deadline earlier, or
  gives a no-deadline task one at all — example T2) it is the effective date
  (`WeddingPlannerWeb.Format.date/1`) plus "· needed by '<source task's title>'".
  """
  @spec effective_deadline_text(Graph.t(), %{optional(term()) => Task.t()}, Task.t()) ::
          String.t()
  def effective_deadline_text(graph, tasks_by_id, %Task{} = task) do
    case Graph.effective_source(graph, task.id) do
      nil ->
        deadline_text(task)

      source_id ->
        date = Graph.effective_deadline(graph, task.id)
        "#{Format.date(date)} · needed by '#{title_for(tasks_by_id, source_id)}'"
    end
  end

  @doc """
  `task`'s direct unfinished dependencies, titled (`TSK-12`'s warning, ascending by id —
  `Graph.unfinished_dependencies/2`'s own order).
  """
  @spec unfinished_titles(Graph.t(), %{optional(term()) => Task.t()}, Task.t()) :: [String.t()]
  def unfinished_titles(graph, tasks_by_id, %Task{} = task) do
    graph
    |> Graph.unfinished_dependencies(task.id)
    |> Enum.map(&title_for(tasks_by_id, &1))
  end

  @doc """
  `task`'s deadline conflicts, worded (`TSK-14`): "Due 15/03/2027, but 'Book caterer'
  waits on it and is due 01/03/2027." — with "(through 'Y')" right after the naming
  dependent's title when the binding deadline is further up the chain
  (`Graph.conflicts/2`'s `via != source`).
  """
  @spec conflict_lines(Graph.t(), %{optional(term()) => Task.t()}, Task.t()) :: [String.t()]
  def conflict_lines(graph, tasks_by_id, %Task{} = task) do
    graph
    |> Graph.conflicts(task.id)
    |> Enum.map(&conflict_line(graph, tasks_by_id, task, &1))
  end

  defp conflict_line(graph, tasks_by_id, %Task{} = task, %{
         via: via_id,
         source: source_id,
         date: date
       }) do
    via_title = title_for(tasks_by_id, via_id)
    own_date = Format.date(Graph.own_deadline(graph, task.id))

    through =
      if via_id != source_id, do: " (through '#{title_for(tasks_by_id, source_id)}')", else: ""

    "Due #{own_date}, but '#{via_title}'#{through} waits on it and is due #{Format.date(date)}."
  end

  defp title_for(tasks_by_id, id) do
    case Map.get(tasks_by_id, id) do
      %Task{title: title} -> title
      nil -> "a deleted task"
    end
  end

  # -- dependencies section (TSK-10/15, DR-35/36) --------------------------------------

  @doc "The `task[owner]`-style status word for a dependency chip: \"To do\"/\"In progress\"/\"Done\"."
  @spec dependency_status_label(:to_do | :in_progress | :done) :: String.t()
  def dependency_status_label(:to_do), do: "To do"
  def dependency_status_label(:in_progress), do: "In progress"
  def dependency_status_label(:done), do: "Done"

  defp chip_class do
    "inline-flex items-center gap-1.5 rounded-chip border border-line-strong bg-surface " <>
      "px-2.5 py-1 text-xs font-medium text-ink"
  end

  @doc """
  `TSK-15`'s "Waits on"/"Waiting on this" forest, rendered as nested
  `<details>`/`<summary>` (zero JS, `DR-36`): a node with children hides its own next
  level behind its `<summary>`; a leaf (`children == []`) renders as a plain link; a real
  cycle (`children == :cut`, `WeddingPlanner.Tasks.Graph.waits_on_tree/2`'s own
  moduledoc) renders "(shown above)" instead of recursing. Every node links to
  `/tasks?open=<id>` (`TSK-15`'s "detail view" deep link).
  """
  attr :nodes, :list, required: true
  attr :tasks_by_id, :map, required: true

  def dependency_tree(assigns) do
    ~H"""
    <ul class="ml-4 list-none space-y-1">
      <li :for={{id, children} <- @nodes}>
        <span :if={children == :cut} class="text-ink-faint">
          {title_for(@tasks_by_id, id)} (shown above)
        </span>
        <.link
          :if={children == []}
          navigate={~p"/tasks?open=#{id}"}
          class="text-accent hover:underline"
        >
          {title_for(@tasks_by_id, id)}
        </.link>
        <details :if={is_list(children) and children != []}>
          <summary class="cursor-pointer select-none">
            <.link navigate={~p"/tasks?open=#{id}"} class="text-accent hover:underline">
              {title_for(@tasks_by_id, id)}
            </.link>
          </summary>
          <.dependency_tree nodes={children} tasks_by_id={@tasks_by_id} />
        </details>
      </li>
    </ul>
    """
  end

  # -- owner display and picker (TSK-01, D-28) ----------------------------------------

  @doc """
  The row's owner text (`TSK-01`): each user's `display_name`, `"Both"` (shared) or
  `"Nobody"`. `task.owner` must already be preloaded.
  """
  @spec owner_text(Task.t()) :: String.t()
  def owner_text(%Task{owner_shared: true}), do: "Both"
  def owner_text(%Task{owner_id: nil}), do: "Nobody"
  def owner_text(%Task{owner: %User{display_name: name}}), do: name

  @doc """
  The current `task[owner]` select value for `form` (see the moduledoc's "Owner is not a
  form field" section): `""` for nobody, `"shared"` for both, or the owner's id as a
  string.
  """
  @spec owner_value(Phoenix.HTML.Form.t()) :: String.t()
  def owner_value(form) do
    cond do
      truthy?(form[:owner_shared].value) -> "shared"
      owner_id = present(form[:owner_id].value) -> to_string(owner_id)
      true -> ""
    end
  end

  @doc """
  The `task[owner]` select's options: `"Nobody"` (`""`), `"Both"` (`"shared"`), then each
  assignable user by display name (`DR-22` — `users` must already be filtered to
  `WeddingPlanner.Accounts.Users.list_assignable/0`; never hard-code two users, `D-28`).
  """
  @spec owner_options([User.t()]) :: [{String.t(), String.t()}]
  def owner_options(users) do
    [{"Nobody", ""}, {"Both", "shared"}] ++ Enum.map(users, &{&1.display_name, to_string(&1.id)})
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value

  # -- link display and picker (TSK-01, DR-26 Q17/Q18) --------------------------------

  @doc """
  The current `task[link]` select value for `form` (see the moduledoc's "Link is not a
  form field either" section): `""` for none, `"event:<id>"`, or `"category:<id>"`.
  """
  @spec link_value(Phoenix.HTML.Form.t()) :: String.t()
  def link_value(form) do
    cond do
      event_id = present(form[:link_event_id].value) -> "event:#{event_id}"
      category_id = present(form[:link_category_id].value) -> "category:#{category_id}"
      true -> ""
    end
  end

  @doc """
  The `task[link]` select's grouped options: an "Events" `<optgroup>` then a
  "Categories" one (`DR-26` Q17/Q18 — offer/invoice groups join in slice T4).
  """
  @spec link_options([Event.t()], [Category.t()]) :: [{String.t(), [{String.t(), String.t()}]}]
  def link_options(events, categories) do
    [
      {"Events", Enum.map(events, &{&1.name, "event:#{&1.id}"})},
      {"Categories", Enum.map(categories, &{&1.name, "category:#{&1.id}"})}
    ]
  end

  # -- deadline-kind switch (traps: no stale fields visible or submitted) -------------

  @doc "The currently selected deadline kind on `form`, as a string (`\"none\"`/`\"fixed\"`/`\"relative\"`)."
  @spec deadline_kind(Phoenix.HTML.Form.t()) :: String.t()
  def deadline_kind(form), do: to_string(form[:deadline_kind].value)

  @doc "The currently selected status on `form`, as a string (`TSK-12`'s editor warning)."
  @spec status_value(Phoenix.HTML.Form.t()) :: String.t()
  def status_value(form), do: to_string(form[:status].value)

  # `TSK-12`'s warning wording, shared by the row's one-tap-complete warning and the
  # editor's inline warning: "Still waiting on: 'Confirm venue', 'Book band'."
  defp still_waiting_text(titles) do
    "Still waiting on: " <> Enum.map_join(titles, ", ", &"'#{&1}'") <> "."
  end

  # -- button styling (see moduledoc: why not `<.button>` for these) ------------------

  defp secondary_button_class do
    "inline-flex min-h-11 items-center justify-center gap-2 rounded-field px-4 text-sm font-semibold " <>
      "cursor-pointer transition-all duration-150 ease-out active:scale-[0.98] " <>
      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-paper " <>
      "disabled:cursor-not-allowed disabled:opacity-50 disabled:active:scale-100 " <>
      "bg-transparent text-ink border border-line-strong hover:bg-surface active:bg-line"
  end

  defp destructive_button_class do
    "inline-flex min-h-11 items-center justify-center gap-2 rounded-field px-4 text-sm font-semibold " <>
      "cursor-pointer transition-all duration-150 ease-out active:scale-[0.98] " <>
      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-paper " <>
      "disabled:cursor-not-allowed disabled:opacity-50 disabled:active:scale-100 " <>
      "bg-bad text-white shadow-sm hover:opacity-90 active:opacity-95"
  end
end
