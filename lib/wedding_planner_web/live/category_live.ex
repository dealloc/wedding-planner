defmodule WeddingPlannerWeb.Live.CategoryLive do
  @moduledoc """
  A category's own page (`/categories/:id`): the comparison matrix (task 65, `DR-57`;
  `docs/modules/offers-and-comparison.md` `CST-50`…`CST-55`) — offers as columns,
  services as rows banded Must-have / Nice-to-have / Not wanted (`CST-51`) with their
  existing row-header controls, an "other charges" row for ad hoc lines, and a totals
  row with a per-view preset selector and the Minimum–Maximum range (`CST-53`,
  `DR-54`). **Replaces** task 51/52's plain offers list (`DR-43`) — the add-service,
  add-offer and quick-offer forms stay.

  ## The view model is `WeddingPlanner.Valuation.Comparison.build/4`, never re-derived

  `refresh_matrix/1,2` reloads `WeddingPlanner.Valuation.Snapshot.load/1` and rebuilds
  `@matrix` from scratch on every local mutation and every matching broadcast — the
  matrix has no incremental update path, same reasoning as `refresh_bands/1` used to
  have for the three band streams alone (small per-category data, `NFR-33`). Nothing in
  this module counts, prices or decides a gap; every figure and flag comes straight out
  of `@matrix`.

  ## Bands are still three separate streams

  `WeddingPlannerWeb.AGENTS`-documented streams are not enumerable, so a single
  `:services` stream still cannot be filtered into three bands in the template
  (`AGENTS.md`). The three band streams — `:services_must_have`,
  `:services_nice_to_have`, `:services_not_wanted` — now carry, per row, both the
  service (`decorate_service_rows/2`'s `first?`/`last?`, unchanged) **and** its cells
  (one per offer, keyed by offer id, taken from `@matrix`'s matching band). Every local
  mutation and every relevant broadcast goes through `refresh_matrix/1`, which
  re-derives the decoration and re-streams every band with `reset: true` — stream items
  only re-render when re-inserted (`AGENTS.md`).

  ## The preset selection and the rejected-offers toggle are per-view, never persisted

  `@selected_preset_id` (`HC-10`, `DR-54`) and `@show_rejected?` (`CST-55`) are plain
  transient socket assigns: neither survives a reload, neither is broadcast, and two
  people looking at the same category may disagree about either without affecting the
  other's screen. `WeddingPlanner.Valuation.PresetChoice.find/2` resolves
  `@selected_preset_id` against the loaded snapshot's presets on every recompute (`nil`,
  a stale id, or no stored presets at all all fall back to the same default, likely-role
  preset) — the id is never looked up by name.

  ## Live recompute (`XC-01`)

  Subscribes to `:category`, `:service`, `:offer`, `:offer_line`, `:override`, `:event`,
  `:person`, `:group`, `:invitation`, `:plus_one_opt_out`, `:headcount_preset` and
  `:activity_entry`. Every one of the first ten calls `refresh_matrix/1` — headcounts
  and gaps both ultimately read the guest list and the stored presets, exactly like
  `WeddingPlannerWeb.Live.OfferLive`'s own Cost card subscriptions (task 57/60). Per
  `DR-21`/`XC-02`, every update is silent: no highlight, badge or "someone else changed
  this" indicator.

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
  `refresh_matrix/1` (or, for `:category`, just replacing the header's category struct),
  which already re-fetches every shown history from the database, so the two mechanisms
  never disagree, only occasionally do redundant work.

  Per `DR-21`/`XC-02` every live update is silent — no highlight, badge or indicator.

  ## Cell/header interactions (task 66, `DR-56`, `DR-57`)

  `"toggle_override"` (a cell's override toggle button) calls
  `WeddingPlanner.Offers.toggle_override/3` with the **row's own service** and the
  **column's own offer** — the two values a cell's button carries via `phx-value-*`,
  never re-derived some other way. `"set_offer_status"` (one `<form>` per column header,
  `phx-change` on the form itself) calls `WeddingPlanner.Offers.update_offer/3` with just
  `status`; the select never offers *confirmed* (`DR-40`) — an offer already at
  *confirmed* shows the read-only pill instead of any select. `"toggle_ad_hoc"` (the
  "Other charges" row's own checkbox-style `phx-click`, never a form/`phx-change`) calls
  `WeddingPlanner.Offers.set_line_enabled/3`. All three simply `refresh_matrix/1` on
  success — the same idempotent full recompute every other mutation here already uses,
  which is also what makes it safe that the matching `:override`/`:offer`/`:offer_line`
  broadcasts arrive right behind the local update.

  Each cell's edit affordance is a plain `<.link navigate={...}>` deep link into
  `WeddingPlannerWeb.Live.OfferLive`'s own line editor (`/offers/:id?line=<line_id>` per
  line, or `/offers/:id?add_line=<service_id>` for an empty cell) — **no in-matrix field
  editing** (DR-57 answers `w10-plan.md` §10's question Q2 no).

  ## Offer forms (tasks 51/52, `CST-11`, `DR-41`) — the matrix replaces their old list

  Below the matrix, above the category history: the add-offer form (vendor name, VAT
  basis, status) and the quick-offer form (`CST-11` — a single price, one mandatory flat
  "Price" line via `WeddingPlanner.Offers.create_simple_offer/3`, no `phx-change`
  validation of its own since there is no matching `change_simple_offer/1` to drive one
  and speculatively calling `create_simple_offer/3` on every keystroke would create real
  offers). Both are siblings of every other form on this page, never nested. A failed
  quick-offer submit re-renders `@quick_offer_form` from the returned changeset (an
  **offer** changeset carrying the line's own `amount_input` error too, per that
  function's moduledoc); a successful one calls `refresh_matrix/1` so the new offer
  appears as a matrix column immediately.
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.ActivityComponents, only: [entity_history: 1]

  import WeddingPlannerWeb.Components.ComparisonComponents,
    only: [
      matrix_grid_style: 1,
      matrix_header_row: 1,
      matrix_cell: 1,
      matrix_other_charges_row: 1,
      matrix_totals_row: 1
    ]

  alias WeddingPlanner.Categories
  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Valuation.Comparison
  alias WeddingPlanner.Valuation.PresetChoice
  alias WeddingPlanner.Valuation.Snapshot
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
      Realtime.subscribe(:offer)
      Realtime.subscribe(:offer_line)
      Realtime.subscribe(:override)
      Realtime.subscribe(:event)
      Realtime.subscribe(:person)
      Realtime.subscribe(:group)
      Realtime.subscribe(:invitation)
      Realtime.subscribe(:plus_one_opt_out)
      Realtime.subscribe(:headcount_preset)
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
      |> assign(:add_offer_form, fresh_add_offer_form(category))
      |> assign(:quick_offer_form, fresh_quick_offer_form())
      |> assign(:category_activity_entries, Query.for_entity(:category, category.id))
      |> assign(:selected_preset_id, nil)
      |> assign(:show_rejected?, false)
      |> refresh_matrix()

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
          |> refresh_matrix()

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :add_service_form, to_form(changeset))}
    end
  end

  def handle_event("rename_service", %{"id" => id, "service" => params}, socket) do
    service = Categories.get_service!(id)

    case Categories.update_service(socket.assigns.current_scope, service, params) do
      {:ok, _updated} ->
        {:noreply, refresh_matrix(socket)}

      {:error, changeset} ->
        {:noreply, refresh_matrix(socket, %{service.id => to_form(changeset)})}
    end
  end

  def handle_event("change_priority", %{"id" => id, "wanted_priority" => value}, socket) do
    service = Categories.get_service!(id)

    {:ok, _updated} =
      Categories.update_service(socket.assigns.current_scope, service, %{
        "wanted_priority" => value
      })

    {:noreply, refresh_matrix(socket)}
  end

  # -- offer forms (tasks 51/52, CST-11, DR-43) ------------------------------------------

  def handle_event("validate_offer", %{"offer" => params}, socket) do
    category = socket.assigns.category

    form =
      %Offer{category_id: category.id}
      |> Offers.change_offer(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :add_offer_form, form)}
  end

  def handle_event("create_offer", %{"offer" => params}, socket) do
    category = socket.assigns.category

    case Offers.create_offer(socket.assigns.current_scope, category, params) do
      {:ok, offer} ->
        {:noreply, push_navigate(socket, to: ~p"/offers/#{offer.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :add_offer_form, to_form(changeset))}
    end
  end

  # -- quick offer (task 52, CST-11, DR-41) -----------------------------------------------

  def handle_event("create_quick_offer", %{"quick_offer" => params}, socket) do
    category = socket.assigns.category

    case Offers.create_simple_offer(socket.assigns.current_scope, category, params) do
      {:ok, offer} ->
        [line] = Offers.list_lines(offer)

        socket =
          socket
          |> assign(:quick_offer_form, fresh_quick_offer_form())
          |> refresh_matrix()
          |> put_flash(:info, "Added #{offer.vendor_name} (#{Format.money(line.amount)})")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :quick_offer_form, to_form(changeset, as: :quick_offer))}
    end
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
          |> refresh_matrix()

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
      |> refresh_matrix()

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
        {:ok, _survivor} -> refresh_matrix(socket)
        {:error, :different_categories} -> refresh_matrix(socket)
      end

    socket =
      socket
      |> assign(:confirming_merge_id, nil)
      |> assign(:merge_survivor_id, nil)

    {:noreply, socket}
  end

  # -- matrix totals row / rejected toggle (task 65, CST-53, CST-55, DR-54) --------------

  def handle_event("select_preset", %{"matrix-preset-preset" => id}, socket) do
    {:noreply, socket |> assign(:selected_preset_id, id) |> refresh_matrix()}
  end

  def handle_event("toggle_show_rejected", _params, socket) do
    {:noreply, socket |> update(:show_rejected?, &(not &1)) |> refresh_matrix()}
  end

  # -- matrix cell/header interactions (task 66, DR-56, DR-57) ---------------------------

  def handle_event(
        "toggle_override",
        %{"service-id" => service_id, "offer-id" => offer_id},
        socket
      ) do
    scope = socket.assigns.current_scope
    offer = Offers.get_offer!(offer_id)
    service = Categories.get_service!(service_id)

    case Offers.toggle_override(scope, offer, service) do
      {:ok, _result} -> {:noreply, refresh_matrix(socket)}
      {:error, :wrong_category} -> {:noreply, socket}
    end
  end

  def handle_event("set_offer_status", %{"offer-id" => offer_id, "status" => status}, socket) do
    scope = socket.assigns.current_scope
    offer = Offers.get_offer!(offer_id)

    case Offers.update_offer(scope, offer, %{"status" => status}) do
      {:ok, _updated} -> {:noreply, refresh_matrix(socket)}
      {:error, _changeset} -> {:noreply, socket}
    end
  end

  def handle_event("toggle_ad_hoc", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    line = Offers.get_line!(id)

    case Offers.set_line_enabled(scope, line, not line.enabled) do
      {:ok, _updated} -> {:noreply, refresh_matrix(socket)}
      {:error, :not_optional_ad_hoc} -> {:noreply, socket}
    end
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

  def handle_info({Realtime, :service, _event}, socket), do: {:noreply, refresh_matrix(socket)}
  def handle_info({Realtime, :offer, _event}, socket), do: {:noreply, refresh_matrix(socket)}
  def handle_info({Realtime, :offer_line, _event}, socket), do: {:noreply, refresh_matrix(socket)}
  def handle_info({Realtime, :override, _event}, socket), do: {:noreply, refresh_matrix(socket)}
  def handle_info({Realtime, :event, _event}, socket), do: {:noreply, refresh_matrix(socket)}
  def handle_info({Realtime, :person, _event}, socket), do: {:noreply, refresh_matrix(socket)}
  def handle_info({Realtime, :group, _event}, socket), do: {:noreply, refresh_matrix(socket)}
  def handle_info({Realtime, :invitation, _event}, socket), do: {:noreply, refresh_matrix(socket)}

  def handle_info({Realtime, :plus_one_opt_out, _event}, socket),
    do: {:noreply, refresh_matrix(socket)}

  def handle_info({Realtime, :headcount_preset, _event}, socket),
    do: {:noreply, refresh_matrix(socket)}

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

    {:noreply, refresh_matrix(socket)}
  end

  defp fresh_add_service_form(category) do
    to_form(Categories.change_service(%Service{category_id: category.id}))
  end

  defp fresh_add_offer_form(category) do
    to_form(Offers.change_offer(%Offer{category_id: category.id}))
  end

  defp fresh_quick_offer_form do
    to_form(%{"vat_basis" => "inclusive"}, as: :quick_offer)
  end

  defp offer_vat_basis_label(:inclusive), do: "Inclusive"
  defp offer_vat_basis_label(:exclusive), do: "Exclusive"

  defp offer_status_options do
    Enum.map(
      [:considering, :shortlisted, :rejected],
      &{offer_status_label(&1), Atom.to_string(&1)}
    )
  end

  defp offer_status_label(:considering), do: "Considering"
  defp offer_status_label(:shortlisted), do: "Shortlisted"
  defp offer_status_label(:rejected), do: "Rejected"

  defp offer_vat_basis_options do
    Enum.map([:inclusive, :exclusive], &{offer_vat_basis_label(&1), Atom.to_string(&1)})
  end

  # -- the matrix (task 65, DR-57) --------------------------------------------------------

  defp refresh_matrix(socket), do: refresh_matrix(socket, %{})

  defp refresh_matrix(socket, override_forms) do
    category = socket.assigns.category
    snapshot = Snapshot.load(Repo)
    presets = snapshot.headcount_presets
    selected_preset = PresetChoice.find(presets, socket.assigns.selected_preset_id)

    range_presets =
      case PresetChoice.range_presets(presets) do
        {:ok, tuple} -> tuple
        :missing -> nil
      end

    matrix = Comparison.build(snapshot, category.id, selected_preset, range_presets)
    cells = cells_by_service(matrix)

    services = Categories.list_services(category)
    decorated = decorate_service_rows(services, cells)

    rename_forms =
      Map.new(services, fn service ->
        form = Map.get(override_forms, service.id) || to_form(Categories.change_service(service))
        {service.id, form}
      end)

    service_histories = Map.new(services, &{&1.id, Query.for_entity(:service, &1.id)})

    visible_columns =
      if socket.assigns.show_rejected? do
        matrix.columns
      else
        Enum.reject(matrix.columns, & &1.rejected?)
      end

    socket
    |> assign(:all_services, services)
    |> assign(:rename_forms, rename_forms)
    |> assign(:service_histories, service_histories)
    |> assign(:matrix, matrix)
    |> assign(:presets, presets)
    |> assign(:selected_preset, selected_preset)
    |> assign(:range_missing?, is_nil(range_presets))
    |> assign(:visible_columns, visible_columns)
    |> assign(:rejected_count, Enum.count(matrix.columns, & &1.rejected?))
    |> stream(:services_must_have, band_rows(decorated, :must_have), reset: true)
    |> stream(:services_nice_to_have, band_rows(decorated, :nice_to_have), reset: true)
    |> stream(:services_not_wanted, band_rows(decorated, :not_wanted), reset: true)
  end

  defp cells_by_service(matrix) do
    matrix.bands
    |> Enum.flat_map(& &1.rows)
    |> Map.new(&{&1.service.id, &1.cells})
  end

  defp decorate_service_rows(services, cells_by_service) do
    last_index = length(services) - 1

    services
    |> Enum.with_index()
    |> Enum.map(fn {service, idx} ->
      %{
        id: service.id,
        service: service,
        first?: idx == 0,
        last?: idx == last_index,
        cells: Map.get(cells_by_service, service.id, %{})
      }
    end)
  end

  defp band_rows(decorated, priority) do
    Enum.filter(decorated, &(&1.service.wanted_priority == priority))
  end

  defp priority_stream_key(priority), do: Map.fetch!(@priority_streams, priority)

  defp stream_insert_service_row(socket, nil), do: socket

  defp stream_insert_service_row(socket, id) do
    service = Categories.get_service!(id)
    cells = cells_by_service(socket.assigns.matrix)
    decorated = decorate_service_rows(Categories.list_services(socket.assigns.category), cells)
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

      <div
        id="comparison-matrix"
        class="mt-6 overflow-x-auto rounded-field border border-line bg-surface-raised"
      >
        <div>
          <.matrix_header_row columns={@visible_columns} />

          <.service_band
            dom_id="band-must-have"
            label="Must-have"
            stream={@streams.services_must_have}
            columns={@visible_columns}
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
            columns={@visible_columns}
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
            columns={@visible_columns}
            all_services={@all_services}
            rename_forms={@rename_forms}
            service_histories={@service_histories}
            confirming_delete_service_id={@confirming_delete_service_id}
            confirming_delete_has_lines?={@confirming_delete_has_lines?}
            confirming_merge_id={@confirming_merge_id}
            merge_survivor_id={@merge_survivor_id}
            time_zone={@time_zone}
          />

          <.matrix_other_charges_row columns={@visible_columns} other_charges={@matrix.other_charges} />

          <.matrix_totals_row
            columns={@visible_columns}
            presets={@presets}
            selected_preset={@selected_preset}
            range_missing?={@range_missing?}
          />
        </div>

        <div :if={@rejected_count > 0} class="border-t border-line p-3">
          <button
            type="button"
            id="matrix-show-rejected"
            phx-click="toggle_show_rejected"
            class="text-sm font-medium text-accent hover:underline"
          >
            <%= if @show_rejected? do %>
              Hide rejected ({@rejected_count})
            <% else %>
              Show rejected ({@rejected_count})
            <% end %>
          </button>
        </div>
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

      <.offers_section add_offer_form={@add_offer_form} quick_offer_form={@quick_offer_form} />

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
  attr :columns, :list, required: true
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
      <h2 class="sticky left-0 z-10 mb-2 inline-block bg-surface-raised px-1 text-sm font-semibold uppercase tracking-wide text-ink-soft">
        {@label}
      </h2>
      <ul id={@dom_id} phx-update="stream">
        <li
          id={"#{@dom_id}-empty"}
          class="hidden border-b border-dashed border-line-strong p-4 text-center text-sm text-ink-faint only:block"
        >
          No services
        </li>
        <li
          :for={{dom_id, row} <- @stream}
          id={dom_id}
          class="grid border-b border-line"
          style={matrix_grid_style(@columns)}
        >
          <.service_row
            row={row}
            columns={@columns}
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
  attr :columns, :list, required: true
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
    <div class="sticky left-0 z-10 overflow-hidden bg-surface-raised px-3 py-2">
      <.form
        for={@form}
        id={"service-#{@row.service.id}-rename-form"}
        phx-change="rename_service"
        phx-submit="rename_service"
        phx-value-id={@row.service.id}
      >
        <label for={"service-#{@row.service.id}-name-input"} class="sr-only">Name</label>
        <.input
          field={@form[:name]}
          type="text"
          id={"service-#{@row.service.id}-name-input"}
          phx-debounce="blur"
          aria-label="Name"
          title={@row.service.name}
          class="block w-full truncate rounded-sm border-0 bg-transparent p-0 text-sm font-medium text-ink focus:outline-none focus:ring-2 focus:ring-accent focus:ring-offset-1 focus:ring-offset-surface-raised"
        />
      </.form>

      <.form
        for={to_form(%{}, as: :priority)}
        id={"service-#{@row.service.id}-priority-form"}
        phx-change="change_priority"
        phx-value-id={@row.service.id}
        class="mt-0.5"
      >
        <label for={"service-#{@row.service.id}-priority"} class="sr-only">Priority</label>
        <.input
          type="select"
          id={"service-#{@row.service.id}-priority"}
          name="wanted_priority"
          value={Atom.to_string(@row.service.wanted_priority)}
          options={priority_options()}
          aria-label="Priority"
          class="block w-full max-w-full truncate border-0 border-b border-dashed border-line-strong bg-transparent p-0 pb-0.5 text-xs text-ink-soft focus:border-accent focus:outline-none focus:ring-0"
        />
      </.form>

      <details class="mt-1 text-xs">
        <summary class="cursor-pointer list-none text-ink-faint select-none hover:text-ink-soft">
          ⋯ Manage
        </summary>
        <div class="mt-2 space-y-2">
          <div class="flex flex-wrap items-center gap-1.5">
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

          <details id={"service-#{@row.service.id}-history-disclosure"}>
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
      </details>

      <%!-- Confirm panels are siblings of (never nested inside) the "Manage" disclosure
      above, so they stay visible whether or not the disclosure happens to be open when
      they're triggered — DR-57's Manage disclosure only collapses the trigger controls,
      never their own confirmation state. --%>
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
        class="mt-2 rounded-field border border-line-strong bg-surface p-4"
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
    </div>

    <.matrix_cell
      :for={column <- @columns}
      service_id={@row.service.id}
      offer_id={column.offer.id}
      cell={Map.fetch!(@row.cells, column.offer.id)}
      vat_basis={column.offer.vat_basis}
      rejected?={column.rejected?}
    />
    """
  end

  # -- offer forms (tasks 51/52, DR-43, DR-57) — the matrix replaces their old plain list,
  # so this component now only holds the "Add offer" and "Quick offer" forms. -----------

  attr :add_offer_form, :any, required: true
  attr :quick_offer_form, :any, required: true

  defp offers_section(assigns) do
    ~H"""
    <div class="mt-8">
      <.header>Add an offer</.header>

      <div class="mt-2 flex flex-wrap gap-4">
        <div class="rounded-field border border-line bg-surface-raised p-4">
          <h2 class="mb-3 text-sm font-semibold text-ink">Add offer</h2>
          <.form
            for={@add_offer_form}
            id="add-offer-form"
            phx-change="validate_offer"
            phx-submit="create_offer"
            class="flex flex-wrap items-end gap-3"
          >
            <.input
              field={@add_offer_form[:vendor_name]}
              type="text"
              label="Vendor name"
              id="add-offer-vendor"
            />
            <.input
              field={@add_offer_form[:vat_basis]}
              type="select"
              label="VAT basis"
              id="add-offer-vat-basis"
              options={offer_vat_basis_options()}
            />
            <.input
              field={@add_offer_form[:status]}
              type="select"
              label="Status"
              id="add-offer-status"
              options={offer_status_options()}
            />
            <.button variant="primary" id="add-offer-submit">Add offer</.button>
          </.form>
        </div>

        <div class="rounded-field border border-line bg-surface-raised p-4">
          <h2 class="mb-3 text-sm font-semibold text-ink">Quick offer — one price</h2>
          <.form
            for={@quick_offer_form}
            id="quick-offer-form"
            phx-submit="create_quick_offer"
            class="flex flex-wrap items-end gap-3"
          >
            <.input
              field={@quick_offer_form[:vendor_name]}
              type="text"
              label="Vendor name"
              id="quick-offer-vendor"
            />
            <.input
              field={@quick_offer_form[:amount_input]}
              type="text"
              label="Price"
              id="quick-offer-amount"
              placeholder="e.g. 1.800"
            />
            <.input
              field={@quick_offer_form[:vat_basis]}
              type="select"
              label="VAT basis"
              id="quick-offer-vat-basis"
              options={offer_vat_basis_options()}
            />
            <.input
              field={@quick_offer_form[:vat_rate_input]}
              type="text"
              label="VAT rate (if exclusive, %)"
              id="quick-offer-vat-rate"
              placeholder="21"
            />
            <.button variant="primary" id="quick-offer-submit">Add quick offer</.button>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
