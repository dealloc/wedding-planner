defmodule WeddingPlannerWeb.Live.OfferLive do
  @moduledoc """
  An offer's own page (task 51; `/offers/:id`, `DR-40`): its header fields
  (`docs/modules/offers-and-comparison.md` `CST-10`, `CST-33`, `CST-36`), the
  `WeddingPlannerWeb.ReferencesComponent` panel mounted here for the first time
  (`DR-28`, `DR-31`), its own activity history (`XC-11`) and delete (`XC-24`, `XC-40`).

  Default (narrow) `Layouts.app` width — this page is a single stacked form plus the
  references panel, no wide-table need (unlike `CategoryLive`, which is deliberately
  built wide for the future comparison matrix).

  ## Offer lines (task 52, `CST-02`, `CST-20`–`CST-33`, `DR-41`, `XC-41`/`XC-42`)

  A `:lines` stream (`offer-line-<id>` rows, service order then ad hoc —
  `WeddingPlanner.Offers.list_lines/1`) between the header form and the references
  panel. **One editor open at a time** (`@editing_line_id`: `nil` | a line id | `:new`,
  the same discipline `TaskComponents.task_editor/1`/`TasksLive` used for task 31): the
  add-line form and a row's own edit form share one private `line_editor/1` component
  (fixed field ids per prefix, `add-line-*`/`edit-line-*`, since only one is ever
  mounted), and only the row whose id matches `@editing_line_id` — or the add slot, for
  `:new` — renders it. Opening or closing an editor re-inserts the affected stream
  row(s) (`stream_insert/3`) rather than resetting the whole stream, the same
  `CategoryLive` "stream items only re-render when re-inserted" discipline; any mutation
  or an `:offer_line`/`:service`/`:event` broadcast instead calls `refresh_lines/1`,
  which refetches and resets the whole stream (small per-offer data, same reasoning as
  `CategoryLive`'s band refresh).

  The service picker (`CST-02`) is a virtual `line[service_choice]` select — `""` ad
  hoc, a service id, or `"new"` — read and translated by this module before the params
  ever reach `WeddingPlanner.Offers.change_line/2`/`create_line/3`/`update_line/3`,
  exactly the `task[owner]`-style translation `TaskComponents` documents.
  `"new"` additionally types a name into `line[new_service_name]`; on save this module
  calls `WeddingPlanner.Categories.create_service/3` itself, first — if that succeeds but
  the line then fails validation, the service is left in place (harmless, visible in the
  category) rather than rolled back, since `Offers.create_line/3` runs no transaction of
  its own spanning the two writes.

  Field visibility (state always; basis/amount only for priced states; event/included
  quantity only for per-person bases; minimum charge for any priced line; VAT rate
  override only on a VAT-exclusive offer) is read live off the *form's* current
  (possibly unsaved) `state`/`basis` values on every `phx-change` — `phx-change` lives on
  the `<form>` itself, never a bare `<select>` (the design record's matrix-v3 bug).
  `WeddingPlanner.Offers.OfferLine.invalid?/1` (a per-person line whose event was
  deleted, `XC-41`) drives the struck-through row, the `DisplayComponents.gap_severity/1`
  `:invalid` badge labelled "Event deleted", and the edit form's event select prompt
  ("Pick an event or switch to flat") — nothing repairs it automatically (`XC-42`).

  ## Header form (`CST-10`, `CST-33`, `CST-36`)

  One `<.form>`, the `PersonLive` validate/save pattern (validate on change, persist on
  submit, stay on the page with a flash — never per-keystroke persistence). Per-field
  log entries come from `WeddingPlanner.Offers.update_offer/3` itself.

  `vat_rate_input` is only rendered while the form's *currently selected* (possibly
  unsaved) `vat_basis` is `:exclusive` — read off `@form[:vat_basis].value`, which is
  whichever the validate params carried, not the last-saved `@offer.vat_basis` — so the
  field appears/disappears immediately as the select changes, no round trip needed for
  that alone. `handle_event("validate", ...)` prefills `"21"` into `vat_rate_input`
  exactly once, on the transition *into* exclusive (never overwriting whatever the user
  already typed) — the "considering" of that switch is done here, not in the schema
  changeset, since it is a form-population concern, not a validation rule. Switching
  back to inclusive needs no equivalent handling on this page: hiding the input simply
  stops it from being submitted, and `Offer.changeset/2`'s `put_vat_rate/1` already
  clears the stored `vat_rate_bp` whenever the saved `vat_basis` ends up inclusive.

  `minimum_spend_input` follows `CategoriesLive`'s own `target_input` pattern exactly
  (see that module's moduledoc) — prefilled from the stored `Money` as a plain nl-BE
  number with no currency symbol, parsed back via `WeddingPlanner.Money.parse/1`
  (`DR-23`) inside the schema changeset.

  `status` only ever offers *considering*/*shortlisted*/*rejected* here (`DR-40`) — this
  slice never writes *confirmed* (`Offer.changeset/2` refuses that transition outright).
  In the one case that can still happen — an offer already sitting at *confirmed* from
  a future slice — the select is replaced by a read-only `status_pill/1` instead of
  being rendered at all, so no select is ever shown holding options that omit the
  option currently selected in the data.

  ## References (`DR-28`, `DR-31`)

  The host contract `ReferencesComponent`'s moduledoc documents: this LiveView loads
  `WeddingPlanner.References.list_references/1` for `WeddingPlanner.Offers.reference_owner/1`,
  subscribes to `WeddingPlanner.Realtime.topic(:reference)`, and refetches the whole
  list on every broadcast — the component itself never fetches. This is `DR-28`'s
  deferred real-browser check, closed by this task's CDP run (uploads, inline
  open/download, a URL reference opening in a new tab).

  ## Delete (`XC-24`, `XC-40`)

  `CoreComponents.destructive_confirm/1` with `affected =
  WeddingPlanner.Offers.offer_deletion_effects(offer)` (references today; task 50 will
  extend the same function with lines). `Offers.delete_offer/2` purges reference files
  from storage as part of its own contract — nothing here does that directly.

  ## Live updates (`XC-01`, `XC-02`)

  Subscribes to `:offer`, `:reference`, `:category`, `:activity_entry`, `:offer_line`,
  `:service` (a rename/merge changes a service line's label) and `:event` (a rename
  changes a per-person line's displayed event name; a deletion is what makes a line
  invalid — see above). A `{:deleted, id}` for this
  offer, from another process, navigates the viewer to the category with a flash — the
  same "the thing you were looking at is gone" pattern `PersonLive` uses. `:category`
  is only subscribed to keep the breadcrumb's category name live (a category with any
  offer can never itself be deleted — `Categories.category_deletion_blockers/1` — so
  the only realistic event here is a rename). Per `DR-21`, every other broadcast simply
  updates assigns in place: no highlight, badge or "someone else changed this" notice.

  ## Matrix deep links (task 66, `DR-57`)

  `handle_params/3` opens the line editor from a query param the comparison matrix
  links to — never present at `mount/3` time in a way this module needs to special-case,
  since `handle_params/3` runs right after `mount/3` for the very first URL too and the
  streams/assigns it reads are already in place by then:

    * `?line=<id>` opens that line's editor (`@editing_line_id = id`) **only if the line
      belongs to this offer** — a foreign id (or one that fails to parse) is silently
      ignored, editor left closed, no crash.
    * `?add_line=<service_id>` opens the add slot (`:new`) with that service preselected
      (`@line_service_choice`) **only if the service belongs to this offer's category**
      — same silent-ignore, same reasoning (a matrix cell only ever names a service that
      actually belongs to the category, but the URL itself is not trusted).

  Neither param is looked at more than once: closing the editor (`close_line_editor/1`,
  on cancel or a successful save) always `push_patch/2`s back to the bare `/offers/:id`,
  so a reload of a "mid-edit" URL never reopens it, and the query string is not part of
  this module's own persisted state (`XC-02`) — it only ever seeds the transient
  `@editing_line_id`. The service `<select>` is `phx-mounted={JS.focus()}` so opening an
  editor (from the matrix or from this page's own "Edit"/"+ Add line" buttons alike)
  scrolls it into view via the browser's native focus-follows-scroll behaviour — no
  custom JS hook.

  ## Cost card (task 57/60, `DR-51`, `DR-54`)

  Between the header form (`#offer-form`) and the lines section (`#offer-lines-section`):
  `WeddingPlannerWeb.Components.OfferCostComponents.cost_card/1`, fed by
  `WeddingPlannerWeb.OfferCost.build/3` over a freshly loaded
  `WeddingPlanner.Valuation.Snapshot`. `@cost_preset` (default `nil`) holds the
  **requested** preset id, a plain transient socket assign — never persisted, never
  broadcast (`HC-10`, `D-31`); it survives a live recompute but resets to `nil` on
  `mount/3` (i.e. on reload), which `WeddingPlanner.Valuation.PresetChoice.find/2`
  (inside `OfferCost.build/3`) turns into the default (likely-role) preset — same
  fallback path a stale id (a deleted selection) takes. The card is handed the
  **resolved** id (`@cost.selected.id`), not the raw `@cost_preset`, so its chips always
  reflect what is actually shown, default-fallback included.
  `handle_event("select_cost_preset", …)` changes only `@cost_preset` and recomputes;
  `refresh_cost/1` is also called from `mount/3` and from every `handle_info/2` clause
  whose broadcast can move the total, the range or the gaps — on top of the existing
  `:offer`, `:offer_line`, `:service`, `:event` subscriptions above, this task adds
  `:person`, `:group`, `:invitation`, `:plus_one_opt_out` (headcounts and gaps both
  ultimately read the guest list, `NFR-33`) and `:headcount_preset` (a rename, role
  move, create or delete changes which presets exist, their names, or which is the
  default/range ends). Card composition and money formatting stay entirely inside
  `OfferCost`/`OfferCostComponents`; this module only wires assigns and broadcasts.

  ## Invoices, variance, invoicing complete (task 70, `BIL-05`, `BIL-07`, `DR-58`)

  Shown **only while the offer is confirmed** (`DR-58` — before C5, W11, that never
  happens through the UI; tests and the dev-DB real-browser check set it directly). The
  whole `#offer-invoices` section renders nothing at all otherwise, not even an empty
  state.

  `refresh_invoices/1` reloads a fresh `WeddingPlanner.Valuation.Snapshot` and
  recomputes the offer's linked invoices (`WeddingPlanner.Invoices.list_invoices_by_offer/1`,
  each row via the shared `WeddingPlannerWeb.Components.InvoiceComponents.invoice_row/1`),
  its `BUD-02` figures (`Valuation.Invoices.offer_figures/2`) and its variance
  (`Valuation.Invoices.variance/3`) — called from every place `refresh_cost/1` already
  is (mount and every broadcast that can move a headcount, a gap or the offer's own
  lines/status), plus `:invoice`/`:invoice_line`, newly subscribed here. The variance is
  computed under `@cost_preset` — the offer page's **own** Cost card selection
  (`WeddingPlanner.Valuation.PresetChoice.find/2`, the same resolution
  `WeddingPlannerWeb.OfferCost.build/3` makes) — never a second selector (`BIL-07`
  "under a chosen preset"): switching the Cost card's chip changes both at once. It is
  `nil` (hidden) whenever the offer has no linked invoices yet, even though
  `Valuation.Invoices.variance/3` itself would still return a figure for a confirmed
  offer with none — `BIL-07` "for an offer with invoices" is this module's own gate.

  `"toggle_invoicing_complete"` is one click, `WeddingPlanner.Invoices.set_invoicing_complete/3`
  with the flag's opposite — the button IS the pill (`good`-toned classes when set, the
  same tokens `WeddingPlannerWeb.DisplayComponents.status_pill/1`'s `:good` tone uses),
  never a `<.button type="button">` (drops `type`, `AGENTS.md`).

  ## Delete blocker (`DR-58`)

  `"confirm_delete"` checks `WeddingPlanner.Offers.offer_deletion_blockers/1` **before**
  opening any confirmation (`@confirming_delete_blocked?`) — the same
  check-before-attempting discipline `WeddingPlannerWeb.Live.CategoryLive` uses for a
  service with lines: non-empty shows `#offer-delete-blocked` (the blockers named, no
  delete button) instead of `CoreComponents.destructive_confirm/1`.
  `Offers.delete_offer/2`'s own `{:error, :has_invoices}` is kept as a defensive
  fallback in case of a race between the check and the click.
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.ActivityComponents, only: [entity_history: 1]

  alias WeddingPlanner.Categories
  alias WeddingPlanner.Events
  alias WeddingPlanner.Events.Event
  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Offers.VatRate
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.References
  alias WeddingPlanner.Tasks.TodoList
  alias WeddingPlanner.Valuation.Invoices, as: InvoiceValuation
  alias WeddingPlanner.Valuation.PresetChoice
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Format
  alias WeddingPlannerWeb.OfferCost

  import WeddingPlannerWeb.Components.OfferCostComponents, only: [cost_card: 1]
  import WeddingPlannerWeb.Components.InvoiceComponents, only: [invoice_row: 1, variance_panel: 1]

  on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

  @statuses [:considering, :shortlisted, :rejected]
  @vat_bases [:inclusive, :exclusive]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    offer = Offers.get_offer!(id)

    if connected?(socket) do
      Realtime.subscribe(:offer)
      Realtime.subscribe(:reference)
      Realtime.subscribe(:category)
      Realtime.subscribe(:activity_entry)
      Realtime.subscribe(:offer_line)
      Realtime.subscribe(:service)
      Realtime.subscribe(:event)
      Realtime.subscribe(:person)
      Realtime.subscribe(:group)
      Realtime.subscribe(:invitation)
      Realtime.subscribe(:plus_one_opt_out)
      Realtime.subscribe(:headcount_preset)
      Realtime.subscribe(:invoice)
      Realtime.subscribe(:invoice_line)
    end

    socket =
      socket
      |> assign(:page_title, offer.vendor_name)
      |> assign(:category, offer.category)
      |> assign(:confirming_delete, false)
      |> assign(:confirming_delete_blocked?, false)
      |> assign(:activity_entries, Query.for_entity(:offer, offer.id))
      |> assign(:services, Categories.list_services(offer.category))
      |> assign(:events, Events.list_events())
      |> assign(:editing_line_id, nil)
      |> assign(:confirming_delete_line_id, nil)
      |> assign(:line_form, nil)
      |> assign(:line_service_choice, "")
      |> assign(:line_new_service_name, "")
      |> assign(:line_new_service_error, nil)
      |> assign(:cost_preset, nil)
      |> refresh_view(offer)
      |> refresh_lines()
      |> refresh_cost()
      |> refresh_invoices()

    {:ok, socket}
  end

  # -- matrix deep links (task 66, DR-57) ------------------------------------------------

  @impl true
  def handle_params(%{"line" => line_id} = _params, _uri, socket) do
    {:noreply, open_deep_linked_line(socket, line_id)}
  end

  def handle_params(%{"add_line" => service_id} = _params, _uri, socket) do
    {:noreply, open_deep_linked_add_line(socket, service_id)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # -- header form (CST-10, CST-33, CST-36) ----------------------------------------------

  @impl true
  def handle_event("validate", %{"offer" => params}, socket) do
    previously_exclusive? = form_exclusive?(socket.assigns.form)
    params = maybe_prefill_vat_rate(params, previously_exclusive?)

    form =
      socket.assigns.offer
      |> Offers.change_offer(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"offer" => params}, socket) do
    scope = socket.assigns.current_scope

    case Offers.update_offer(scope, socket.assigns.offer, params) do
      {:ok, offer} ->
        socket =
          socket
          |> refresh_view(offer)
          |> put_flash(:info, "Offer updated.")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  # -- delete (XC-24, XC-40) --------------------------------------------------------------

  def handle_event("confirm_delete", _params, socket) do
    blocked? = Offers.offer_deletion_blockers(socket.assigns.offer) != []

    socket =
      socket
      |> assign(:confirming_delete, true)
      |> assign(:confirming_delete_blocked?, blocked?)

    {:noreply, socket}
  end

  def handle_event("cancel_delete", _params, socket) do
    socket =
      socket
      |> assign(:confirming_delete, false)
      |> assign(:confirming_delete_blocked?, false)

    {:noreply, socket}
  end

  def handle_event("delete_confirmed", _params, socket) do
    scope = socket.assigns.current_scope
    category = socket.assigns.category

    case Offers.delete_offer(scope, socket.assigns.offer) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Offer deleted.")
         |> push_navigate(to: ~p"/categories/#{category.id}")}

      {:error, :has_invoices} ->
        {:noreply, assign(socket, :confirming_delete_blocked?, true)}
    end
  end

  # -- offer lines (task 52, CST-02, CST-20..33, DR-41) ------------------------------------

  def handle_event("add_line", _params, socket) do
    {:noreply, open_line_editor(socket, :new)}
  end

  def handle_event("edit_line", %{"id" => id}, socket) do
    {:noreply, open_line_editor(socket, String.to_integer(id))}
  end

  def handle_event("cancel_line", _params, socket) do
    {:noreply, close_line_editor(socket)}
  end

  def handle_event("validate_line", %{"line" => params}, socket) do
    {choice, new_name, attrs} = split_line_params(params)
    attrs = put_existing_service_id(attrs, choice)

    changeset =
      socket
      |> editing_base_line()
      |> Offers.change_line(attrs)
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:line_form, to_form(changeset, as: :line))
      |> assign(:line_service_choice, choice)
      |> assign(:line_new_service_name, new_name)
      |> assign(:line_new_service_error, nil)

    {:noreply, socket}
  end

  def handle_event("save_line", %{"line" => params}, socket) do
    scope = socket.assigns.current_scope
    category = socket.assigns.category
    {choice, new_name, attrs} = split_line_params(params)

    case resolve_service_id(scope, category, choice, new_name, attrs) do
      {:ok, resolved_attrs} ->
        persist_line(socket, scope, editing_base_line(socket), resolved_attrs)

      {:error, :blank_name} ->
        {:noreply, assign(socket, :line_new_service_error, "Enter a name for the new service.")}

      {:error, %Ecto.Changeset{} = service_changeset} ->
        {:noreply, assign(socket, :line_new_service_error, changeset_message(service_changeset))}
    end
  end

  def handle_event("confirm_delete_line", %{"id" => id}, socket) do
    id = String.to_integer(id)
    socket = socket |> assign(:confirming_delete_line_id, id) |> reinsert_line_row(id)
    {:noreply, socket}
  end

  def handle_event("cancel_delete_line", _params, socket) do
    id = socket.assigns.confirming_delete_line_id
    socket = socket |> assign(:confirming_delete_line_id, nil) |> reinsert_line_row(id)
    {:noreply, socket}
  end

  def handle_event("delete_line", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    line = Offers.get_line!(id)
    {:ok, _} = Offers.delete_line(scope, line)

    socket =
      socket
      |> assign(:confirming_delete_line_id, nil)
      |> refresh_lines()

    {:noreply, socket}
  end

  def handle_event("toggle_line", %{"id" => id} = params, socket) do
    scope = socket.assigns.current_scope
    line = Offers.get_line!(id)
    enabled? = Map.get(params, "enabled") in ["true", "on"]

    case Offers.set_line_enabled(scope, line, enabled?) do
      {:ok, _updated} -> {:noreply, refresh_lines(socket)}
      {:error, :not_optional_ad_hoc} -> {:noreply, socket}
    end
  end

  # -- cost card (task 57, DR-51, HC-10, D-31) ---------------------------------------------

  def handle_event("select_cost_preset", %{"offer-cost-preset-preset" => preset}, socket) do
    {:noreply, socket |> assign(:cost_preset, preset) |> refresh_cost() |> refresh_invoices()}
  end

  # -- invoicing complete (task 70, BIL-05, DR-58) ---------------------------------------

  def handle_event("toggle_invoicing_complete", _params, socket) do
    scope = socket.assigns.current_scope
    offer = socket.assigns.offer

    case Invoices.set_invoicing_complete(scope, offer, not offer.invoicing_complete) do
      {:ok, updated} -> {:noreply, socket |> refresh_view(updated) |> refresh_invoices()}
      {:error, :not_confirmed} -> {:noreply, socket}
    end
  end

  # -- live updates (XC-01, XC-02) --------------------------------------------------------

  @impl true
  def handle_info({Realtime, :offer, {:deleted, id}}, socket) do
    if id == socket.assigns.offer.id do
      category = socket.assigns.category

      {:noreply,
       socket
       |> put_flash(:error, "This offer was deleted.")
       |> push_navigate(to: ~p"/categories/#{category.id}")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({Realtime, :offer, {event, offer}}, socket)
      when event in [:created, :updated] do
    if offer.id == socket.assigns.offer.id do
      {:noreply, socket |> refresh_view(offer) |> refresh_cost() |> refresh_invoices()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({Realtime, :reference, _event}, socket) do
    owner = Offers.reference_owner(socket.assigns.offer)
    {:noreply, assign(socket, :references, References.list_references(owner))}
  end

  def handle_info({Realtime, :category, {:updated, updated}}, socket) do
    if updated.id == socket.assigns.category.id do
      {:noreply, assign(socket, :category, updated)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({Realtime, :category, _event}, socket), do: {:noreply, socket}

  def handle_info({Realtime, :activity_entry, {:created, entry}}, socket) do
    %{offer: offer} = socket.assigns

    if entry.entity_type == "offer" and entry.entity_id == offer.id do
      entry = Query.preload_user(entry)
      {:noreply, update(socket, :activity_entries, &[entry | &1])}
    else
      {:noreply, socket}
    end
  end

  def handle_info({Realtime, :offer_line, _event}, socket),
    do: {:noreply, socket |> refresh_lines() |> refresh_cost() |> refresh_invoices()}

  def handle_info({Realtime, :service, _event}, socket) do
    socket = assign(socket, :services, Categories.list_services(socket.assigns.category))
    {:noreply, socket |> refresh_lines() |> refresh_cost() |> refresh_invoices()}
  end

  def handle_info({Realtime, :event, _event}, socket) do
    socket = assign(socket, :events, Events.list_events())
    {:noreply, socket |> refresh_lines() |> refresh_cost() |> refresh_invoices()}
  end

  # -- cost card live updates (task 57, DR-51, NFR-33): recompute only, no other assign
  # changes — headcounts and gaps both ultimately read the guest list. The variance
  # (task 70) rides along for the same reason: it depends on the same committed total.
  def handle_info({Realtime, :person, _event}, socket),
    do: {:noreply, socket |> refresh_cost() |> refresh_invoices()}

  def handle_info({Realtime, :group, _event}, socket),
    do: {:noreply, socket |> refresh_cost() |> refresh_invoices()}

  def handle_info({Realtime, :invitation, _event}, socket),
    do: {:noreply, socket |> refresh_cost() |> refresh_invoices()}

  def handle_info({Realtime, :plus_one_opt_out, _event}, socket),
    do: {:noreply, socket |> refresh_cost() |> refresh_invoices()}

  # A rename, role move, create or delete (DR-54): the card's chips, default and range
  # all derive from the current stored presets, so a plain recompute picks it all up —
  # PresetChoice.find/2 falls back to the default on its own if the selected id
  # disappeared. The variance (task 70) follows the same resolution.
  def handle_info({Realtime, :headcount_preset, _event}, socket),
    do: {:noreply, socket |> refresh_cost() |> refresh_invoices()}

  # -- invoices live updates (task 70, BIL-04, XC-01) ------------------------------------
  def handle_info({Realtime, :invoice, _event}, socket), do: {:noreply, refresh_invoices(socket)}

  def handle_info({Realtime, :invoice_line, _event}, socket),
    do: {:noreply, refresh_invoices(socket)}

  # -- helpers -----------------------------------------------------------------------

  # Cost card (task 57, DR-51, NFR-33): a fresh snapshot, `@cost_preset` (never hard-coded
  # to Likely — that would silently break the preset switch), reads via `Snapshot.load/1`
  # only, never a partial/incremental update.
  defp refresh_cost(socket) do
    %{offer: offer, cost_preset: preset} = socket.assigns
    snapshot = Snapshot.load(WeddingPlanner.Repo)
    assign(socket, :cost, OfferCost.build(snapshot, offer.id, preset))
  end

  # Invoices, figures and variance (task 70, BIL-05, BIL-07, DR-58): a fresh snapshot,
  # never a partial update, same reasoning as `refresh_cost/1`. The variance is computed
  # under the same `@cost_preset` resolution `OfferCost.build/3` makes internally
  # (`PresetChoice.find/2` — HC-10, DR-54) so the two never disagree; it is hidden (nil)
  # whenever there is no linked invoice yet, even though the engine itself would still
  # return a figure for a confirmed offer with none (BIL-07 "for an offer with
  # invoices" is this module's own gate — see the moduledoc).
  defp refresh_invoices(socket) do
    %{offer: offer, cost_preset: cost_preset} = socket.assigns
    snapshot = Snapshot.load(WeddingPlanner.Repo)
    today = TodoList.today(socket.assigns.time_zone)
    invoices = Invoices.list_invoices_by_offer(offer)
    preset = PresetChoice.find(snapshot.headcount_presets, cost_preset)

    socket
    |> assign(:invoice_snapshot, snapshot)
    |> assign(:invoice_today, today)
    |> assign(:invoice_figures, InvoiceValuation.offer_figures(snapshot, offer))
    |> assign(:invoice_preset_name, preset && preset.name)
    |> assign(:variance, offer_variance(snapshot, offer, invoices, preset))
    |> stream(:offer_invoices, invoices, reset: true, dom_id: &"offer-invoices-row-#{&1.id}")
  end

  defp offer_variance(_snapshot, _offer, [], _preset), do: nil
  defp offer_variance(_snapshot, _offer, _invoices, nil), do: nil

  defp offer_variance(snapshot, offer, _invoices, preset) do
    case InvoiceValuation.variance(snapshot, offer, preset) do
      %{} = variance -> variance
      :not_confirmed -> nil
    end
  end

  defp invoicing_complete_class(true) do
    "inline-flex items-center gap-1.5 rounded-chip bg-good-soft px-3 py-1.5 text-xs font-medium " <>
      "text-good cursor-pointer transition hover:opacity-90 focus-visible:outline-none " <>
      "focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
  end

  defp invoicing_complete_class(false) do
    "inline-flex min-h-11 items-center justify-center gap-2 rounded-field px-4 text-sm font-semibold " <>
      "cursor-pointer transition-all duration-150 ease-out active:scale-[0.98] " <>
      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-paper " <>
      "bg-transparent text-ink border border-line-strong hover:bg-surface active:bg-line"
  end

  defp refresh_view(socket, %Offer{} = offer) do
    offer = %{offer | category: socket.assigns.category}

    socket
    |> assign(:offer, offer)
    |> assign(:page_title, offer.vendor_name)
    |> assign(:form, to_form(fresh_changeset(offer)))
    |> assign(:references, References.list_references(Offers.reference_owner(offer)))
  end

  defp fresh_changeset(%Offer{} = offer) do
    offer
    |> Offers.change_offer(%{})
    |> Ecto.Changeset.put_change(:vat_rate_input, vat_rate_input_value(offer.vat_rate_bp))
    |> Ecto.Changeset.put_change(
      :minimum_spend_input,
      minimum_spend_input_value(offer.minimum_spend)
    )
  end

  defp vat_rate_input_value(nil), do: ""

  defp vat_rate_input_value(bp) do
    bp |> Offers.VatRate.format() |> String.replace_suffix(" %", "")
  end

  defp minimum_spend_input_value(nil), do: ""

  defp minimum_spend_input_value(%Money{} = money) do
    money |> Format.money() |> String.replace_prefix("€ ", "")
  end

  defp form_exclusive?(form), do: to_string(form[:vat_basis].value) == "exclusive"

  defp maybe_prefill_vat_rate(params, false = _previously_exclusive?) do
    if Map.get(params, "vat_basis") == "exclusive" and blank?(Map.get(params, "vat_rate_input")) do
      Map.put(params, "vat_rate_input", "21")
    else
      params
    end
  end

  defp maybe_prefill_vat_rate(params, true), do: params

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp status_options, do: Enum.map(@statuses, &{status_label(&1), Atom.to_string(&1)})
  defp vat_basis_options, do: Enum.map(@vat_bases, &{vat_basis_label(&1), Atom.to_string(&1)})

  defp status_label(:considering), do: "Considering"
  defp status_label(:shortlisted), do: "Shortlisted"
  defp status_label(:rejected), do: "Rejected"
  defp status_label(:confirmed), do: "Confirmed"

  defp vat_basis_label(:inclusive), do: "Inclusive"
  defp vat_basis_label(:exclusive), do: "Exclusive"

  # DR-40's semantic table (`.claude/design/ui-decisions.md` §2):
  # considering/rejected -> neutral, shortlisted -> info, confirmed -> good.
  defp status_tone(:considering), do: :neutral
  defp status_tone(:shortlisted), do: :info
  defp status_tone(:confirmed), do: :good
  defp status_tone(:rejected), do: :neutral

  # -- offer lines helpers (task 52, DR-41) --------------------------------------------

  defp refresh_lines(socket) do
    offer = socket.assigns.offer
    lines = Offers.list_lines(offer)

    # An editor open on a line another process just deleted has nothing left to edit —
    # close it. A `:new` editor, or one open on a line that still exists, is untouched:
    # broadcasts never interrupt an in-progress edit (`XC-02`, `DR-21`).
    editing_line_id =
      case socket.assigns.editing_line_id do
        id when is_integer(id) -> if Enum.any?(lines, &(&1.id == id)), do: id, else: nil
        other -> other
      end

    socket
    |> assign(:editing_line_id, editing_line_id)
    |> stream(:lines, lines, reset: true, dom_id: &"offer-line-#{&1.id}")
  end

  # -- matrix deep links (task 66, DR-57) ------------------------------------------------

  defp open_deep_linked_line(socket, line_id) do
    with {:ok, id} <- parse_id(line_id),
         %OfferLine{} = line <- fetch_line(id),
         true <- line.offer_id == socket.assigns.offer.id do
      open_line_editor(socket, id)
    else
      _ -> socket
    end
  end

  defp open_deep_linked_add_line(socket, service_id) do
    with {:ok, id} <- parse_id(service_id),
         true <- Enum.any?(socket.assigns.services, &(&1.id == id)) do
      socket
      |> open_line_editor(:new)
      |> assign(:line_service_choice, to_string(id))
    else
      _ -> socket
    end
  end

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_id(_value), do: :error

  defp fetch_line(id) do
    Offers.get_line!(id)
  rescue
    Ecto.NoResultsError -> nil
  end

  defp open_line_editor(socket, target) do
    previous = socket.assigns.editing_line_id
    base_line = editor_base_line(socket, target)
    changeset = Offers.change_line(base_line, %{})

    socket
    |> assign(:editing_line_id, target)
    |> assign(:line_form, to_form(changeset, as: :line))
    |> assign(:line_service_choice, initial_service_choice(base_line))
    |> assign(:line_new_service_name, "")
    |> assign(:line_new_service_error, nil)
    |> reinsert_line_row(previous)
    |> reinsert_line_row(target)
  end

  defp close_line_editor(socket) do
    previous = socket.assigns.editing_line_id

    socket
    |> assign(:editing_line_id, nil)
    |> assign(:line_form, nil)
    |> assign(:line_service_choice, "")
    |> assign(:line_new_service_name, "")
    |> assign(:line_new_service_error, nil)
    |> reinsert_line_row(previous)
    |> push_patch(to: ~p"/offers/#{socket.assigns.offer.id}")
  end

  defp editing_base_line(socket), do: editor_base_line(socket, socket.assigns.editing_line_id)

  defp editor_base_line(socket, :new), do: %OfferLine{offer_id: socket.assigns.offer.id}
  defp editor_base_line(_socket, id) when is_integer(id), do: Offers.get_line!(id)

  defp initial_service_choice(%OfferLine{service_id: nil}), do: ""
  defp initial_service_choice(%OfferLine{service_id: id}), do: to_string(id)

  defp reinsert_line_row(socket, id) when id in [:new, nil], do: socket

  defp reinsert_line_row(socket, id) do
    stream_insert(socket, :lines, Offers.get_line!(id))
  rescue
    Ecto.NoResultsError -> socket
  end

  # `line[service_choice]` (`CST-02`) is a virtual selection, never a schema field — see
  # the moduledoc's "Offer lines" section for why it is translated here rather than in
  # `WeddingPlanner.Offers`.
  defp split_line_params(params) do
    choice = Map.get(params, "service_choice", "")
    new_name = Map.get(params, "new_service_name", "")
    attrs = Map.drop(params, ["service_choice", "new_service_name"])
    attrs = if choice == "", do: attrs, else: Map.delete(attrs, "label")
    {choice, new_name, attrs}
  end

  defp put_existing_service_id(attrs, ""), do: attrs
  defp put_existing_service_id(attrs, "new"), do: attrs
  defp put_existing_service_id(attrs, service_id), do: Map.put(attrs, "service_id", service_id)

  defp resolve_service_id(_scope, _category, "", _new_name, attrs), do: {:ok, attrs}

  defp resolve_service_id(scope, category, "new", new_name, attrs) do
    name = String.trim(new_name || "")

    if name == "" do
      {:error, :blank_name}
    else
      # CST-02: the service is created first, on its own. If the line then fails to
      # validate (below), the service is deliberately left in place rather than rolled
      # back — it is harmless, already visible in the category, and simply unused by
      # any offer until the couple retries the line.
      case Categories.create_service(scope, category, %{"name" => name}) do
        {:ok, service} -> {:ok, Map.put(attrs, "service_id", service.id)}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  defp resolve_service_id(_scope, _category, service_id, _new_name, attrs),
    do: {:ok, Map.put(attrs, "service_id", service_id)}

  defp persist_line(socket, scope, %OfferLine{id: nil} = _base_line, attrs) do
    case Offers.create_line(scope, socket.assigns.offer, attrs) do
      {:ok, _line} -> {:noreply, socket |> refresh_lines() |> close_line_editor()}
      {:error, changeset} -> {:noreply, assign(socket, :line_form, to_form(changeset, as: :line))}
    end
  end

  defp persist_line(socket, scope, %OfferLine{} = base_line, attrs) do
    case Offers.update_line(scope, base_line, attrs) do
      {:ok, _line} -> {:noreply, socket |> refresh_lines() |> close_line_editor()}
      {:error, changeset} -> {:noreply, assign(socket, :line_form, to_form(changeset, as: :line))}
    end
  end

  defp changeset_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Map.values()
    |> List.flatten()
    |> Enum.join(", ")
  end

  defp service_choice_options(services) do
    [{"Ad hoc (own label)", ""}] ++
      Enum.map(services, &{&1.name, to_string(&1.id)}) ++
      [{"+ New service…", "new"}]
  end

  defp line_state_options(""), do: [{"Mandatory", "mandatory"}, {"Optional", "optional"}]

  defp line_state_options(_choice) do
    [
      {"Mandatory", "mandatory"},
      {"Optional", "optional"},
      {"Included", "included"},
      {"Not offered", "not_offered"},
      {"Unknown", "unknown"}
    ]
  end

  defp line_basis_options do
    [
      {"Flat", "flat"},
      {"Per adult", "per_adult"},
      {"Per child", "per_child"},
      {"Per attendee", "per_attendee"}
    ]
  end

  # Reads the *normalised* value off the changeset directly
  # (`Ecto.Changeset.get_field/2`) rather than `form[:field].value`: once
  # `OfferLine.changeset/2` clears a pricing field for an unpriced state/flat basis, the
  # changeset's own `.changes`/`.data` correctly reflect the clear, but
  # `Phoenix.HTML.Form`'s `input_value` (via `Phoenix.HTML.FormData` for
  # `Ecto.Changeset`) falls back to the changeset's raw, pre-normalisation `.params` for
  # any field absent from `.changes` — so `form[:basis].value` would keep showing
  # whatever basis was last *typed*, even after the state switched to something unpriced
  # and the changeset itself cleared it back to `nil`. Reading `get_field/2` instead
  # matches the persisted/normalised truth, which is what "conditional display is
  # cosmetic" (`WeddingPlanner.Offers.OfferLine`'s moduledoc) means.
  defp line_priced?(form),
    do: OfferLine.priced_state?(Ecto.Changeset.get_field(form.source, :state))

  defp line_per_person?(form),
    do: OfferLine.per_person?(Ecto.Changeset.get_field(form.source, :basis))

  defp line_event_prompt(%OfferLine{} = line) do
    if OfferLine.invalid?(line), do: "Pick an event or switch to flat", else: "Choose an event"
  end

  defp line_event_prompt(nil), do: "Choose an event"

  defp offer_default_rate_placeholder(%Offer{vat_rate_bp: bp}), do: vat_rate_input_value(bp)

  defp line_summary(%OfferLine{state: :included}), do: "Included"
  defp line_summary(%OfferLine{state: :not_offered}), do: "Not offered"
  defp line_summary(%OfferLine{state: :unknown}), do: "Unknown — ask the vendor"

  defp line_summary(%OfferLine{} = line) do
    [
      line_amount_summary(line),
      line_event_name(line),
      line_minimum_charge_summary(line),
      line_included_quantity_summary(line)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp line_amount_summary(%OfferLine{amount: nil}), do: nil

  defp line_amount_summary(%OfferLine{amount: amount, basis: basis}),
    do: Format.money(amount) <> line_basis_suffix(basis)

  defp line_basis_suffix(:flat), do: ""
  defp line_basis_suffix(:per_adult), do: " / adult"
  defp line_basis_suffix(:per_child), do: " / child"
  defp line_basis_suffix(:per_attendee), do: " / attendee"

  defp line_event_name(%OfferLine{event: %Event{name: name}}), do: name
  defp line_event_name(%OfferLine{}), do: nil

  defp line_minimum_charge_summary(%OfferLine{minimum_charge: nil}), do: nil

  defp line_minimum_charge_summary(%OfferLine{minimum_charge: amount}),
    do: "min. #{Format.money(amount)}"

  defp line_included_quantity_summary(%OfferLine{included_quantity: nil}), do: nil
  defp line_included_quantity_summary(%OfferLine{included_quantity: qty}), do: "first #{qty} free"

  # DR-41: a line's VAT override is retained even once the offer turns inclusive (C3
  # ignores it, `CST-36` step 5) — shown muted rather than hidden, so it stays visible
  # and editable instead of silently vanishing.
  defp line_vat_note(%OfferLine{vat_rate_bp: nil}, _offer), do: nil

  defp line_vat_note(%OfferLine{vat_rate_bp: bp}, %Offer{vat_basis: :exclusive}),
    do: "#{VatRate.format(bp)} VAT"

  defp line_vat_note(%OfferLine{vat_rate_bp: bp}, %Offer{vat_basis: :inclusive}),
    do: "#{VatRate.format(bp)} VAT — ignored — offer is VAT inclusive"

  # -- render --------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <WeddingPlannerWeb.Live.TimeZoneHook.probe id="offer-time-zone-probe" />

      <.header>
        {@offer.vendor_name}
        <:subtitle>
          <.status_pill
            id="offer-status-pill"
            label={status_label(@offer.status)}
            tone={status_tone(@offer.status)}
          />
        </:subtitle>
        <:actions>
          <.button
            navigate={~p"/categories/#{@category.id}"}
            id="offer-back-to-category"
          >
            Back to {@category.name}
          </.button>
        </:actions>
      </.header>

      <.form
        for={@form}
        id="offer-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-4"
      >
        <.input
          field={@form[:vendor_name]}
          type="text"
          label="Vendor name"
          id="offer-form-vendor"
        />

        <.input
          :if={@offer.status != :confirmed}
          field={@form[:status]}
          type="select"
          label="Status"
          id="offer-form-status"
          options={status_options()}
        />

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <.input
            field={@form[:vat_basis]}
            type="select"
            label="VAT basis"
            id="offer-form-vat-basis"
            options={vat_basis_options()}
          />

          <.input
            :if={form_exclusive?(@form)}
            field={@form[:vat_rate_input]}
            type="text"
            label="Default VAT rate (%)"
            id="offer-form-vat-rate"
            placeholder="21"
          />
        </div>

        <.input
          field={@form[:minimum_spend_input]}
          type="text"
          label="Minimum spend (VAT incl.)"
          id="offer-form-minimum-spend"
          placeholder="e.g. 7.000"
        />

        <div>
          <.input
            field={@form[:url]}
            type="url"
            label="URL"
            id="offer-form-url"
            placeholder="https://…"
          />
          <a
            :if={@offer.url}
            href={@offer.url}
            target="_blank"
            rel="noopener noreferrer"
            id="offer-url-link"
            class="mt-1 inline-block text-sm font-medium text-accent hover:underline"
          >
            Visit site
          </a>
        </div>

        <.input field={@form[:notes]} type="textarea" label="Notes" id="offer-form-notes" />

        <.button variant="primary" id="offer-form-submit">Save offer</.button>
      </.form>

      <.cost_card cost={@cost} selected={@cost.selected && @cost.selected.id} />

      <div :if={@offer.status == :confirmed} class="mt-8 space-y-4" id="offer-invoices">
        <.header>
          Invoices
          <:actions>
            <.link
              navigate={~p"/invoices?category=#{@category.id}"}
              id="offer-add-invoice"
              class="text-sm font-medium text-accent hover:underline"
            >
              + Add invoice
            </.link>
          </:actions>
        </.header>

        <ul id="offer-invoices-list" phx-update="stream" class="space-y-3">
          <li
            id="offer-invoices-empty"
            class="hidden rounded-field border border-dashed border-line-strong p-4 text-center text-sm text-ink-faint only:block"
          >
            No invoices yet
          </li>
          <li :for={{dom_id, invoice} <- @streams.offer_invoices} id={dom_id}>
            <.invoice_row
              id={"offer-invoice-#{invoice.id}"}
              invoice={invoice}
              snapshot={@invoice_snapshot}
              today={@invoice_today}
              show_offer?={false}
            />
          </li>
        </ul>

        <div
          id="offer-invoice-figures"
          class="grid grid-cols-3 gap-4 rounded-field border border-line bg-surface-raised p-4 text-center"
        >
          <div>
            <p class="text-xs font-medium tracking-wide text-ink-soft uppercase">Invoiced</p>
            <p class="mt-1 text-lg font-semibold text-ink">
              {Format.money(@invoice_figures.invoiced)}
            </p>
          </div>
          <div>
            <p class="text-xs font-medium tracking-wide text-ink-soft uppercase">Paid</p>
            <p class="mt-1 text-lg font-semibold text-ink">{Format.money(@invoice_figures.paid)}</p>
          </div>
          <div>
            <p class="text-xs font-medium tracking-wide text-ink-soft uppercase">Outstanding</p>
            <p class="mt-1 text-lg font-semibold text-ink">
              {Format.money(@invoice_figures.outstanding)}
            </p>
          </div>
        </div>

        <.variance_panel
          :if={@variance}
          id="offer-variance"
          variance={@variance}
          preset_name={@invoice_preset_name}
        />

        <button
          type="button"
          id="offer-invoicing-complete"
          phx-click="toggle_invoicing_complete"
          class={invoicing_complete_class(@offer.invoicing_complete)}
        >
          <%= if @offer.invoicing_complete do %>
            Invoicing complete
          <% else %>
            Mark invoicing complete
          <% end %>
        </button>
      </div>

      <div class="mt-8" id="offer-lines-section">
        <.header>Lines</.header>

        <ul id="offer-lines" phx-update="stream" class="mt-2 space-y-3">
          <li
            id="offer-lines-empty"
            class="hidden rounded-field border border-dashed border-line-strong p-4 text-center text-sm text-ink-faint only:block"
          >
            No lines yet
          </li>
          <li
            :for={{dom_id, line} <- @streams.lines}
            id={dom_id}
            class="rounded-field border border-line bg-surface-raised p-4"
          >
            <.line_editor
              :if={@editing_line_id == line.id}
              id_prefix="edit-line"
              form={@line_form}
              offer={@offer}
              services={@services}
              events={@events}
              service_choice={@line_service_choice}
              new_service_name={@line_new_service_name}
              new_service_error={@line_new_service_error}
              line={line}
            />
            <.offer_line_row
              :if={@editing_line_id != line.id}
              line={line}
              offer={@offer}
              confirming_delete?={@confirming_delete_line_id == line.id}
            />
          </li>
        </ul>

        <div class="mt-4 rounded-field border border-line bg-surface-raised p-4">
          <.line_editor
            :if={@editing_line_id == :new}
            id_prefix="add-line"
            form={@line_form}
            offer={@offer}
            services={@services}
            events={@events}
            service_choice={@line_service_choice}
            new_service_name={@line_new_service_name}
            new_service_error={@line_new_service_error}
            line={nil}
          />
          <.button :if={@editing_line_id != :new} id="offer-add-line" phx-click="add_line">
            + Add line
          </.button>
        </div>
      </div>

      <div class="mt-8">
        <.header>References</.header>
        <.live_component
          module={WeddingPlannerWeb.ReferencesComponent}
          id="offer-references"
          owner={Offers.reference_owner(@offer)}
          references={@references}
          current_scope={@current_scope}
          time_zone={@time_zone}
        />
      </div>

      <div class="mt-8 space-y-2">
        <.header>Delete this offer</.header>
        <button
          type="button"
          id="offer-delete"
          phx-click="confirm_delete"
          class="inline-flex min-h-11 items-center justify-center gap-2 rounded-field bg-bad px-4 text-sm font-semibold text-white shadow-sm transition-all duration-150 ease-out hover:opacity-90 active:scale-[0.98] active:opacity-95"
        >
          Delete offer
        </button>

        <.destructive_confirm
          :if={@confirming_delete and not @confirming_delete_blocked?}
          id="offer-delete-confirm"
          title={"Delete '#{@offer.vendor_name}'?"}
          body="This cannot be undone. Its references and files are removed too."
          affected={Offers.offer_deletion_effects(@offer)}
          confirm="delete_confirmed"
          cancel="cancel_delete"
        />

        <div
          :if={@confirming_delete and @confirming_delete_blocked?}
          id="offer-delete-blocked"
          role="alertdialog"
          aria-labelledby="offer-delete-blocked-title"
          class="mt-2 rounded-field border border-line-strong bg-surface p-4"
        >
          <p id="offer-delete-blocked-title" class="text-sm font-semibold text-ink">
            Can't delete '{@offer.vendor_name}'
          </p>
          <p class="mt-1 text-sm text-ink-soft">
            It has {Enum.map_join(Offers.offer_deletion_blockers(@offer), ", ", & &1.label)} linked
            to it. Unlink or delete them first.
          </p>
          <div class="mt-4 flex flex-wrap gap-2">
            <.button id="offer-delete-blocked-cancel" phx-click="cancel_delete">Cancel</.button>
          </div>
        </div>
      </div>

      <div class="mt-8">
        <.header>History</.header>
        <.entity_history
          id="offer-history"
          entity={{:offer, @offer.id}}
          entries={@activity_entries}
          time_zone={@time_zone}
        />
      </div>
    </Layouts.app>
    """
  end

  # -- offer line row (task 52) ---------------------------------------------------------

  attr :line, :any, required: true
  attr :offer, :any, required: true
  attr :confirming_delete?, :boolean, required: true

  defp offer_line_row(assigns) do
    ~H"""
    <div class={["space-y-2", OfferLine.invalid?(@line) && "text-ink-faint line-through"]}>
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <p class="font-medium text-ink">{Offers.line_label(@line)}</p>
          <p class="text-sm text-ink-soft">{line_summary(@line)}</p>
          <p :if={line_vat_note(@line, @offer)} class="text-xs text-ink-faint">
            {line_vat_note(@line, @offer)}
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <.gap_severity
            :if={OfferLine.invalid?(@line)}
            id={"offer-line-#{@line.id}-invalid"}
            severity={:invalid}
            label="Event deleted"
          />

          <.form
            :if={OfferLine.optional_ad_hoc?(@line)}
            for={to_form(%{}, as: :toggle)}
            id={"offer-line-#{@line.id}-toggle-form"}
            phx-change="toggle_line"
            phx-value-id={@line.id}
            class="contents"
          >
            <.input
              type="checkbox"
              id={"offer-line-#{@line.id}-toggle"}
              name="enabled"
              value="true"
              checked={@line.enabled}
              label="On"
            />
          </.form>

          <.button id={"offer-line-#{@line.id}-edit"} phx-click="edit_line" phx-value-id={@line.id}>
            Edit
          </.button>
          <.button
            variant="destructive"
            id={"offer-line-#{@line.id}-delete"}
            phx-click="confirm_delete_line"
            phx-value-id={@line.id}
          >
            Delete
          </.button>
        </div>
      </div>

      <.destructive_confirm
        :if={@confirming_delete?}
        id={"offer-line-#{@line.id}-delete-confirm"}
        title={"Delete '#{Offers.line_label(@line)}'?"}
        body="This cannot be undone."
        confirm="delete_line"
        confirm_value={@line.id}
        cancel="cancel_delete_line"
      />
    </div>
    """
  end

  # -- add/edit line editor (task 52) — shared by the add slot (`id_prefix="add-line"`)
  # and whichever row is open (`id_prefix="edit-line"`); only one is ever mounted at a
  # time (`@editing_line_id`), so every field keeps its fixed, unparameterised id — same
  # discipline as `WeddingPlannerWeb.TaskComponents.task_editor/1`. -------------------

  attr :id_prefix, :string, required: true
  attr :form, :any, required: true
  attr :offer, :any, required: true
  attr :services, :list, required: true
  attr :events, :list, required: true
  attr :service_choice, :string, required: true
  attr :new_service_name, :string, required: true
  attr :new_service_error, :any, default: nil
  attr :line, :any, default: nil

  defp line_editor(assigns) do
    ~H"""
    <.form
      for={@form}
      id={"#{@id_prefix}-form"}
      phx-change="validate_line"
      phx-submit="save_line"
      class="space-y-4"
    >
      <.input
        type="select"
        id={"#{@id_prefix}-service"}
        name="line[service_choice]"
        label="Service"
        value={@service_choice}
        options={service_choice_options(@services)}
        phx-mounted={JS.focus()}
      />

      <div :if={@service_choice == "new"}>
        <.input
          type="text"
          id={"#{@id_prefix}-new-service-name"}
          name="line[new_service_name]"
          label="New service name"
          value={@new_service_name}
        />
        <p :if={@new_service_error} class="mt-1 text-sm text-bad">{@new_service_error}</p>
      </div>

      <.input
        :if={@service_choice == ""}
        field={@form[:label]}
        type="text"
        label="Label"
        id={"#{@id_prefix}-label"}
        placeholder="e.g. Cleaning fee"
      />

      <.input
        field={@form[:state]}
        type="select"
        label="State"
        id={"#{@id_prefix}-state"}
        prompt="Choose a state"
        options={line_state_options(@service_choice)}
      />

      <div :if={line_priced?(@form)} class="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <.input
          field={@form[:basis]}
          type="select"
          label="Basis"
          id={"#{@id_prefix}-basis"}
          prompt="Choose a basis"
          options={line_basis_options()}
        />

        <.input
          field={@form[:amount_input]}
          type="text"
          label="Amount"
          id={"#{@id_prefix}-amount"}
          placeholder="e.g. 85"
        />
      </div>

      <.input
        :if={line_per_person?(@form)}
        field={@form[:event_id]}
        type="select"
        label="Event"
        id={"#{@id_prefix}-event"}
        prompt={line_event_prompt(@line)}
        options={Enum.map(@events, &{&1.name, &1.id})}
      />

      <.input
        :if={line_per_person?(@form)}
        field={@form[:included_quantity]}
        type="number"
        label="Included quantity"
        id={"#{@id_prefix}-included"}
        min="0"
      />

      <.input
        :if={line_priced?(@form)}
        field={@form[:minimum_charge_input]}
        type="text"
        label="Minimum charge"
        id={"#{@id_prefix}-minimum-charge"}
        placeholder="e.g. 6.800"
      />

      <.input
        :if={line_priced?(@form) and @offer.vat_basis == :exclusive}
        field={@form[:vat_rate_input]}
        type="text"
        label="VAT rate override (%)"
        id={"#{@id_prefix}-vat-rate"}
        placeholder={offer_default_rate_placeholder(@offer)}
      />

      <div class="flex flex-wrap items-center gap-2 pt-2">
        <.button variant="primary" id={"#{@id_prefix}-submit"}>Save line</.button>
        <button
          type="button"
          id={"#{@id_prefix}-cancel"}
          phx-click="cancel_line"
          class={secondary_button_class()}
        >
          Cancel
        </button>
      </div>
    </.form>
    """
  end

  # Mirrors `WeddingPlannerWeb.TaskComponents`' own private helper (see that module's
  # moduledoc for why `<.button type="button">` cannot be used for Cancel here: its
  # `:rest` global attrs do not include `type`, so it would silently submit the form).
  defp secondary_button_class do
    "inline-flex min-h-11 items-center justify-center gap-2 rounded-field px-4 text-sm font-semibold " <>
      "cursor-pointer transition-all duration-150 ease-out active:scale-[0.98] " <>
      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-paper " <>
      "disabled:cursor-not-allowed disabled:opacity-50 disabled:active:scale-100 " <>
      "bg-transparent text-ink border border-line-strong hover:bg-surface active:bg-line"
  end
end
