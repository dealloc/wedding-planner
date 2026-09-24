defmodule WeddingPlannerWeb.Live.InvoiceLive do
  @moduledoc """
  An invoice's own page (task 69; `/invoices/:id`, `DR-59`): header fields edited in
  place, a paid toggle, its lines (add/edit/delete), the references panel, its history
  and delete with confirmation — the `WeddingPlannerWeb.Live.OfferLive` pattern applied
  to invoices.

  ## Header form (`BIL-01`, `BIL-02`, `DR-59`)

  One `<.form id="invoice-form">`, validate-on-change/persist-on-submit
  (`WeddingPlannerWeb.Live.OfferLive` precedent). The category select is rendered
  `disabled` while the invoice is linked to an offer (`Invoice.changeset/2`'s own rule);
  the offer-link select lists the confirmed offers of whichever category the (saved)
  invoice currently has, disabled with a hint when there are none (`DR-58`).

  ## Lines (`BIL-02`, `BIL-03`)

  A `:lines` stream, one editor open at a time (`@editing_line_id`: `nil` | an id |
  `:new`), the same discipline `OfferLine`'s editor in `OfferLive` uses. The last
  remaining line's delete control is hidden (`@lines_count <= 1`) — `Invoices.delete_line/2`
  refuses it anyway (`{:error, :last_line}`), kept as a defensive fallback.

  ## Paid (`BIL-02`, `DR-59`)

  `#invoice-paid-toggle` reads "Mark paid" while unpaid (opening `#invoice-paid-form`, a
  date input defaulting to `WeddingPlanner.Tasks.TodoList.today(@time_zone)`, editable)
  or "Mark unpaid" while paid (a single, immediate action — no form). Each is exactly one
  `WeddingPlanner.Invoices` call (`mark_paid/3`/`mark_unpaid/2`).

  ## Figures (`BIL-03`, `BIL-06`)

  The total and the overdue highlight both come from `WeddingPlanner.Valuation.Invoices`
  over a freshly loaded `WeddingPlanner.Valuation.Snapshot` — never re-derived here.

  ## References, history, delete (`XC-11`, `XC-20`–`XC-24`, `XC-40`)

  Mounted exactly as `OfferLive` mounts them: `WeddingPlannerWeb.ReferencesComponent` over
  `Invoices.reference_owner/1`, `WeddingPlannerWeb.ActivityComponents.entity_history/1`
  over `{:invoice, id}`, and `CoreComponents.destructive_confirm/1` listing
  `Invoices.invoice_deletion_effects/1`. A `{:deleted, id}` broadcast for this invoice
  (from another process) redirects to `/invoices` with a flash, the same "the thing you
  were looking at is gone" pattern.
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.ActivityComponents, only: [entity_history: 1]

  alias WeddingPlanner.Categories
  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Invoices.InvoiceLine
  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.References
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks.TodoList
  alias WeddingPlanner.Valuation.Invoices, as: InvoiceValuation
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Format

  on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    invoice = Invoices.get_invoice!(id) |> Repo.preload([:category, :offer])

    if connected?(socket) do
      Realtime.subscribe(:invoice)
      Realtime.subscribe(:invoice_line)
      Realtime.subscribe(:category)
      Realtime.subscribe(:offer)
      Realtime.subscribe(:reference)
      Realtime.subscribe(:activity_entry)
    end

    socket =
      socket
      |> assign(:categories, Categories.list_categories())
      |> assign(:confirming_delete, false)
      |> assign(:confirming_paid, false)
      |> assign(:paid_form, nil)
      |> assign(:editing_line_id, nil)
      |> assign(:confirming_delete_line_id, nil)
      |> assign(:line_form, nil)
      |> assign(:activity_entries, Query.for_entity(:invoice, invoice.id))
      |> refresh_view(invoice)

    {:ok, socket}
  end

  # -- header form (BIL-01, BIL-02, DR-59) ---------------------------------------------

  @impl true
  def handle_event("validate", %{"invoice" => params}, socket) do
    changeset =
      socket.assigns.invoice |> Invoices.change_invoice(params) |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :invoice))}
  end

  def handle_event("save", %{"invoice" => params}, socket) do
    scope = socket.assigns.current_scope

    case Invoices.update_invoice(scope, socket.assigns.invoice, params) do
      {:ok, invoice} ->
        {:noreply, socket |> refresh_view(invoice) |> put_flash(:info, "Invoice updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :invoice))}
    end
  end

  # -- paid (BIL-02, DR-59) ------------------------------------------------------------

  def handle_event("open_mark_paid", _params, socket) do
    socket =
      socket
      |> assign(:confirming_paid, true)
      |> assign(
        :paid_form,
        to_form(%{"paid_on" => Date.to_iso8601(socket.assigns.today)}, as: :paid)
      )

    {:noreply, socket}
  end

  def handle_event("cancel_mark_paid", _params, socket) do
    {:noreply, assign(socket, :confirming_paid, false)}
  end

  def handle_event("confirm_mark_paid", %{"paid" => %{"paid_on" => date_str}}, socket) do
    scope = socket.assigns.current_scope

    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        {:ok, invoice} = Invoices.mark_paid(scope, socket.assigns.invoice, date)

        {:noreply,
         socket
         |> assign(:confirming_paid, false)
         |> refresh_view(invoice)
         |> put_flash(:info, "Invoice marked paid.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Pick a valid date.")}
    end
  end

  def handle_event("mark_unpaid", _params, socket) do
    scope = socket.assigns.current_scope
    {:ok, invoice} = Invoices.mark_unpaid(scope, socket.assigns.invoice)

    {:noreply, socket |> refresh_view(invoice) |> put_flash(:info, "Invoice marked unpaid.")}
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
    {:ok, _} = Invoices.delete_invoice(scope, socket.assigns.invoice)

    {:noreply,
     socket
     |> put_flash(:info, "Invoice deleted.")
     |> push_navigate(to: ~p"/invoices")}
  end

  # -- lines (BIL-02, BIL-03) -----------------------------------------------------------

  def handle_event("add_line", _params, socket), do: {:noreply, open_line_editor(socket, :new)}

  def handle_event("edit_line", %{"id" => id}, socket),
    do: {:noreply, open_line_editor(socket, String.to_integer(id))}

  def handle_event("cancel_line", _params, socket), do: {:noreply, close_line_editor(socket)}

  def handle_event("validate_line", %{"line" => params}, socket) do
    changeset =
      socket |> editing_base_line() |> Invoices.change_line(params) |> Map.put(:action, :validate)

    {:noreply, assign(socket, :line_form, to_form(changeset, as: :line))}
  end

  def handle_event("save_line", %{"line" => params}, socket) do
    scope = socket.assigns.current_scope
    persist_line(socket, scope, editing_base_line(socket), params)
  end

  def handle_event("confirm_delete_line", %{"id" => id}, socket) do
    id = String.to_integer(id)
    {:noreply, socket |> assign(:confirming_delete_line_id, id) |> reinsert_line_row(id)}
  end

  def handle_event("cancel_delete_line", _params, socket) do
    id = socket.assigns.confirming_delete_line_id
    {:noreply, socket |> assign(:confirming_delete_line_id, nil) |> reinsert_line_row(id)}
  end

  def handle_event("delete_line", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    line = Invoices.get_line!(id)

    socket = assign(socket, :confirming_delete_line_id, nil)

    case Invoices.delete_line(scope, line) do
      {:ok, _line} -> {:noreply, socket |> refresh_lines() |> refresh_figures()}
      {:error, :last_line} -> {:noreply, refresh_lines(socket)}
    end
  end

  # -- live updates (XC-01, XC-02) ------------------------------------------------------

  @impl true
  def handle_info({Realtime, :invoice, {:deleted, id}}, socket) do
    if id == socket.assigns.invoice.id do
      {:noreply,
       socket
       |> put_flash(:error, "This invoice was deleted.")
       |> push_navigate(to: ~p"/invoices")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({Realtime, :invoice, {event, invoice}}, socket)
      when event in [:created, :updated] do
    if invoice.id == socket.assigns.invoice.id do
      {:noreply, refresh_view(socket, invoice)}
    else
      {:noreply, socket}
    end
  end

  # A line-deleted broadcast for *this* invoice's own last line arrives as part of the
  # same `delete_invoice/2` that removes the invoice row itself (its lines are deleted
  # first, then the invoice, all broadcasts sent only after commit — see that
  # function's moduledoc) — so by the time this arrives the invoice may already be
  # gone. Guard the refetch; the `:invoice`/`{:deleted, id}` broadcast that follows
  # handles navigating the viewer away.
  def handle_info({Realtime, :invoice_line, _event}, socket) do
    if Repo.get(Invoice, socket.assigns.invoice.id) do
      {:noreply, socket |> refresh_lines() |> refresh_figures()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({Realtime, :category, _event}, socket) do
    socket = assign(socket, :categories, Categories.list_categories())
    {:noreply, refresh_view(socket, socket.assigns.invoice)}
  end

  def handle_info({Realtime, :offer, _event}, socket),
    do: {:noreply, refresh_view(socket, socket.assigns.invoice)}

  def handle_info({Realtime, :reference, _event}, socket) do
    owner = Invoices.reference_owner(socket.assigns.invoice)
    {:noreply, assign(socket, :references, References.list_references(owner))}
  end

  def handle_info({Realtime, :activity_entry, {:created, entry}}, socket) do
    %{invoice: invoice} = socket.assigns

    if entry.entity_type == "invoice" and entry.entity_id == invoice.id do
      entry = Query.preload_user(entry)
      {:noreply, update(socket, :activity_entries, &[entry | &1])}
    else
      {:noreply, socket}
    end
  end

  # -- helpers: header/figures ----------------------------------------------------------

  defp refresh_view(socket, %Invoice{} = invoice) do
    invoice = Repo.preload(invoice, [:category, :offer], force: true)

    socket
    |> assign(:invoice, invoice)
    |> assign(:page_title, invoice.label)
    |> assign(:form, to_form(Invoices.change_invoice(invoice, %{}), as: :invoice))
    |> assign(:references, References.list_references(Invoices.reference_owner(invoice)))
    |> refresh_figures()
    |> refresh_lines()
  end

  defp refresh_figures(socket) do
    invoice = socket.assigns.invoice
    snapshot = Snapshot.load(WeddingPlanner.Repo)
    today = TodoList.today(socket.assigns.time_zone)

    socket
    |> assign(:snapshot, snapshot)
    |> assign(:today, today)
    |> assign(:total, InvoiceValuation.total(snapshot, invoice))
    |> assign(:overdue?, InvoiceValuation.overdue?(invoice, today))
    |> assign(:paid?, InvoiceValuation.paid?(invoice))
  end

  defp confirmed_offers_for(category_id) do
    case parse_id(category_id) do
      {:ok, id} -> id |> Offers.list_offers() |> Enum.filter(&(&1.status == :confirmed))
      :error -> []
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_id(_other), do: :error

  # -- helpers: lines --------------------------------------------------------------------

  defp refresh_lines(socket) do
    lines = Invoices.get_invoice!(socket.assigns.invoice.id).lines

    editing_line_id =
      case socket.assigns.editing_line_id do
        id when is_integer(id) -> if Enum.any?(lines, &(&1.id == id)), do: id, else: nil
        other -> other
      end

    socket
    |> assign(:invoice, %{socket.assigns.invoice | lines: lines})
    |> assign(:editing_line_id, editing_line_id)
    |> assign(:lines_count, length(lines))
    |> stream(:lines, lines, reset: true, dom_id: &"invoice-line-#{&1.id}")
  end

  defp open_line_editor(socket, target) do
    previous = socket.assigns.editing_line_id
    base_line = editor_base_line(socket, target)
    changeset = Invoices.change_line(base_line, %{})

    socket
    |> assign(:editing_line_id, target)
    |> assign(:line_form, to_form(changeset, as: :line))
    |> reinsert_line_row(previous)
    |> reinsert_line_row(target)
  end

  defp close_line_editor(socket) do
    previous = socket.assigns.editing_line_id

    socket
    |> assign(:editing_line_id, nil)
    |> assign(:line_form, nil)
    |> reinsert_line_row(previous)
  end

  defp editing_base_line(socket), do: editor_base_line(socket, socket.assigns.editing_line_id)

  defp editor_base_line(socket, :new), do: %InvoiceLine{invoice_id: socket.assigns.invoice.id}
  defp editor_base_line(_socket, id) when is_integer(id), do: Invoices.get_line!(id)

  defp reinsert_line_row(socket, id) when id in [:new, nil], do: socket

  defp reinsert_line_row(socket, id) do
    stream_insert(socket, :lines, Invoices.get_line!(id))
  rescue
    Ecto.NoResultsError -> socket
  end

  defp persist_line(socket, scope, %InvoiceLine{id: nil}, params) do
    case Invoices.create_line(scope, socket.assigns.invoice, params) do
      {:ok, _line} ->
        {:noreply, socket |> refresh_lines() |> refresh_figures() |> close_line_editor()}

      {:error, changeset} ->
        {:noreply, assign(socket, :line_form, to_form(changeset, as: :line))}
    end
  end

  defp persist_line(socket, scope, %InvoiceLine{} = base_line, params) do
    case Invoices.update_line(scope, base_line, params) do
      {:ok, _line} ->
        {:noreply, socket |> refresh_lines() |> refresh_figures() |> close_line_editor()}

      {:error, changeset} ->
        {:noreply, assign(socket, :line_form, to_form(changeset, as: :line))}
    end
  end

  defp secondary_button_class do
    "inline-flex min-h-11 items-center justify-center gap-2 rounded-field px-4 text-sm font-semibold " <>
      "cursor-pointer transition-all duration-150 ease-out active:scale-[0.98] " <>
      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-paper " <>
      "bg-transparent text-ink border border-line-strong hover:bg-surface active:bg-line"
  end

  # -- render --------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <WeddingPlannerWeb.Live.TimeZoneHook.probe id="invoice-time-zone-probe" />

      <.header>
        {@invoice.label}
        <:subtitle>
          <.status_pill
            :if={@overdue?}
            id="invoice-status-pill"
            label="Overdue"
            tone={:bad}
          />
          <.status_pill
            :if={@paid?}
            id="invoice-status-pill"
            label="Paid"
            tone={:good}
          />
          <.status_pill
            :if={!@paid? and !@overdue?}
            id="invoice-status-pill"
            label="Unpaid"
            tone={:neutral}
          />
        </:subtitle>
        <:actions>
          <.button navigate={~p"/invoices"} id="invoice-back-to-invoices">Back to Invoices</.button>
        </:actions>
      </.header>

      <.form
        for={@form}
        id="invoice-form"
        phx-change="validate"
        phx-submit="save"
        class="mt-4 space-y-4"
      >
        <.input field={@form[:label]} type="text" label="Label" id="invoice-form-label" />

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <.input
            field={@form[:invoice_date]}
            type="date"
            label="Invoice date"
            id="invoice-form-invoice-date"
          />
          <.input
            field={@form[:due_date]}
            type="date"
            label="Due date"
            id="invoice-form-due-date"
          />
        </div>

        <.input
          field={@form[:category_id]}
          type="select"
          label="Category"
          id="invoice-form-category"
          disabled={@invoice.offer_id != nil}
          options={Enum.map(@categories, &{&1.name, &1.id})}
        />

        <div>
          <.input
            field={@form[:offer_id]}
            type="select"
            label="Linked offer"
            id="invoice-form-offer"
            prompt="No offer"
            disabled={confirmed_offers_for(@form[:category_id].value) == []}
            options={
              Enum.map(confirmed_offers_for(@form[:category_id].value), &{&1.vendor_name, &1.id})
            }
          />
          <p
            :if={confirmed_offers_for(@form[:category_id].value) == []}
            class="mt-1 text-xs text-ink-faint"
          >
            Only confirmed offers can be linked
          </p>
        </div>

        <.button variant="primary" id="invoice-form-submit">Save invoice</.button>
      </.form>

      <div class="mt-6">
        <.button :if={!@paid?} id="invoice-paid-toggle" phx-click="open_mark_paid">
          Mark paid
        </.button>
        <.button :if={@paid?} id="invoice-paid-toggle" phx-click="mark_unpaid">
          Mark unpaid
        </.button>

        <.form
          :if={@confirming_paid}
          for={@paid_form}
          id="invoice-paid-form"
          phx-submit="confirm_mark_paid"
          class="mt-2 flex flex-wrap items-end gap-2"
        >
          <.input field={@paid_form[:paid_on]} type="date" label="Paid on" id="invoice-paid-date" />
          <.button variant="primary" id="invoice-paid-confirm">Confirm</.button>
          <button
            type="button"
            id="invoice-paid-cancel"
            phx-click="cancel_mark_paid"
            class={secondary_button_class()}
          >
            Cancel
          </button>
        </.form>
      </div>

      <div class="mt-8" id="invoice-lines-section">
        <.header>
          Lines
          <:subtitle>
            <span id="invoice-total" class="font-semibold text-ink">{Format.money(@total)}</span>
          </:subtitle>
        </.header>

        <ul id="invoice-lines" phx-update="stream" class="mt-2 space-y-3">
          <li
            id="invoice-lines-empty"
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
              form={@line_form}
            />
            <.invoice_line_row
              :if={@editing_line_id != line.id}
              line={line}
              can_delete?={@lines_count > 1}
              confirming_delete?={@confirming_delete_line_id == line.id}
            />
          </li>
        </ul>

        <div class="mt-4 rounded-field border border-line bg-surface-raised p-4">
          <.line_editor :if={@editing_line_id == :new} form={@line_form} />
          <.button :if={@editing_line_id != :new} id="invoice-add-line" phx-click="add_line">
            + Add line
          </.button>
        </div>
      </div>

      <div class="mt-8">
        <.header>References</.header>
        <.live_component
          module={WeddingPlannerWeb.ReferencesComponent}
          id="invoice-references"
          owner={Invoices.reference_owner(@invoice)}
          references={@references}
          current_scope={@current_scope}
          time_zone={@time_zone}
        />
      </div>

      <div class="mt-8 space-y-2">
        <.header>Delete this invoice</.header>
        <button
          type="button"
          id="invoice-delete"
          phx-click="confirm_delete"
          class="inline-flex min-h-11 items-center justify-center gap-2 rounded-field bg-bad px-4 text-sm font-semibold text-white shadow-sm transition-all duration-150 ease-out hover:opacity-90 active:scale-[0.98] active:opacity-95"
        >
          Delete invoice
        </button>

        <.destructive_confirm
          :if={@confirming_delete}
          id="invoice-delete-confirm"
          title={"Delete '#{@invoice.label}'?"}
          body="This cannot be undone. Its references and files are removed too."
          affected={Invoices.invoice_deletion_effects(@invoice)}
          confirm="delete_confirmed"
          cancel="cancel_delete"
        />
      </div>

      <div class="mt-8">
        <.header>History</.header>
        <.entity_history
          id="invoice-history"
          entity={{:invoice, @invoice.id}}
          entries={@activity_entries}
          time_zone={@time_zone}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :line, :any, required: true
  attr :can_delete?, :boolean, required: true
  attr :confirming_delete?, :boolean, required: true

  defp invoice_line_row(assigns) do
    ~H"""
    <div class="space-y-2">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <p class="font-medium text-ink">{@line.label}</p>
          <p class="text-sm text-ink-soft">{Format.money(@line.amount)}</p>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <.button id={"invoice-line-#{@line.id}-edit"} phx-click="edit_line" phx-value-id={@line.id}>
            Edit
          </.button>
          <.button
            :if={@can_delete?}
            variant="destructive"
            id={"invoice-line-#{@line.id}-delete"}
            phx-click="confirm_delete_line"
            phx-value-id={@line.id}
          >
            Delete
          </.button>
        </div>
      </div>

      <.destructive_confirm
        :if={@confirming_delete?}
        id={"invoice-line-#{@line.id}-delete-confirm"}
        title={"Delete '#{@line.label}'?"}
        body="This cannot be undone."
        confirm="delete_line"
        confirm_value={@line.id}
        cancel="cancel_delete_line"
      />
    </div>
    """
  end

  attr :form, :any, required: true

  defp line_editor(assigns) do
    ~H"""
    <.form
      for={@form}
      id="invoice-line-form"
      phx-change="validate_line"
      phx-submit="save_line"
      class="space-y-4"
    >
      <.input field={@form[:label]} type="text" label="Label" id="invoice-line-form-label" />
      <.input
        field={@form[:amount_input]}
        type="text"
        label="Amount"
        id="invoice-line-form-amount"
        placeholder="e.g. 3.000"
      />

      <div class="flex flex-wrap items-center gap-2 pt-2">
        <.button variant="primary" id="invoice-line-form-submit">Save line</.button>
        <button
          type="button"
          id="invoice-line-form-cancel"
          phx-click="cancel_line"
          class={secondary_button_class()}
        >
          Cancel
        </button>
      </div>
    </.form>
    """
  end
end
