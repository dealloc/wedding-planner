defmodule WeddingPlanner.Valuation.CashFlow do
  @moduledoc """
  `BUD-06` cash flow: every **unpaid** invoice placed in exactly one bucket — **Overdue**,
  one bucket per due month, or **No due date** — with totals, over a
  `WeddingPlanner.Valuation.Snapshot` (`NFR-41`). Preset-independent: an invoice's total
  never depends on a headcount (`WeddingPlanner.Valuation.Invoices` moduledoc), so
  `build/2` takes no preset. Task 84 renders it; X2 (dashboard) reuses it (`DR-78`).

  ## The partition (`DR-75`)

  Paid invoices never appear (`BIL-02`, `DR-59`): `WeddingPlanner.Invoices.Invoice.paid?/1`
  filters them out before anything else. Every remaining (unpaid) invoice lands in
  **exactly one** of:

    * `overdue` — unpaid **and** overdue on `today`
      (`WeddingPlanner.Valuation.Invoices.overdue?/2`: due date set and strictly before
      `today` — due today is not overdue, `DR-59`). Overdue is its **own** bucket and
      leaves its due month entirely; it is never also counted in `months` (`BIL-06`).
    * a `months` bucket, keyed by the due date's `{year, month}` — for every unpaid,
      not-overdue invoice that has a due date. Only months that actually have an invoice
      get a bucket (no zero-amount rows for months in between); the current month's
      bucket therefore only ever holds its **not-yet-overdue** part, since anything in it
      that is already overdue was already routed to `overdue`.
    * `no_due_date` — unpaid, no due date.

  `total` is the sum of every bucket (`WeddingPlanner.Money.sum/1`) — because the three
  groups above are a partition of the unpaid invoices, this always equals `BUD-05`'s total
  Outstanding. `today` is the caller's — the date in the viewer's time zone (`NFR-22`,
  `DR-44`); this module never reads a clock.

  ## Ordering and totals

  Within `overdue` and each month bucket, invoices are sorted by due date then id; within
  `no_due_date`, by invoice date then id. `months` is ascending by `{year, month}`. An
  invoice's total is `WeddingPlanner.Valuation.Invoices.total/2` (its lines summed,
  `BIL-03`); a bucket's total is `WeddingPlanner.Money.sum/1` of its invoices' totals,
  unrounded (`NFR-14`). An empty `overdue` or `no_due_date` is `nil` rather than an empty
  bucket; `months` is `[]` when there is none. With no unpaid invoice at all, `total` is
  €0.
  """

  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Valuation.Invoices
  alias WeddingPlanner.Valuation.Snapshot

  @typedoc "One invoice with its total (`BIL-03`)."
  @type invoice_entry :: %{invoice: Invoice.t(), total: Money.t()}

  @typedoc "A non-empty group of unpaid invoices with their combined total."
  @type bucket :: %{total: Money.t(), invoices: [invoice_entry(), ...]}

  @typedoc "A `bucket/0` for one due month; `first_day` is the 1st of that month."
  @type month_bucket :: %{
          year: pos_integer(),
          month: 1..12,
          first_day: Date.t(),
          total: Money.t(),
          invoices: [invoice_entry(), ...]
        }

  @typedoc "`BUD-06`'s cash-flow partition of every unpaid invoice (see the moduledoc)."
  @type t :: %{
          overdue: bucket() | nil,
          months: [month_bucket()],
          no_due_date: bucket() | nil,
          total: Money.t()
        }

  @doc """
  Builds `t:t/0` for `snapshot` as of `today` (the viewer's date, `DR-44`): every unpaid
  invoice placed in exactly one of `overdue`, a `months` bucket, or `no_due_date` — see
  the moduledoc for the partition, ordering and totals.
  """
  @spec build(Snapshot.t(), Date.t()) :: t()
  def build(%Snapshot{invoices: invoices} = snapshot, %Date{} = today) do
    entries =
      invoices
      |> Enum.reject(&Invoices.paid?/1)
      |> Enum.map(&%{invoice: &1, total: Invoices.total(snapshot, &1)})

    {overdue_entries, unpaid_not_overdue} =
      Enum.split_with(entries, &Invoices.overdue?(&1.invoice, today))

    {no_due_entries, dated_entries} =
      Enum.split_with(unpaid_not_overdue, &is_nil(&1.invoice.due_date))

    %{
      overdue: build_bucket(overdue_entries, &sort_by_due_date/2),
      months: build_months(dated_entries),
      no_due_date: build_bucket(no_due_entries, &sort_by_invoice_date/2),
      total: WeddingPlanner.Money.sum(Enum.map(entries, & &1.total))
    }
  end

  defp build_months(entries) do
    entries
    |> Enum.group_by(fn %{invoice: invoice} ->
      {invoice.due_date.year, invoice.due_date.month}
    end)
    |> Enum.sort_by(fn {key, _entries} -> key end)
    |> Enum.map(fn {{year, month}, month_entries} ->
      sorted = Enum.sort(month_entries, &sort_by_due_date/2)

      %{
        year: year,
        month: month,
        first_day: Date.new!(year, month, 1),
        total: bucket_total(sorted),
        invoices: sorted
      }
    end)
  end

  defp build_bucket([], _comparator), do: nil

  defp build_bucket(entries, comparator) do
    sorted = Enum.sort(entries, comparator)
    %{total: bucket_total(sorted), invoices: sorted}
  end

  defp bucket_total(entries), do: WeddingPlanner.Money.sum(Enum.map(entries, & &1.total))

  # Due date then id (`DR-75`). `Date.compare/2`, never raw term comparison — a `%Date{}`'s
  # struct fields do not sort chronologically as terms.
  defp sort_by_due_date(%{invoice: a}, %{invoice: b}) do
    case Date.compare(a.due_date, b.due_date) do
      :lt -> true
      :gt -> false
      :eq -> a.id <= b.id
    end
  end

  # Invoice date then id, for `no_due_date` (`DR-75`).
  defp sort_by_invoice_date(%{invoice: a}, %{invoice: b}) do
    case Date.compare(a.invoice_date, b.invoice_date) do
      :lt -> true
      :gt -> false
      :eq -> a.id <= b.id
    end
  end
end
