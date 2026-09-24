defmodule WeddingPlanner.Valuation.Invoices do
  @moduledoc """
  The invoice figures engine (`docs/modules/invoices-and-budget.md`): every figure the
  invoice screens show, and the budget engine (slice B3) reuses, as pure functions over a
  `WeddingPlanner.Valuation.Snapshot` (`NFR-41`) — an invoice's total, an offer's
  invoiced / paid / outstanding, whether an invoice is overdue, and `BIL-07`'s variance.

  Everything is read from the snapshot's `invoices` and `invoice_lines`, joined by id with
  `==` (ids may be `make_ref/0` values in a what-if). Nothing here touches the database
  or the web layer, and nothing rounds (`NFR-14`): all arithmetic goes through
  `WeddingPlanner.Money` (`NFR-12`, `DR-18`).

  ## Amounts are static (`BIL-03`)

  An invoice's total is the sum of its lines' amounts — static, VAT inclusive, entered
  already rounded (`DR-59`). It never depends on a headcount, so nothing here but
  `variance/3` takes a preset.

  ## Paid and overdue (`BIL-02`, `BIL-06`, `DR-59`, `DR-44`)

  Paid is derived: an invoice is paid iff its `paid_on` is set
  (`WeddingPlanner.Invoices.Invoice.paid?/1`, the single implementation). Overdue is
  **not paid ∧ due date set ∧ due date strictly before `today`** — an invoice due today is
  not overdue yet. `today` is the caller's: the date in the viewer's time zone
  (`NFR-22`, `DR-44`), never read from a clock here.

  ## An offer's figures (`BUD-02`)

  Over the invoices **linked to the offer** (`for_offer/2`): Invoiced = the sum of their
  totals; Paid = the sum of the paid ones' totals; Outstanding = Invoiced − Paid.

  ## Variance (`BIL-07`, `DR-58`)

  For a **confirmed** offer only (anything else is `:not_confirmed`): its committed total
  under the chosen preset — `WeddingPlanner.Valuation.Offer.total/3`, the same call the
  budget's Committed layer makes (C5 later freezes a confirmed offer's selection behind
  it, `DR-49`) — against its invoiced total. `BIL-07` fixes no sign convention, so the
  result is a **magnitude plus a direction**, as `docs/07-normative-examples.md` words B1
  and B2:

    * committed > invoiced → `:not_yet_invoiced`, amount = committed − invoiced (B1);
    * committed < invoiced → `:above_committed`, amount = invoiced − committed (B2);
    * equal → `:matches`, amount €0.

  The amount is never negative. *Invoicing complete* (`BIL-05`) does not change it — that
  flag only matters to `BUD-03`'s forecast (slice B3). Whether to show a variance for a
  confirmed offer that has no invoices yet is the web layer's call (`BIL-07` asks for it
  "for an offer with invoices"); this function computes it regardless.

  The formula (`BUD-08`, `CST-34`) is labelled `"Variance"`: the committed formula's
  `{:preset, name}` step (present exactly when the committed total depends on the preset,
  `DR-50`), `"Committed"` → the committed total, one step per linked invoice (its label →
  its total, in `snapshot.invoices` order), `"Invoiced"` → their sum; total
  `{:money, amount}`. Wording the direction ("not yet invoiced", "above committed") is
  the web layer's.
  """

  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Offers
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Formula.Step
  alias WeddingPlanner.Valuation.Offer
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Snapshot

  @typedoc "An offer's `BUD-02` invoice layers: `outstanding == invoiced − paid`."
  @type offer_figures :: %{invoiced: Money.t(), paid: Money.t(), outstanding: Money.t()}

  @typedoc "Which side of the committed total the invoiced total is on (`BIL-07`)."
  @type direction :: :not_yet_invoiced | :above_committed | :matches

  @typedoc """
  `BIL-07`'s variance of a confirmed offer: `committed` is `Offer.total/3`'s formula,
  `invoiced` the sum of the offer's invoices, `amount` the (never negative) difference and
  `direction` which way it goes; `formula` expands it (see the moduledoc).
  """
  @type variance :: %{
          committed: Formula.t(),
          invoiced: Money.t(),
          amount: Money.t(),
          direction: direction(),
          formula: Formula.t()
        }

  @doc """
  The total of `invoice` (an invoice from `snapshot.invoices`): the sum of its lines in
  `snapshot.invoice_lines` (`BIL-03`). €0 for an invoice with no line — impossible for
  loaded data (`DR-59`: at least one line), but defined.
  """
  @spec total(Snapshot.t(), Invoice.t()) :: Money.t()
  def total(%Snapshot{invoice_lines: lines}, %Invoice{id: id}) do
    lines
    |> Enum.filter(&(&1.invoice_id == id))
    |> Enum.map(& &1.amount)
    |> WeddingPlanner.Money.sum()
  end

  @doc "Whether `invoice` is paid — its `paid_on` is set (`BIL-02`, `DR-59`)."
  @spec paid?(Invoice.t()) :: boolean()
  def paid?(%Invoice{} = invoice), do: Invoice.paid?(invoice)

  @doc """
  Whether `invoice` is overdue on `today` (the date in the viewer's zone, `DR-44`): not
  paid, a due date set, and that due date strictly before `today` (`BIL-06`, `DR-59`).
  """
  @spec overdue?(Invoice.t(), Date.t()) :: boolean()
  def overdue?(%Invoice{due_date: nil}, %Date{}), do: false

  def overdue?(%Invoice{due_date: %Date{} = due_date} = invoice, %Date{} = today) do
    not paid?(invoice) and Date.compare(due_date, today) == :lt
  end

  @doc "The invoices linked to `offer` (`BIL-04`), by id, in `snapshot.invoices` order."
  @spec for_offer(Snapshot.t(), Offers.Offer.t()) :: [Invoice.t()]
  def for_offer(%Snapshot{invoices: invoices}, %Offers.Offer{id: offer_id}) do
    Enum.filter(invoices, &(&1.offer_id == offer_id))
  end

  @doc """
  `offer`'s invoice layers (`BUD-02`) over its linked invoices: Invoiced (all of them),
  Paid (the paid ones) and Outstanding = Invoiced − Paid.
  """
  @spec offer_figures(Snapshot.t(), Offers.Offer.t()) :: offer_figures()
  def offer_figures(%Snapshot{} = snapshot, %Offers.Offer{} = offer) do
    totals = linked_totals(snapshot, offer)
    invoiced = invoiced(totals)
    paid = totals |> Enum.filter(fn {invoice, _total} -> paid?(invoice) end) |> sum_totals()

    %{invoiced: invoiced, paid: paid, outstanding: WeddingPlanner.Money.subtract(invoiced, paid)}
  end

  @doc """
  `BIL-07`'s variance of `offer` (an offer from `snapshot.offers`) under `preset`: its
  committed total against its invoiced total, as a magnitude and a direction with its
  formula — or `:not_confirmed` unless the offer is confirmed (`DR-58`). See the
  moduledoc.
  """
  @spec variance(Snapshot.t(), Offers.Offer.t(), Preset.t()) :: variance() | :not_confirmed
  def variance(%Snapshot{}, %Offers.Offer{status: status}, %Preset{}) when status != :confirmed,
    do: :not_confirmed

  def variance(%Snapshot{} = snapshot, %Offers.Offer{} = offer, %Preset{} = preset) do
    %Formula{total: {:money, committed}} =
      committed_formula = Offer.total(snapshot, offer, preset)

    invoice_totals = linked_totals(snapshot, offer)
    invoiced = invoiced(invoice_totals)

    {amount, direction} =
      case WeddingPlanner.Money.compare(committed, invoiced) do
        :gt -> {WeddingPlanner.Money.subtract(committed, invoiced), :not_yet_invoiced}
        :lt -> {WeddingPlanner.Money.subtract(invoiced, committed), :above_committed}
        :eq -> {WeddingPlanner.Money.new(0, committed.currency), :matches}
      end

    preset_steps = Enum.filter(committed_formula.steps, &match?(%Step{value: {:preset, _}}, &1))

    invoice_steps =
      Enum.map(invoice_totals, fn {invoice, total} ->
        %Step{label: invoice.label, value: {:money, total}}
      end)

    formula = %Formula{
      label: "Variance",
      steps:
        preset_steps ++
          [%Step{label: "Committed", value: {:money, committed}}] ++
          invoice_steps ++
          [%Step{label: "Invoiced", value: {:money, invoiced}}],
      total: {:money, amount}
    }

    %{
      committed: committed_formula,
      invoiced: invoiced,
      amount: amount,
      direction: direction,
      formula: formula
    }
  end

  # The offer's linked invoices, each with its total, in `snapshot.invoices` order.
  defp linked_totals(snapshot, offer) do
    snapshot |> for_offer(offer) |> Enum.map(&{&1, total(snapshot, &1)})
  end

  # BUD-02's Invoiced: every linked invoice, paid or not — the one place both
  # `offer_figures/2` and `variance/3` take it from.
  defp invoiced(totals), do: sum_totals(totals)

  defp sum_totals(totals), do: totals |> Enum.map(&elem(&1, 1)) |> WeddingPlanner.Money.sum()
end
