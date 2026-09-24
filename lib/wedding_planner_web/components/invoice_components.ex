defmodule WeddingPlannerWeb.Components.InvoiceComponents do
  @moduledoc """
  The invoice row shared by the category page's Invoices section and the offer page's
  Invoices section (task 70; `docs/modules/invoices-and-budget.md` `BIL-06`) — the same
  row shape `WeddingPlannerWeb.Live.InvoicesLive` (task 69) already renders, reused
  rather than reinvented: label linking to `/invoices/:id`, invoice date, due date,
  total, and a paid/overdue/unpaid pill (`DR-59`'s tones — overdue bad, paid good,
  unpaid neutral). Every figure comes from `WeddingPlanner.Valuation.Invoices` over the
  caller's own freshly loaded snapshot — nothing here re-derives a sum or an overdue
  check (`NFR-41`).

  Also carries the offer page's variance panel (`variance_panel/1`; `BIL-07`, `DR-58`) —
  wording per `docs/07-normative-examples.md`'s B1/B2 (a magnitude plus a direction, no
  fixed sign convention), captioned with the preset it was computed under (the offer
  page's own Cost card chip, never a second selector, `HC-10`) and its formula expanded
  through the existing `WeddingPlannerWeb.DisplayComponents.formula/1` +
  `WeddingPlannerWeb.FormulaPresenter` (`BUD-08`, `NFR-32`) — this module adds no new
  formula rendering of its own.
  """
  use WeddingPlannerWeb, :html

  alias WeddingPlanner.Valuation.Invoices, as: InvoiceValuation
  alias WeddingPlannerWeb.Format
  alias WeddingPlannerWeb.FormulaPresenter

  @doc """
  One invoice row: label (linking to its own page), invoice date, due date, total, and
  a paid/overdue/unpaid pill.

  `:id` is the row's own dom id (the caller derives it, e.g.
  `"category-invoice-\#{invoice.id}"` or `"offer-invoice-\#{invoice.id}"`); the
  overdue/paid/unpaid pills are `"\#{id}-overdue"` / `"\#{id}-paid"` / `"\#{id}-unpaid"`,
  so a caller-required selector such as `#category-invoice-\#{id}-overdue` (`BIL-06`) is
  always exactly that.

  `:show_offer?` (default `true`) additionally shows the linked offer's vendor name
  beside the invoice date, for a context (the category page) that does not already show
  it elsewhere; the offer page passes `false` since the offer *is* the page.
  """
  attr :id, :string, required: true
  attr :invoice, :any, required: true
  attr :snapshot, :any, required: true
  attr :today, :any, required: true
  attr :show_offer?, :boolean, default: true

  def invoice_row(assigns) do
    assigns =
      assigns
      |> assign(:total, InvoiceValuation.total(assigns.snapshot, assigns.invoice))
      |> assign(:overdue?, InvoiceValuation.overdue?(assigns.invoice, assigns.today))
      |> assign(:paid?, InvoiceValuation.paid?(assigns.invoice))

    ~H"""
    <div id={@id} class="rounded-field border border-line bg-surface-raised p-4">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <.link
            navigate={~p"/invoices/#{@invoice.id}"}
            id={"#{@id}-link"}
            class="font-medium text-ink hover:underline"
          >
            {@invoice.label}
          </.link>
          <p :if={@show_offer? and @invoice.offer} class="text-sm text-ink-soft">
            {@invoice.offer.vendor_name}
          </p>
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
        <.status_pill :if={@overdue?} id={"#{@id}-overdue"} label="Overdue" tone={:bad} />
        <.status_pill :if={@paid?} id={"#{@id}-paid"} label="Paid" tone={:good} />
        <.status_pill
          :if={!@paid? and !@overdue?}
          id={"#{@id}-unpaid"}
          label="Unpaid"
          tone={:neutral}
        />
      </div>
    </div>
    """
  end

  @doc """
  The offer page's variance panel (`BIL-07`, `DR-58`): the direction-worded figure
  (`docs/07-normative-examples.md` B1 "€ 8.726,00 not yet invoiced", B2 "+€ 174,00 above
  committed", or "Invoiced matches committed" when they're equal), captioned with the
  preset it was computed under, and its formula expanded through the existing
  `formula/1` (`BUD-08`, `NFR-32`).

  `:variance` is `WeddingPlanner.Valuation.Invoices.variance/3`'s result — the caller
  only renders this panel when it has one (never `:not_confirmed`, and never for a
  confirmed offer with no invoices yet, `BIL-07` "for an offer with invoices" — both are
  the caller's own gate, not this component's).
  """
  attr :id, :string, default: "offer-variance"
  attr :variance, :map, required: true
  attr :preset_name, :string, required: true

  def variance_panel(assigns) do
    ~H"""
    <div id={@id} class="rounded-field border border-line bg-surface-raised p-4">
      <p class="text-xs font-medium tracking-wide text-ink-soft uppercase">
        Variance — under {@preset_name}
      </p>
      <p id={"#{@id}-amount"} class="mt-1 text-lg font-semibold text-ink">
        {variance_text(@variance)}
      </p>
    </div>

    <.formula id="offer-variance-formula" {FormulaPresenter.present(@variance.formula)} />
    """
  end

  defp variance_text(%{direction: :matches}), do: "Invoiced matches committed"

  defp variance_text(%{direction: :not_yet_invoiced, amount: amount}),
    do: "#{Format.money(amount)} not yet invoiced"

  defp variance_text(%{direction: :above_committed, amount: amount}),
    do: "+#{Format.money(amount)} above committed"
end
