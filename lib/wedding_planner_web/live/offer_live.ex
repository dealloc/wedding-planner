defmodule WeddingPlannerWeb.Live.OfferLive do
  @moduledoc """
  An offer's own page (task 51; `/offers/:id`, `DR-40`): its header fields
  (`docs/modules/offers-and-comparison.md` `CST-10`, `CST-33`, `CST-36`), the
  `WeddingPlannerWeb.ReferencesComponent` panel mounted here for the first time
  (`DR-28`, `DR-31`), its own activity history (`XC-11`) and delete (`XC-24`, `XC-40`).
  Offer lines and their editor are task 52 — nothing here reads or writes a line.

  Default (narrow) `Layouts.app` width — this page is a single stacked form plus the
  references panel, no wide-table need (unlike `CategoryLive`, which is deliberately
  built wide for the future comparison matrix).

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

  Subscribes to `:offer`, `:reference`, `:category` and `:activity_entry`. Task 52 adds
  `:offer_line`, `:service` and `:event` once lines exist. A `{:deleted, id}` for this
  offer, from another process, navigates the viewer to the category with a flash — the
  same "the thing you were looking at is gone" pattern `PersonLive` uses. `:category`
  is only subscribed to keep the breadcrumb's category name live (a category with any
  offer can never itself be deleted — `Categories.category_deletion_blockers/1` — so
  the only realistic event here is a rename). Per `DR-21`, every other broadcast simply
  updates assigns in place: no highlight, badge or "someone else changed this" notice.
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.ActivityComponents, only: [entity_history: 1]

  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.References
  alias WeddingPlannerWeb.Format

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
    end

    socket =
      socket
      |> assign(:page_title, offer.vendor_name)
      |> assign(:category, offer.category)
      |> assign(:confirming_delete, false)
      |> assign(:activity_entries, Query.for_entity(:offer, offer.id))
      |> refresh_view(offer)

    {:ok, socket}
  end

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
    {:noreply, assign(socket, :confirming_delete, true)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirming_delete, false)}
  end

  def handle_event("delete_confirmed", _params, socket) do
    scope = socket.assigns.current_scope
    category = socket.assigns.category
    {:ok, _} = Offers.delete_offer(scope, socket.assigns.offer)

    {:noreply,
     socket
     |> put_flash(:info, "Offer deleted.")
     |> push_navigate(to: ~p"/categories/#{category.id}")}
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
      {:noreply, refresh_view(socket, offer)}
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

  # -- helpers -----------------------------------------------------------------------

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
          :if={@confirming_delete}
          id="offer-delete-confirm"
          title={"Delete '#{@offer.vendor_name}'?"}
          body="This cannot be undone. Its references and files are removed too."
          affected={Offers.offer_deletion_effects(@offer)}
          confirm="delete_confirmed"
          cancel="cancel_delete"
        />
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
end
