defmodule WeddingPlannerWeb.Live.InvoicesLive do
  @moduledoc """
  The invoices list (task 69; `/invoices`, `DR-59`): every invoice as a phone-friendly
  card, overdue unpaid ones highlighted wherever invoices are listed (`BIL-06`), plus the
  new-invoice form.

  ## Order (`DR-59`)

  Overdue first (oldest due date first), then other unpaid invoices by due date (no due
  date last), then paid invoices behind a `<details>` "Paid (N)" disclosure (newest paid
  first). Two fixed streams — `:invoices_unpaid` and `:invoices_paid` — since streams
  cannot be filtered or reordered in place (`AGENTS.md`); `refresh/1` refetches and resets
  both on every relevant broadcast or local mutation. `@paid_count` is a plain assign
  (streams cannot be counted).

  Every figure (a total, paid, overdue) comes from `WeddingPlanner.Valuation.Invoices`
  over a freshly loaded `WeddingPlanner.Valuation.Snapshot` — nothing here re-derives a
  sum or an overdue check. "Today" is `WeddingPlanner.Tasks.TodoList.today(@time_zone)`
  (`on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}`), never `Date.utc_today/0`.

  ## Filters live in the URL (`DR-44`)

  `?filter[category_id]=<id>&filter[paid]=unpaid|paid` — parsed/applied in
  `handle_params/3` (never `mount/3`, the `WeddingPlannerWeb.Live.TasksLive` precedent),
  round-tripped by `parse_filters/1`/`invoices_path/1`, changed only via `push_patch`
  (`#invoices-filter-form`, a `phx-change` sibling form, never a bare select).

  ## `?category=<id>` opens the new-invoice form (`DR-59`)

  A **separate**, unnested top-level `category` param (never confused with the
  `filter[...]` params above) is task 70's link from the category page: present on a
  navigation whose value hasn't already been consumed, it opens the collapsed
  new-invoice form (`@adding`) with that category preselected. `@prefilled_category_param`
  remembers which value was last consumed so a later filter-only `push_patch` (which
  never carries `category`) neither reopens nor closes the form — `@adding` is otherwise a
  plain transient assign the "+ Add invoice" toggle and the form's own Cancel button
  flip directly.

  ## New-invoice form (`DR-58`, `DR-59`, `DR-23`)

  Two independent changesets/forms share one physical `<form id="invoice-new-form">`:
  `@new_invoice_form` (`WeddingPlanner.Invoices.change_invoice/2`, plus a required check
  on `category_id` this context deliberately leaves to callers that ask for it as a
  form field — normally it arrives already set from a parent struct) and
  `@new_line_form` (`WeddingPlanner.Invoices.change_line/2`). Both are recomputed
  independently on every `validate_new`/`create_new`, never by parsing
  `WeddingPlanner.Invoices.create_invoice/4`'s own merged-changeset error path (that
  path exists so *that* function's caller can render one form from one changeset; this
  module already has two, so it validates both itself and only calls `create_invoice/4`
  once both are locally valid). The offer-link select lists the **confirmed** offers of
  whichever category is currently selected in the (unsaved) form — in W10 there are none
  yet, so it renders disabled with "Only confirmed offers can be linked" (`DR-58`).
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.Components.ExportComponents, only: [export_link: 1]

  alias WeddingPlanner.Categories
  alias WeddingPlanner.Invoices
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Invoices.InvoiceLine
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Tasks.TodoList
  alias WeddingPlanner.Valuation.Invoices, as: InvoiceValuation
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Format

  on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Realtime.subscribe(:invoice)
      Realtime.subscribe(:invoice_line)
      Realtime.subscribe(:category)
      Realtime.subscribe(:offer)
    end

    socket =
      socket
      |> assign(:page_title, "Invoices")
      |> assign(:categories, Categories.list_categories())
      |> assign(:adding, false)
      |> assign(:new_invoice_form, nil)
      |> assign(:new_line_form, nil)
      |> assign(:prefilled_category_param, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = parse_filters(params)

    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:filter_form, filter_form(filters))
      |> refresh()
      |> maybe_open_add_form(params["category"])

    {:noreply, socket}
  end

  # -- filters (DR-44) ---------------------------------------------------------------

  @impl true
  def handle_event("filter_change", %{"filter" => filter_params}, socket) do
    filters = %{
      category_id: blank_to_nil(filter_params["category_id"]),
      paid: parse_paid(filter_params["paid"])
    }

    {:noreply, push_patch(socket, to: invoices_path(filters))}
  end

  # -- new invoice (DR-58, DR-59, DR-23) ----------------------------------------------

  def handle_event("toggle_add", _params, socket) do
    if socket.assigns.adding do
      {:noreply, close_add_form(socket)}
    else
      {:noreply, open_add_form(socket, nil)}
    end
  end

  def handle_event("cancel_add", _params, socket), do: {:noreply, close_add_form(socket)}

  def handle_event(
        "validate_new",
        %{"invoice" => invoice_params, "line" => line_params},
        socket
      ) do
    {:noreply, assign_new_forms(socket, invoice_params, line_params)}
  end

  def handle_event("create_new", %{"invoice" => invoice_params, "line" => line_params}, socket) do
    scope = socket.assigns.current_scope
    category = find_category(socket.assigns.categories, invoice_params["category_id"])
    invoice_changeset = new_invoice_changeset(invoice_params, category)

    line_changeset =
      Invoices.change_line(%InvoiceLine{}, line_params) |> Map.put(:action, :validate)

    if (category && invoice_changeset.valid?) and line_changeset.valid? do
      case Invoices.create_invoice(scope, category, invoice_params, line_params) do
        {:ok, invoice} ->
          {:noreply, push_navigate(socket, to: ~p"/invoices/#{invoice.id}")}

        {:error, changeset} ->
          {:noreply, assign(socket, :new_invoice_form, to_form(changeset, as: :invoice))}
      end
    else
      {:noreply,
       socket
       |> assign(:new_invoice_form, to_form(invoice_changeset, as: :invoice))
       |> assign(:new_line_form, to_form(line_changeset, as: :line))}
    end
  end

  # -- live updates (XC-01, XC-02) -----------------------------------------------------

  @impl true
  def handle_info({Realtime, :invoice, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :invoice_line, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({Realtime, :offer, _event}, socket), do: {:noreply, refresh(socket)}

  def handle_info({Realtime, :category, _event}, socket) do
    {:noreply, socket |> assign(:categories, Categories.list_categories()) |> refresh()}
  end

  # -- helpers: filters (DR-44) --------------------------------------------------------

  defp parse_filters(params) do
    %{
      category_id: blank_to_nil(params["filter_category"]),
      paid: parse_paid(params["filter_paid"])
    }
  end

  defp parse_paid("paid"), do: :paid
  defp parse_paid("unpaid"), do: :unpaid
  defp parse_paid(_other), do: :all

  defp filter_form(filters) do
    to_form(
      %{"category_id" => filters.category_id || "", "paid" => paid_select_value(filters.paid)},
      as: :filter
    )
  end

  defp paid_select_value(:all), do: ""
  defp paid_select_value(:paid), do: "paid"
  defp paid_select_value(:unpaid), do: "unpaid"

  defp invoices_path(filters) do
    query =
      %{}
      |> maybe_put("filter_category", filters.category_id)
      |> maybe_put("filter_paid", nil_if_all(filters.paid))

    if query == %{}, do: ~p"/invoices", else: ~p"/invoices?#{query}"
  end

  defp nil_if_all(:all), do: nil
  defp nil_if_all(other), do: paid_select_value(other)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # -- helpers: refresh (small dataset, full refetch — CategoryLive precedent) --------

  defp refresh(socket) do
    snapshot = Snapshot.load(WeddingPlanner.Repo)
    today = TodoList.today(socket.assigns.time_zone)

    invoices =
      Invoices.list_invoices()
      |> Repo.preload([:category, :offer])
      |> filter_invoices(socket.assigns.filters)

    {paid, unpaid} = Enum.split_with(invoices, &InvoiceValuation.paid?/1)
    paid_sorted = sort_paid(paid)

    socket
    |> assign(:snapshot, snapshot)
    |> assign(:today, today)
    |> assign(:paid_count, length(paid_sorted))
    |> stream(:invoices_unpaid, sort_unpaid(unpaid, today),
      reset: true,
      dom_id: &"invoice-row-#{&1.id}"
    )
    |> stream(:invoices_paid, paid_sorted, reset: true, dom_id: &"invoice-row-#{&1.id}")
  end

  defp filter_invoices(invoices, filters) do
    invoices
    |> filter_by_category(filters.category_id)
    |> filter_by_paid(filters.paid)
  end

  defp filter_by_category(invoices, nil), do: invoices

  defp filter_by_category(invoices, category_id) do
    Enum.filter(invoices, &(to_string(&1.category_id) == category_id))
  end

  defp filter_by_paid(invoices, :all), do: invoices
  defp filter_by_paid(invoices, :paid), do: Enum.filter(invoices, &InvoiceValuation.paid?/1)
  defp filter_by_paid(invoices, :unpaid), do: Enum.reject(invoices, &InvoiceValuation.paid?/1)

  # Overdue (oldest due first), then the rest by due date (no due date last). An
  # overdue invoice always has a due date (`Valuation.Invoices.overdue?/2`), so only the
  # second bucket needs the "no due date last" split.
  defp sort_unpaid(invoices, today) do
    {overdue, rest} = Enum.split_with(invoices, &InvoiceValuation.overdue?(&1, today))
    {with_due, without_due} = Enum.split_with(rest, & &1.due_date)

    Enum.sort_by(overdue, & &1.due_date, {:asc, Date}) ++
      Enum.sort_by(with_due, & &1.due_date, {:asc, Date}) ++ without_due
  end

  defp sort_paid(invoices), do: Enum.sort_by(invoices, & &1.paid_on, {:desc, Date})

  # -- helpers: new-invoice form --------------------------------------------------------

  defp maybe_open_add_form(socket, nil), do: socket

  defp maybe_open_add_form(socket, category_param) do
    if socket.assigns.prefilled_category_param == category_param do
      socket
    else
      socket
      |> assign(:prefilled_category_param, category_param)
      |> open_add_form(category_param)
    end
  end

  defp open_add_form(socket, category_id) do
    attrs = if blank?(category_id), do: %{}, else: %{"category_id" => category_id}

    changeset =
      %Invoice{}
      |> Invoices.change_invoice(attrs)
      |> Ecto.Changeset.put_change(:invoice_date, TodoList.today(socket.assigns.time_zone))

    socket
    |> assign(:adding, true)
    |> assign(:new_invoice_form, to_form(changeset, as: :invoice))
    |> assign(:new_line_form, to_form(Invoices.change_line(%InvoiceLine{}, %{}), as: :line))
  end

  defp close_add_form(socket) do
    socket
    |> assign(:adding, false)
    |> assign(:new_invoice_form, nil)
    |> assign(:new_line_form, nil)
  end

  defp assign_new_forms(socket, invoice_params, line_params) do
    category = find_category(socket.assigns.categories, invoice_params["category_id"])
    invoice_changeset = new_invoice_changeset(invoice_params, category)

    line_changeset =
      Invoices.change_line(%InvoiceLine{}, line_params) |> Map.put(:action, :validate)

    socket
    |> assign(:new_invoice_form, to_form(invoice_changeset, as: :invoice))
    |> assign(:new_line_form, to_form(line_changeset, as: :line))
  end

  # `%Invoice{category_id: ...}` is preset to the *resolved* category's own id (the
  # `WeddingPlanner.Invoices.create_invoice/4` base struct shape) before `attrs` is cast
  # — otherwise casting the very same category id from a bare `%Invoice{}` (nil ->
  # category id) registers as a *change*, which combined with a chosen `offer_id`
  # spuriously trips `Invoice.changeset/2`'s "category locked while linked" rule that
  # is meant only for an *existing*, already-linked invoice.
  defp new_invoice_changeset(invoice_params, category) do
    base = %Invoice{category_id: category && category.id}
    changeset = base |> Invoices.change_invoice(invoice_params) |> Map.put(:action, :validate)

    if blank?(invoice_params["category_id"]) do
      Ecto.Changeset.add_error(changeset, :category_id, "can't be blank", validation: :required)
    else
      changeset
    end
  end

  defp find_category(categories, id),
    do: Enum.find(categories, &(to_string(&1.id) == to_string(id)))

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

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_other), do: false

  defp invoice_subtitle(%Invoice{category: category, offer: nil}), do: category.name

  defp invoice_subtitle(%Invoice{category: category, offer: %{vendor_name: vendor}}),
    do: "#{category.name} · #{vendor}"

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
      <WeddingPlannerWeb.Live.TimeZoneHook.probe id="invoices-time-zone-probe" />

      <.header>
        Invoices
        <:actions>
          <.button id="invoice-new-toggle" phx-click="toggle_add">
            {if @adding, do: "Cancel", else: "+ Add invoice"}
          </.button>
          <.export_link kind="invoices" time_zone={@time_zone} />
        </:actions>
      </.header>

      <.form
        for={@filter_form}
        id="invoices-filter-form"
        phx-change="filter_change"
        class="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2"
      >
        <.input
          type="select"
          id="invoices-filter-category"
          name="filter[category_id]"
          label="Category"
          value={@filter_form[:category_id].value}
          prompt="All categories"
          options={Enum.map(@categories, &{&1.name, &1.id})}
        />
        <.input
          type="select"
          id="invoices-filter-paid"
          name="filter[paid]"
          label="Status"
          value={@filter_form[:paid].value}
          options={[{"All", ""}, {"Unpaid", "unpaid"}, {"Paid", "paid"}]}
        />
      </.form>

      <div :if={@adding} class="mt-4 rounded-field border border-line bg-surface-raised p-4">
        <.form
          for={@new_invoice_form}
          id="invoice-new-form"
          phx-change="validate_new"
          phx-submit="create_new"
          class="space-y-4"
        >
          <.input
            field={@new_invoice_form[:category_id]}
            type="select"
            label="Category"
            id="invoice-new-category"
            prompt="Choose a category"
            options={Enum.map(@categories, &{&1.name, &1.id})}
          />

          <.input
            field={@new_invoice_form[:label]}
            type="text"
            label="Label"
            id="invoice-new-label"
            placeholder="e.g. Venue deposit"
          />

          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <.input
              field={@new_invoice_form[:invoice_date]}
              type="date"
              label="Invoice date"
              id="invoice-new-invoice-date"
            />
            <.input
              field={@new_invoice_form[:due_date]}
              type="date"
              label="Due date (optional)"
              id="invoice-new-due-date"
            />
          </div>

          <div>
            <.input
              field={@new_invoice_form[:offer_id]}
              type="select"
              label="Linked offer"
              id="invoice-new-offer"
              prompt="No offer"
              disabled={confirmed_offers_for(@new_invoice_form[:category_id].value) == []}
              options={
                Enum.map(
                  confirmed_offers_for(@new_invoice_form[:category_id].value),
                  &{&1.vendor_name, &1.id}
                )
              }
            />
            <p
              :if={confirmed_offers_for(@new_invoice_form[:category_id].value) == []}
              class="mt-1 text-xs text-ink-faint"
            >
              Only confirmed offers can be linked
            </p>
          </div>

          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <.input
              field={@new_line_form[:label]}
              type="text"
              label="First line label"
              id="invoice-new-line-label"
              placeholder="e.g. Deposit"
            />
            <.input
              field={@new_line_form[:amount_input]}
              type="text"
              label="Amount"
              id="invoice-new-line-amount"
              placeholder="e.g. 3.000"
            />
          </div>

          <div class="flex flex-wrap items-center gap-2 pt-2">
            <.button variant="primary" id="invoice-new-submit">Add invoice</.button>
            <button
              type="button"
              id="invoice-new-cancel"
              phx-click="cancel_add"
              class={secondary_button_class()}
            >
              Cancel
            </button>
          </div>
        </.form>
      </div>

      <ul id="invoices-list" phx-update="stream" class="mt-6 space-y-3">
        <li
          id="invoices-list-empty"
          class="hidden rounded-field border border-dashed border-line-strong p-4 text-center text-sm text-ink-faint only:block"
        >
          No invoices yet
        </li>
        <li :for={{dom_id, invoice} <- @streams.invoices_unpaid} id={dom_id}>
          <.invoice_row invoice={invoice} snapshot={@snapshot} today={@today} />
        </li>
      </ul>

      <details id="invoices-paid" class="mt-6">
        <summary class="cursor-pointer text-sm font-medium text-ink-soft">
          Paid ({@paid_count})
        </summary>
        <ul id="invoices-paid-list" phx-update="stream" class="mt-3 space-y-3">
          <li :for={{dom_id, invoice} <- @streams.invoices_paid} id={dom_id}>
            <.invoice_row invoice={invoice} snapshot={@snapshot} today={@today} />
          </li>
        </ul>
      </details>
    </Layouts.app>
    """
  end

  attr :invoice, :any, required: true
  attr :snapshot, :any, required: true
  attr :today, :any, required: true

  defp invoice_row(assigns) do
    assigns =
      assigns
      |> assign(:total, InvoiceValuation.total(assigns.snapshot, assigns.invoice))
      |> assign(:overdue?, InvoiceValuation.overdue?(assigns.invoice, assigns.today))
      |> assign(:paid?, InvoiceValuation.paid?(assigns.invoice))

    ~H"""
    <div class="rounded-field border border-line bg-surface-raised p-4">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <.link
            navigate={~p"/invoices/#{@invoice.id}"}
            id={"invoice-row-#{@invoice.id}-link"}
            class="font-medium text-ink hover:underline"
          >
            {@invoice.label}
          </.link>
          <p class="text-sm text-ink-soft">{invoice_subtitle(@invoice)}</p>
          <p class="text-xs text-ink-faint">Invoiced {Format.date(@invoice.invoice_date)}</p>
        </div>

        <div class="shrink-0 text-right">
          <p class="font-semibold text-ink">{Format.money(@total)}</p>
          <p class={["text-sm", @overdue? && "text-bad"]}>
            {if @invoice.due_date, do: "Due #{Format.date(@invoice.due_date)}", else: "No due date"}
          </p>
        </div>
      </div>

      <div class="mt-2 flex flex-wrap gap-2">
        <.status_pill
          :if={@overdue?}
          id={"invoice-row-#{@invoice.id}-overdue"}
          label="Overdue"
          tone={:bad}
        />
        <.status_pill :if={@paid?} id={"invoice-row-#{@invoice.id}-paid"} label="Paid" tone={:good} />
        <.status_pill
          :if={!@paid? and !@overdue?}
          id={"invoice-row-#{@invoice.id}-unpaid"}
          label="Unpaid"
          tone={:neutral}
        />
      </div>
    </div>
    """
  end
end
