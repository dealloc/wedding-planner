defmodule WeddingPlannerWeb.Live.CategoryLive do
  @moduledoc """
  A category's own page (task 29; `/categories/:id`) — where its services are managed,
  banded by wanted priority (`CST-51`, `DR-26` Q13). This screen is deliberately built as
  the future comparison matrix (slice C4): services as rows, grouped Must-have /
  Nice-to-have / Not wanted, in that order, with row-header controls and horizontal room
  left for C4's offer columns (`Layouts.app` `width="wide"`). C4 adds offer columns to
  this page instead of replacing it.

  ## Bands are three separate streams

  `WeddingPlannerWeb.AGENTS`-documented streams are not enumerable, so a single
  `:services` stream cannot be filtered into three bands in the template (`AGENTS.md`).
  Instead this LiveView keeps three streams — `:services_must_have`,
  `:services_nice_to_have`, `:services_not_wanted` — and `refresh_bands/1,2` refetches
  `WeddingPlanner.Categories.list_services/1`, decorates it once (so `first?`/`last?`
  reflect the **category's overall manual order**, not a position within a band — moving
  a service up/down never changes which band it is in, only its global `sort_order`),
  splits by `wanted_priority`, and re-streams every band with `reset: true`. Every local
  mutation (rename, priority change, move, merge, delete) and every matching `:service`
  broadcast goes through this same full refresh — the dataset is one category's worth of
  services, small enough that this stays cheap (same reasoning as
  `WeddingPlannerWeb.Live.EventsLive`'s moduledoc).

  ## Inline rename (a trap worth restating)

  Each row's name is a one-field `<.form>` (a sibling of the add-service form and every
  other row's own form — never nested) bound to both `phx-change` (with
  `phx-debounce="blur"` on the input, so it fires once on blur, never per keystroke) and
  `phx-submit` (so Enter commits immediately too, and does not fall through to a native
  page-reloading form submission). Both fire the same `"rename_service"` event.

  ## Delete vs. merge/not-wanted (`CST-06`, `D-34`, `DR-26` Q12)

  Clicking a row's Delete checks `WeddingPlanner.Categories.service_line_count/1` **before**
  attempting the delete (not just on failure) so the confirmation panel is right the first
  time: `0` shows the normal `CoreComponents.destructive_confirm/1` delete confirmation;
  greater than `0` shows a different panel with no delete button, only "Set to not wanted"
  and a pointer to the row's own always-visible "Merge into…" control (which needs no
  special-casing for this path — it is simply the same control every row has). This
  mirrors `WeddingPlanner.Categories.delete_service/2`'s own `{:error, :has_lines}` guard,
  so the two can never disagree; the `:error` branch is kept as a defensive fallback in
  case of a race between the check and the click.

  ## Merge (`CST-04`, `DR-26` Q14)

  A row's persistent "Merge into…" select + button asks for confirmation
  (`@confirming_merge_id`/`@merge_survivor_id`) before calling
  `WeddingPlanner.Categories.merge_services/3` — merging deletes the absorbed service, so
  `XC-40` applies just as much as a plain delete. Hidden entirely when there is only one
  service in the category (nothing to merge into).

  ## History (`XC-11`)

  The category's own history is shown once, at the bottom, and every service's history is
  an expandable `<details>` disclosure using the same
  `WeddingPlannerWeb.ActivityComponents.entity_history/1` component. Both are fetched
  eagerly (again, small per-category data) and kept live: `:activity_entry` broadcasts are
  matched by entity type/id and prepended, the documented host pattern from that
  component's moduledoc — `:service`/`:category` broadcasts additionally trigger a full
  `refresh_bands/1` (or, for `:category`, just replacing the header's category struct),
  which already re-fetches every shown history from the database, so the two mechanisms
  never disagree, only occasionally do redundant work.

  Per `DR-21`/`XC-02` every live update is silent — no highlight, badge or indicator.
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.ActivityComponents, only: [entity_history: 1]

  alias WeddingPlanner.Categories
  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.Realtime
  alias WeddingPlannerWeb.Format

  on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

  @priority_streams %{
    must_have: :services_must_have,
    nice_to_have: :services_nice_to_have,
    not_wanted: :services_not_wanted
  }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    category = Categories.get_category!(id)

    if connected?(socket) do
      Realtime.subscribe(:category)
      Realtime.subscribe(:service)
      Realtime.subscribe(:activity_entry)
    end

    socket =
      socket
      |> assign(:page_title, category.name)
      |> assign(:category, category)
      |> assign(:confirming_delete_service_id, nil)
      |> assign(:confirming_delete_has_lines?, false)
      |> assign(:confirming_merge_id, nil)
      |> assign(:merge_survivor_id, nil)
      |> assign(:add_service_form, fresh_add_service_form(category))
      |> assign(:category_activity_entries, Query.for_entity(:category, category.id))
      |> refresh_bands()

    {:ok, socket}
  end

  # -- add / rename / priority ----------------------------------------------------------

  @impl true
  def handle_event("validate_service", %{"service" => params}, socket) do
    form =
      %Service{category_id: socket.assigns.category.id}
      |> Categories.change_service(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :add_service_form, form)}
  end

  def handle_event("create_service", %{"service" => params}, socket) do
    category = socket.assigns.category

    case Categories.create_service(socket.assigns.current_scope, category, params) do
      {:ok, _service} ->
        socket =
          socket
          |> assign(:add_service_form, fresh_add_service_form(category))
          |> refresh_bands()

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :add_service_form, to_form(changeset))}
    end
  end

  def handle_event("rename_service", %{"id" => id, "service" => params}, socket) do
    service = Categories.get_service!(id)

    case Categories.update_service(socket.assigns.current_scope, service, params) do
      {:ok, _updated} ->
        {:noreply, refresh_bands(socket)}

      {:error, changeset} ->
        {:noreply, refresh_bands(socket, %{service.id => to_form(changeset)})}
    end
  end

  def handle_event("change_priority", %{"id" => id, "wanted_priority" => value}, socket) do
    service = Categories.get_service!(id)

    {:ok, _updated} =
      Categories.update_service(socket.assigns.current_scope, service, %{
        "wanted_priority" => value
      })

    {:noreply, refresh_bands(socket)}
  end

  # -- move (within the category's overall order) -------------------------------------

  def handle_event("move_service_up", %{"id" => id}, socket), do: move_service(socket, id, :up)

  def handle_event("move_service_down", %{"id" => id}, socket),
    do: move_service(socket, id, :down)

  # -- delete (CST-06, D-34, DR-26 Q12) --------------------------------------------------

  def handle_event("confirm_delete_service", %{"id" => id}, socket) do
    service = Categories.get_service!(id)
    has_lines? = Categories.service_line_count(service) > 0

    socket =
      socket
      |> assign(:confirming_delete_service_id, service.id)
      |> assign(:confirming_delete_has_lines?, has_lines?)
      |> stream_insert_service_row(service.id)

    {:noreply, socket}
  end

  def handle_event("cancel_delete_service", _params, socket) do
    id = socket.assigns.confirming_delete_service_id

    socket =
      socket
      |> assign(:confirming_delete_service_id, nil)
      |> assign(:confirming_delete_has_lines?, false)
      |> stream_insert_service_row(id)

    {:noreply, socket}
  end

  def handle_event("delete_service_confirmed", %{"id" => id}, socket) do
    service = Categories.get_service!(id)

    case Categories.delete_service(socket.assigns.current_scope, service) do
      {:ok, _} ->
        socket =
          socket
          |> assign(:confirming_delete_service_id, nil)
          |> assign(:confirming_delete_has_lines?, false)
          |> refresh_bands()

        {:noreply, socket}

      {:error, :has_lines} ->
        socket =
          socket
          |> assign(:confirming_delete_has_lines?, true)
          |> stream_insert_service_row(service.id)

        {:noreply, socket}
    end
  end

  def handle_event("set_not_wanted", %{"id" => id}, socket) do
    service = Categories.get_service!(id)

    {:ok, _} =
      Categories.update_service(socket.assigns.current_scope, service, %{
        "wanted_priority" => "not_wanted"
      })

    socket =
      socket
      |> assign(:confirming_delete_service_id, nil)
      |> assign(:confirming_delete_has_lines?, false)
      |> refresh_bands()

    {:noreply, socket}
  end

  # -- merge (CST-04, DR-26 Q14) ---------------------------------------------------------

  def handle_event("request_merge", %{"id" => id, "survivor_id" => survivor_id}, socket) do
    socket =
      socket
      |> assign(:confirming_merge_id, String.to_integer(id))
      |> assign(:merge_survivor_id, String.to_integer(survivor_id))
      |> stream_insert_service_row(String.to_integer(id))

    {:noreply, socket}
  end

  def handle_event("cancel_merge", _params, socket) do
    id = socket.assigns.confirming_merge_id

    socket =
      socket
      |> assign(:confirming_merge_id, nil)
      |> assign(:merge_survivor_id, nil)
      |> stream_insert_service_row(id)

    {:noreply, socket}
  end

  def handle_event("merge_confirmed", %{"id" => id}, socket) do
    absorbed = Categories.get_service!(id)
    survivor = Categories.get_service!(socket.assigns.merge_survivor_id)

    # {:error, :different_categories} cannot happen here in practice — the survivor is
    # always picked from the same category's own select options — kept only as a
    # defensive fallback rather than a `{:ok, _}` pattern-match that would crash the
    # LiveView process if that select were ever tampered with.
    socket =
      case Categories.merge_services(socket.assigns.current_scope, absorbed, survivor) do
        {:ok, _survivor} -> refresh_bands(socket)
        {:error, :different_categories} -> refresh_bands(socket)
      end

    socket =
      socket
      |> assign(:confirming_merge_id, nil)
      |> assign(:merge_survivor_id, nil)

    {:noreply, socket}
  end

  # -- live updates (XC-01, XC-02) -------------------------------------------------------

  @impl true
  def handle_info({Realtime, :category, {:updated, updated}}, socket) do
    if updated.id == socket.assigns.category.id do
      {:noreply, assign(socket, :category, updated)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({Realtime, :category, {:deleted, id}}, socket) do
    if id == socket.assigns.category.id do
      {:noreply, push_navigate(socket, to: ~p"/categories")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({Realtime, :category, _event}, socket), do: {:noreply, socket}

  def handle_info({Realtime, :service, _event}, socket), do: {:noreply, refresh_bands(socket)}

  def handle_info({Realtime, :activity_entry, {:created, entry}}, socket) do
    %{category: category} = socket.assigns

    cond do
      entry.entity_type == "category" and entry.entity_id == category.id ->
        entry = Query.preload_user(entry)
        {:noreply, update(socket, :category_activity_entries, &[entry | &1])}

      entry.entity_type == "service" and
          Map.has_key?(socket.assigns.service_histories, entry.entity_id) ->
        entry = Query.preload_user(entry)

        socket =
          update(socket, :service_histories, fn histories ->
            Map.update!(histories, entry.entity_id, &[entry | &1])
          end)

        {:noreply, socket}

      true ->
        {:noreply, socket}
    end
  end

  # -- private -----------------------------------------------------------------------

  defp move_service(socket, id, direction) do
    service = Categories.get_service!(id)
    :ok = Categories.move_service(socket.assigns.current_scope, service, direction)

    {:noreply, refresh_bands(socket)}
  end

  defp fresh_add_service_form(category) do
    to_form(Categories.change_service(%Service{category_id: category.id}))
  end

  defp refresh_bands(socket), do: refresh_bands(socket, %{})

  defp refresh_bands(socket, override_forms) do
    category = socket.assigns.category
    services = Categories.list_services(category)
    decorated = decorate_service_rows(services)

    rename_forms =
      Map.new(services, fn service ->
        form = Map.get(override_forms, service.id) || to_form(Categories.change_service(service))
        {service.id, form}
      end)

    service_histories = Map.new(services, &{&1.id, Query.for_entity(:service, &1.id)})

    socket
    |> assign(:all_services, services)
    |> assign(:rename_forms, rename_forms)
    |> assign(:service_histories, service_histories)
    |> stream(:services_must_have, band_rows(decorated, :must_have), reset: true)
    |> stream(:services_nice_to_have, band_rows(decorated, :nice_to_have), reset: true)
    |> stream(:services_not_wanted, band_rows(decorated, :not_wanted), reset: true)
  end

  defp decorate_service_rows(services) do
    last_index = length(services) - 1

    services
    |> Enum.with_index()
    |> Enum.map(fn {service, idx} ->
      %{id: service.id, service: service, first?: idx == 0, last?: idx == last_index}
    end)
  end

  defp band_rows(decorated, priority) do
    Enum.filter(decorated, &(&1.service.wanted_priority == priority))
  end

  defp priority_stream_key(priority), do: Map.fetch!(@priority_streams, priority)

  defp stream_insert_service_row(socket, nil), do: socket

  defp stream_insert_service_row(socket, id) do
    service = Categories.get_service!(id)
    decorated = decorate_service_rows(Categories.list_services(socket.assigns.category))
    row = Enum.find(decorated, &(&1.id == service.id))

    stream_insert(socket, priority_stream_key(service.wanted_priority), row)
  rescue
    Ecto.NoResultsError -> socket
  end

  defp other_services(%Service{} = service, all_services) do
    Enum.reject(all_services, &(&1.id == service.id))
  end

  defp merge_survivor_name(nil, _all_services), do: ""

  defp merge_survivor_name(id, all_services) do
    case Enum.find(all_services, &(&1.id == id)) do
      nil -> ""
      service -> service.name
    end
  end

  defp priority_options do
    Enum.map(Service.wanted_priorities(), &{priority_label(&1), Atom.to_string(&1)})
  end

  defp priority_label(:not_wanted), do: "Not wanted"
  defp priority_label(:nice_to_have), do: "Nice-to-have"
  defp priority_label(:must_have), do: "Must-have"

  defp target_display(nil), do: "No target"
  defp target_display(%Money{} = money), do: Format.money(money)

  # -- render --------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width="wide">
      <.header>
        {@category.name}
        <:subtitle>
          Target: <span id="category-target">{target_display(@category.target)}</span>
        </:subtitle>
        <:actions>
          <.button navigate={~p"/categories/#{@category.id}/edit"} id="category-edit">
            Edit
          </.button>
          <.button navigate={~p"/categories"} id="back-to-categories">Back to categories</.button>
        </:actions>
      </.header>

      <div class="space-y-6">
        <.service_band
          dom_id="band-must-have"
          label="Must-have"
          stream={@streams.services_must_have}
          all_services={@all_services}
          rename_forms={@rename_forms}
          service_histories={@service_histories}
          confirming_delete_service_id={@confirming_delete_service_id}
          confirming_delete_has_lines?={@confirming_delete_has_lines?}
          confirming_merge_id={@confirming_merge_id}
          merge_survivor_id={@merge_survivor_id}
          time_zone={@time_zone}
        />
        <.service_band
          dom_id="band-nice-to-have"
          label="Nice-to-have"
          stream={@streams.services_nice_to_have}
          all_services={@all_services}
          rename_forms={@rename_forms}
          service_histories={@service_histories}
          confirming_delete_service_id={@confirming_delete_service_id}
          confirming_delete_has_lines?={@confirming_delete_has_lines?}
          confirming_merge_id={@confirming_merge_id}
          merge_survivor_id={@merge_survivor_id}
          time_zone={@time_zone}
        />
        <.service_band
          dom_id="band-not-wanted"
          label="Not wanted"
          stream={@streams.services_not_wanted}
          all_services={@all_services}
          rename_forms={@rename_forms}
          service_histories={@service_histories}
          confirming_delete_service_id={@confirming_delete_service_id}
          confirming_delete_has_lines?={@confirming_delete_has_lines?}
          confirming_merge_id={@confirming_merge_id}
          merge_survivor_id={@merge_survivor_id}
          time_zone={@time_zone}
        />
      </div>

      <div class="mt-6 rounded-field border border-line bg-surface-raised p-4">
        <h2 class="mb-3 text-sm font-semibold text-ink">Add service</h2>
        <.form
          for={@add_service_form}
          id="add-service-form"
          phx-change="validate_service"
          phx-submit="create_service"
          class="flex flex-wrap items-end gap-3"
        >
          <.input field={@add_service_form[:name]} type="text" label="Name" id="add-service-name" />
          <.input
            field={@add_service_form[:wanted_priority]}
            type="select"
            label="Wanted priority"
            id="add-service-priority"
            options={priority_options()}
          />
          <.button variant="primary" id="add-service-submit">Add service</.button>
        </.form>
      </div>

      <div class="mt-8">
        <.header>History</.header>
        <.entity_history
          id="category-history"
          entity={{:category, @category.id}}
          entries={@category_activity_entries}
          time_zone={@time_zone}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :dom_id, :string, required: true
  attr :label, :string, required: true
  attr :stream, :any, required: true
  attr :all_services, :list, required: true
  attr :rename_forms, :map, required: true
  attr :service_histories, :map, required: true
  attr :confirming_delete_service_id, :any, required: true
  attr :confirming_delete_has_lines?, :boolean, required: true
  attr :confirming_merge_id, :any, required: true
  attr :merge_survivor_id, :any, required: true
  attr :time_zone, :string, default: nil

  defp service_band(assigns) do
    ~H"""
    <section>
      <h2 class="mb-2 text-sm font-semibold uppercase tracking-wide text-ink-soft">
        {@label}
      </h2>
      <ul id={@dom_id} phx-update="stream" class="space-y-3">
        <li
          id={"#{@dom_id}-empty"}
          class="hidden rounded-field border border-dashed border-line-strong p-4 text-center text-sm text-ink-faint only:block"
        >
          No services
        </li>
        <li
          :for={{dom_id, row} <- @stream}
          id={dom_id}
          class="rounded-field border border-line bg-surface-raised p-4"
        >
          <.service_row
            row={row}
            all_services={@all_services}
            form={@rename_forms[row.service.id]}
            history={@service_histories[row.service.id] || []}
            confirming_delete={@confirming_delete_service_id == row.service.id}
            confirming_delete_has_lines?={@confirming_delete_has_lines?}
            confirming_merge={@confirming_merge_id == row.service.id}
            merge_survivor_id={@merge_survivor_id}
            time_zone={@time_zone}
          />
        </li>
      </ul>
    </section>
    """
  end

  attr :row, :map, required: true
  attr :all_services, :list, required: true
  attr :form, :any, required: true
  attr :history, :list, required: true
  attr :confirming_delete, :boolean, required: true
  attr :confirming_delete_has_lines?, :boolean, required: true
  attr :confirming_merge, :boolean, required: true
  attr :merge_survivor_id, :any, required: true
  attr :time_zone, :string, default: nil

  defp service_row(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div class="min-w-0 flex-1 space-y-2">
          <.form
            for={@form}
            id={"service-#{@row.service.id}-rename-form"}
            phx-change="rename_service"
            phx-submit="rename_service"
            phx-value-id={@row.service.id}
          >
            <.input
              field={@form[:name]}
              type="text"
              label="Name"
              id={"service-#{@row.service.id}-name-input"}
              phx-debounce="blur"
            />
          </.form>

          <.form
            for={to_form(%{}, as: :priority)}
            id={"service-#{@row.service.id}-priority-form"}
            phx-change="change_priority"
            phx-value-id={@row.service.id}
          >
            <.input
              type="select"
              id={"service-#{@row.service.id}-priority"}
              name="wanted_priority"
              value={Atom.to_string(@row.service.wanted_priority)}
              options={priority_options()}
              label="Priority"
            />
          </.form>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <button
            type="button"
            id={"service-#{@row.service.id}-move-up"}
            phx-click="move_service_up"
            phx-value-id={@row.service.id}
            disabled={@row.first?}
            aria-label={"Move #{@row.service.name} up"}
            class="inline-flex min-h-11 min-w-11 items-center justify-center rounded-field border border-line-strong text-ink-soft transition hover:bg-surface disabled:cursor-not-allowed disabled:opacity-40"
          >
            <.icon name="hero-chevron-up" />
          </button>
          <button
            type="button"
            id={"service-#{@row.service.id}-move-down"}
            phx-click="move_service_down"
            phx-value-id={@row.service.id}
            disabled={@row.last?}
            aria-label={"Move #{@row.service.name} down"}
            class="inline-flex min-h-11 min-w-11 items-center justify-center rounded-field border border-line-strong text-ink-soft transition hover:bg-surface disabled:cursor-not-allowed disabled:opacity-40"
          >
            <.icon name="hero-chevron-down" />
          </button>
          <.button
            variant="destructive"
            phx-click="confirm_delete_service"
            phx-value-id={@row.service.id}
            id={"service-#{@row.service.id}-delete"}
          >
            Delete
          </.button>
        </div>
      </div>

      <.form
        :if={other_services(@row.service, @all_services) != []}
        for={to_form(%{}, as: :merge)}
        id={"service-#{@row.service.id}-merge-form"}
        phx-submit="request_merge"
        phx-value-id={@row.service.id}
        class="flex flex-wrap items-end gap-3"
      >
        <.input
          type="select"
          id={"service-#{@row.service.id}-merge-select"}
          name="survivor_id"
          value=""
          options={Enum.map(other_services(@row.service, @all_services), &{&1.name, &1.id})}
          label="Merge into"
        />
        <.button id={"service-#{@row.service.id}-merge-submit"}>Merge</.button>
      </.form>

      <.destructive_confirm
        :if={@confirming_delete and not @confirming_delete_has_lines?}
        id={"service-#{@row.service.id}-delete-confirm"}
        title={"Delete '#{@row.service.name}'?"}
        body="This cannot be undone."
        confirm="delete_service_confirmed"
        confirm_value={@row.service.id}
        cancel="cancel_delete_service"
      />

      <div
        :if={@confirming_delete and @confirming_delete_has_lines?}
        id={"service-#{@row.service.id}-delete-confirm"}
        role="alertdialog"
        aria-labelledby={"service-#{@row.service.id}-delete-confirm-title"}
        class="rounded-field border border-line-strong bg-surface p-4"
      >
        <p
          id={"service-#{@row.service.id}-delete-confirm-title"}
          class="text-sm font-semibold text-ink"
        >
          Can't delete '{@row.service.name}'
        </p>
        <p class="mt-1 text-sm text-ink-soft">
          It has priced offer lines. Merge it into another service above, or set it to not
          wanted instead.
        </p>
        <div class="mt-4 flex flex-wrap gap-2">
          <.button
            id={"service-#{@row.service.id}-delete-confirm-cancel"}
            phx-click="cancel_delete_service"
          >
            Cancel
          </.button>
          <.button
            variant="primary"
            id={"service-#{@row.service.id}-delete-confirm-set-not-wanted"}
            phx-click="set_not_wanted"
            phx-value-id={@row.service.id}
          >
            Set to not wanted
          </.button>
        </div>
      </div>

      <.destructive_confirm
        :if={@confirming_merge}
        id={"service-#{@row.service.id}-merge-confirm"}
        title={"Merge '#{@row.service.name}' into '#{merge_survivor_name(@merge_survivor_id, @all_services)}'?"}
        body="This cannot be undone."
        confirm="merge_confirmed"
        confirm_value={@row.service.id}
        confirm_label="Merge"
        cancel="cancel_merge"
      />

      <details id={"service-#{@row.service.id}-history-disclosure"} class="text-sm">
        <summary class="cursor-pointer text-ink-soft hover:text-ink">History</summary>
        <div class="mt-2">
          <.entity_history
            id={"service-#{@row.service.id}-history"}
            entity={{:service, @row.service.id}}
            entries={@history}
            time_zone={@time_zone}
          />
        </div>
      </details>
    </div>
    """
  end
end
