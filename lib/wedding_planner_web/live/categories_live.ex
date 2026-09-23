defmodule WeddingPlannerWeb.Live.CategoriesLive do
  @moduledoc """
  The categories list (task 29; `docs/modules/offers-and-comparison.md` `CST-01`,
  `CST-05`; `DR-26` Q11, Q13) — create, edit, reorder and delete a category. Each
  category's own services live on its own page, `WeddingPlannerWeb.Live.CategoryLive`
  (`/categories/:id`).

  Copies `WeddingPlannerWeb.Live.EventsLive`'s exemplar shape verbatim: one LiveView,
  three routes sharing it via `@live_action` (`:index`, `:new`, `:edit`), the `:categories`
  stream re-streamed with `reset: true` on every local mutation or matching broadcast, and
  the `CoreComponents.destructive_confirm/1` delete-confirmation pattern.

  ## Deletion (`DR-26` Q11)

  A category is deletable only when `WeddingPlanner.Categories.category_deletion_blockers/1`
  is empty. That check is always `[]` today (no offers or invoices exist yet), so the
  "can't delete" branch below is structurally present but not reachable with real data
  until the slices that add blockers land — same C1/C2-style split as
  `WeddingPlanner.Categories.service_line_count/1`. When blockers exist, the confirmation
  explains why instead of offering a delete button; otherwise it lists what deleting the
  category removes (`category_deletion_effects/1` — its services).

  ## Money input (`DR-23`, `DR-18`)

  The target field binds to the changeset's virtual `:target_input`, never to `:target`
  itself. On `:edit`, the current target is pre-filled into `:target_input` as display
  text (stripping the `Format.money/1` "€ " prefix) so the user sees and can amend
  the current value — copied from `WeddingPlannerWeb.Live.SettingsLive`'s
  `assign_form/2` pattern for `:overall_budget_input`. A blank submission clears the
  target back to unset; an omitted key (never happens from this form, which always
  submits the field) would leave it untouched.

  ## Live updates (`XC-01`, `XC-02`)

  `mount/3` subscribes to the `:category` collection topic. Per `DR-21`/`XC-02`, a live
  update is silent. `:edit` additionally subscribes to `:activity_entry` and follows the
  exact host pattern documented in `WeddingPlannerWeb.ActivityComponents.entity_history/1`'s
  moduledoc.
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.ActivityComponents, only: [entity_history: 1]

  alias WeddingPlanner.Categories
  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.Realtime
  alias WeddingPlannerWeb.Format

  on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

  @resource :category

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Realtime.subscribe(@resource)

    socket =
      socket
      |> assign(:confirming_delete_id, nil)
      |> assign(:confirming_delete_blockers, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case socket.assigns.live_action do
        :index -> assign_index(socket)
        :new -> assign_form(socket, %Category{})
        :edit -> assign_edit(socket, params["id"])
      end

    {:noreply, socket}
  end

  defp assign_index(socket) do
    socket
    |> assign(:page_title, "Categories")
    |> assign(:confirming_delete_id, nil)
    |> assign(:confirming_delete_blockers, [])
    |> stream(:categories, decorate_rows(Categories.list_categories()), reset: true)
  end

  defp assign_form(socket, %Category{} = category) do
    socket
    |> assign(:page_title, if(category.id, do: "Edit category", else: "New category"))
    |> assign(:category, category)
    |> assign(:form, to_form(change_category_with_target(category)))
  end

  defp assign_edit(socket, id) do
    category = Categories.get_category!(id)
    if connected?(socket), do: Realtime.subscribe(:activity_entry)

    socket
    |> assign_form(category)
    |> assign(:activity_entries, Query.for_entity(:category, category.id))
  end

  defp change_category_with_target(%Category{} = category) do
    category
    |> Categories.change_category()
    |> Ecto.Changeset.put_change(:target_input, target_input_value(category.target))
  end

  defp target_input_value(nil), do: ""

  defp target_input_value(%Money{} = money) do
    money |> Format.money() |> String.replace_prefix("€ ", "")
  end

  defp stream_insert_row(socket, nil), do: socket

  defp stream_insert_row(socket, id) do
    case Enum.find(decorate_rows(Categories.list_categories()), &(&1.id == id)) do
      nil -> socket
      row -> stream_insert(socket, :categories, row)
    end
  end

  defp decorate_rows(categories) do
    last_index = length(categories) - 1

    categories
    |> Enum.with_index()
    |> Enum.map(fn {category, idx} ->
      %{
        id: category.id,
        category: category,
        first?: idx == 0,
        last?: idx == last_index,
        service_count: length(Categories.list_services(category))
      }
    end)
  end

  @impl true
  def handle_event("validate", %{"category" => params}, socket) do
    form =
      socket.assigns.category
      |> Categories.change_category(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"category" => params}, socket) do
    save_category(socket, socket.assigns.live_action, params)
  end

  def handle_event("move_up", %{"id" => id}, socket), do: move(socket, id, :up)
  def handle_event("move_down", %{"id" => id}, socket), do: move(socket, id, :down)

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    id = String.to_integer(id)
    category = Categories.get_category!(id)
    blockers = Categories.category_deletion_blockers(category)

    socket =
      socket
      |> assign(:confirming_delete_id, id)
      |> assign(:confirming_delete_blockers, blockers)
      |> stream_insert_row(id)

    {:noreply, socket}
  end

  def handle_event("cancel_delete", _params, socket) do
    previous_id = socket.assigns.confirming_delete_id

    socket =
      socket
      |> assign(:confirming_delete_id, nil)
      |> assign(:confirming_delete_blockers, [])
      |> stream_insert_row(previous_id)

    {:noreply, socket}
  end

  def handle_event("delete_confirmed", %{"id" => id}, socket) do
    category = Categories.get_category!(id)

    socket =
      case Categories.delete_category(socket.assigns.current_scope, category) do
        {:ok, _} ->
          socket
          |> assign(:confirming_delete_id, nil)
          |> assign(:confirming_delete_blockers, [])
          |> stream(:categories, decorate_rows(Categories.list_categories()), reset: true)

        {:error, :has_blockers} ->
          assign(
            socket,
            :confirming_delete_blockers,
            Categories.category_deletion_blockers(category)
          )
      end

    {:noreply, socket}
  end

  defp save_category(socket, :new, params) do
    case Categories.create_category(socket.assigns.current_scope, params) do
      {:ok, _category} ->
        {:noreply,
         socket
         |> put_flash(:info, "Category created.")
         |> push_navigate(to: ~p"/categories")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save_category(socket, :edit, params) do
    case Categories.update_category(socket.assigns.current_scope, socket.assigns.category, params) do
      {:ok, _category} ->
        {:noreply,
         socket
         |> put_flash(:info, "Category updated.")
         |> push_navigate(to: ~p"/categories")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp move(socket, id, direction) do
    category = Categories.get_category!(id)
    :ok = Categories.move_category(socket.assigns.current_scope, category, direction)

    {:noreply,
     stream(socket, :categories, decorate_rows(Categories.list_categories()), reset: true)}
  end

  @impl true
  def handle_info({Realtime, @resource, _event}, %{assigns: %{live_action: :index}} = socket) do
    {:noreply,
     stream(socket, :categories, decorate_rows(Categories.list_categories()), reset: true)}
  end

  def handle_info({Realtime, @resource, _event}, socket), do: {:noreply, socket}

  def handle_info({Realtime, :activity_entry, {:created, entry}}, socket) do
    %{category: category} = socket.assigns

    if entry.entity_type == "category" and entry.entity_id == category.id do
      entry = Query.preload_user(entry)
      {:noreply, update(socket, :activity_entries, &[entry | &1])}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Categories
        <:actions>
          <.button variant="primary" navigate={~p"/categories/new"} id="new-category">
            Add category
          </.button>
        </:actions>
      </.header>

      <ul id="categories" phx-update="stream" class="space-y-3">
        <li
          id="categories-empty"
          class="hidden rounded-field border border-dashed border-line-strong p-6 text-center text-sm text-ink-faint only:block"
        >
          No categories yet.
          <.link navigate={~p"/categories/new"} class="font-medium text-accent hover:underline">
            Add the first one.
          </.link>
        </li>
        <li
          :for={{dom_id, row} <- @streams.categories}
          id={dom_id}
          class="rounded-field border border-line bg-surface-raised p-4"
        >
          <.category_row
            row={row}
            confirming={@confirming_delete_id == row.category.id}
            blockers={@confirming_delete_blockers}
          />
        </li>
      </ul>
    </Layouts.app>
    """
  end

  def render(%{live_action: action} = assigns) when action in [:new, :edit] do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {if @live_action == :new, do: "New category", else: "Edit category"}
        <:actions>
          <.button navigate={~p"/categories"} id="back-to-categories">Back to categories</.button>
        </:actions>
      </.header>

      <.form
        for={@form}
        id="category-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-4"
      >
        <.input field={@form[:name]} type="text" label="Name" id="category-form-name" />
        <.input
          field={@form[:target_input]}
          type="text"
          label="Target (optional, e.g. 2.500 or 2500,00)"
          id="category-form-target"
        />

        <.button variant="primary" id="category-form-submit">Save category</.button>
      </.form>

      <div :if={@live_action == :edit} class="mt-8">
        <.header>History</.header>
        <.entity_history
          id="category-history"
          entity={{:category, @category.id}}
          entries={@activity_entries}
          time_zone={@time_zone}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :row, :map, required: true
  attr :confirming, :boolean, required: true
  attr :blockers, :list, required: true

  defp category_row(assigns) do
    ~H"""
    <div>
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div class="min-w-0">
          <p id={"category-#{@row.category.id}-name"} class="font-semibold text-ink">
            <.link navigate={~p"/categories/#{@row.category.id}"} class="hover:underline">
              {@row.category.name}
            </.link>
          </p>
          <p class="text-sm text-ink-soft">
            <span id={"category-#{@row.category.id}-target"} class="tabular-nums">
              {target_display(@row.category.target)}
            </span>
            <span aria-hidden="true">&middot;</span>
            <span id={"category-#{@row.category.id}-service-count"}>
              {@row.service_count} {pluralize(@row.service_count, "service")}
            </span>
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <button
            type="button"
            id={"category-#{@row.category.id}-move-up"}
            phx-click="move_up"
            phx-value-id={@row.category.id}
            disabled={@row.first?}
            aria-label={"Move #{@row.category.name} up"}
            class="inline-flex min-h-11 min-w-11 items-center justify-center rounded-field border border-line-strong text-ink-soft transition hover:bg-surface disabled:cursor-not-allowed disabled:opacity-40"
          >
            <.icon name="hero-chevron-up" />
          </button>
          <button
            type="button"
            id={"category-#{@row.category.id}-move-down"}
            phx-click="move_down"
            phx-value-id={@row.category.id}
            disabled={@row.last?}
            aria-label={"Move #{@row.category.name} down"}
            class="inline-flex min-h-11 min-w-11 items-center justify-center rounded-field border border-line-strong text-ink-soft transition hover:bg-surface disabled:cursor-not-allowed disabled:opacity-40"
          >
            <.icon name="hero-chevron-down" />
          </button>
          <.button
            navigate={~p"/categories/#{@row.category.id}"}
            id={"category-#{@row.category.id}-open"}
          >
            Open
          </.button>
          <.button
            navigate={~p"/categories/#{@row.category.id}/edit"}
            id={"category-#{@row.category.id}-edit"}
          >
            Edit
          </.button>
          <.button
            variant="destructive"
            phx-click="confirm_delete"
            phx-value-id={@row.category.id}
            id={"category-#{@row.category.id}-delete"}
          >
            Delete
          </.button>
        </div>
      </div>

      <.destructive_confirm
        :if={@confirming and @blockers == []}
        id={"category-#{@row.category.id}-delete-confirm"}
        title={"Delete '#{@row.category.name}'?"}
        body="This cannot be undone."
        affected={Categories.category_deletion_effects(@row.category)}
        confirm="delete_confirmed"
        confirm_value={@row.category.id}
        cancel="cancel_delete"
      />

      <div
        :if={@confirming and @blockers != []}
        id={"category-#{@row.category.id}-delete-confirm"}
        role="alertdialog"
        aria-labelledby={"category-#{@row.category.id}-delete-confirm-title"}
        class="rounded-field border border-line-strong bg-surface p-4"
      >
        <p
          id={"category-#{@row.category.id}-delete-confirm-title"}
          class="text-sm font-semibold text-ink"
        >
          Can't delete '{@row.category.name}'
        </p>
        <ul
          id={"category-#{@row.category.id}-delete-confirm-blockers"}
          class="mt-2 list-disc space-y-0.5 pl-5 text-sm text-ink"
        >
          <li :for={blocker <- @blockers}>{blocker.label}</li>
        </ul>
        <div class="mt-4">
          <.button
            id={"category-#{@row.category.id}-delete-confirm-cancel"}
            phx-click="cancel_delete"
          >
            Close
          </.button>
        </div>
      </div>
    </div>
    """
  end

  defp target_display(nil), do: "No target"
  defp target_display(%Money{} = money), do: Format.money(money)

  defp pluralize(1, word), do: word
  defp pluralize(_n, word), do: word <> "s"
end
