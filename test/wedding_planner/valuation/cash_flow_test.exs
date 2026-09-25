defmodule WeddingPlanner.Valuation.CashFlowTest do
  @moduledoc """
  `WeddingPlanner.Valuation.CashFlow` — `BUD-06`'s cash-flow partition of unpaid invoices
  (`DR-75`) over in-memory snapshots: buckets, ordering, totals (`BUD-05`, `BIL-03`), the
  empty case, and a partition property test.

  The property test compares the engine against an oracle written here in exact integer
  cents, which shares no code with `CashFlow` (`NFR-12` governs production arithmetic, not
  test oracles): it tracks each generated invoice's paid flag, its due date and invoice
  date as day offsets from `today`, and its line total in integer cents, then rebuilds the
  expected partition with plain `Date`/`Enum` arithmetic.
  """
  use ExUnit.Case, async: true

  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Invoices.InvoiceLine
  alias WeddingPlanner.Valuation.CashFlow
  alias WeddingPlanner.Valuation.Snapshot

  # -- helpers ---------------------------------------------------------------------------------

  defp eur(amount), do: WeddingPlanner.Money.new(amount)

  defp assert_money(actual, expected, what) do
    assert Money.equal?(actual, expected),
           "#{what}: expected #{Money.to_string!(expected)}, got #{Money.to_string!(actual)}"
  end

  defp invoice(id, attrs) do
    struct!(
      %Invoice{
        id: id,
        label: "Invoice #{id}",
        invoice_date: ~D[2026-01-01],
        due_date: nil,
        paid_on: nil
      },
      attrs
    )
  end

  # Builds an in-memory snapshot from `{invoice, [line amounts]}` pairs — each amount
  # becomes one line on that invoice.
  defp snapshot(invoice_specs) do
    {invoices, lines} =
      invoice_specs
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {{invoice, amounts}, spec_index}, {invoices, lines} ->
        new_lines =
          amounts
          |> Enum.with_index()
          |> Enum.map(fn {amount, line_index} ->
            %InvoiceLine{
              id: spec_index * 100 + line_index + 1,
              invoice_id: invoice.id,
              label: "Line",
              amount: amount
            }
          end)

        {invoices ++ [invoice], lines ++ new_lines}
      end)

    %Snapshot{invoices: invoices, invoice_lines: lines}
  end

  defp bucket_ids(nil), do: []
  defp bucket_ids(%{invoices: invoices}), do: Enum.map(invoices, & &1.invoice.id)

  # -- buckets (DR-75) --------------------------------------------------------------------------

  describe "buckets (DR-75)" do
    @today ~D[2026-10-15]

    test "an unpaid invoice due before today is overdue, its own bucket" do
      snap = snapshot([{invoice(1, due_date: ~D[2026-10-14]), [eur(100)]}])

      result = CashFlow.build(snap, @today)

      assert bucket_ids(result.overdue) == [1]
      assert result.months == []
      assert result.no_due_date == nil
    end

    # FP-79b: `Date.compare(due, today) != :gt` would put this invoice in `overdue` too.
    test "an unpaid invoice due today is not overdue — it lands in this month's bucket" do
      snap = snapshot([{invoice(1, due_date: ~D[2026-10-15]), [eur(100)]}])

      result = CashFlow.build(snap, @today)

      assert result.overdue == nil
      assert [%{year: 2026, month: 10, first_day: ~D[2026-10-01]} = month] = result.months
      assert bucket_ids(month) == [1]
    end

    test "a due date later in the same month lands in the same month bucket" do
      snap =
        snapshot([
          {invoice(1, due_date: ~D[2026-10-15]), [eur(100)]},
          {invoice(2, due_date: ~D[2026-10-31]), [eur(50)]}
        ])

      result = CashFlow.build(snap, @today)

      assert [%{year: 2026, month: 10} = month] = result.months
      assert bucket_ids(month) == [1, 2]
    end

    # FP-79d: emitting a bucket for every month in between would put empty Nov/Dec rows here.
    test "a due date months away gets its own bucket with no zero-row months in between" do
      snap =
        snapshot([
          {invoice(1, due_date: ~D[2026-10-20]), [eur(50)]},
          {invoice(2, due_date: ~D[2027-01-02]), [eur(100)]}
        ])

      result = CashFlow.build(snap, @today)

      assert Enum.map(result.months, &{&1.year, &1.month}) == [{2026, 10}, {2027, 1}]
    end

    test "an unpaid invoice with no due date is in no_due_date" do
      snap = snapshot([{invoice(1, due_date: nil), [eur(100)]}])

      result = CashFlow.build(snap, @today)

      assert bucket_ids(result.no_due_date) == [1]
      assert result.overdue == nil
      assert result.months == []
    end

    # FP-79c: dropping the `paid?` filter would surface this invoice in `overdue`.
    test "a paid invoice never appears, even with a past due date" do
      snap =
        snapshot([
          {invoice(1, due_date: ~D[2026-10-14], paid_on: ~D[2026-10-01]), [eur(100)]}
        ])

      result = CashFlow.build(snap, @today)

      assert result.overdue == nil
      assert result.months == []
      assert result.no_due_date == nil
      assert_money(result.total, eur(0), "total")
    end

    # FP-79a: also placing the overdue invoice in its due month would show it in both
    # `overdue` and `months`.
    test "an overdue invoice never also appears in its due month's bucket" do
      snap = snapshot([{invoice(1, due_date: ~D[2026-10-14]), [eur(100)]}])

      result = CashFlow.build(snap, @today)

      assert bucket_ids(result.overdue) == [1]
      assert result.months == []
    end
  end

  # -- ordering (DR-75) -------------------------------------------------------------------------

  describe "ordering (DR-75)" do
    @today ~D[2026-10-15]

    test "within a bucket, sorted by due date then id" do
      snap =
        snapshot([
          {invoice(2, due_date: ~D[2026-10-20]), [eur(10)]},
          {invoice(1, due_date: ~D[2026-10-20]), [eur(20)]},
          {invoice(3, due_date: ~D[2026-10-18]), [eur(30)]}
        ])

      result = CashFlow.build(snap, @today)

      assert [month] = result.months
      assert bucket_ids(month) == [3, 1, 2]
    end

    test "months ascending across a year boundary" do
      snap =
        snapshot([
          {invoice(1, due_date: ~D[2027-01-05]), [eur(10)]},
          {invoice(2, due_date: ~D[2026-12-20]), [eur(10)]},
          {invoice(3, due_date: ~D[2026-10-20]), [eur(10)]}
        ])

      result = CashFlow.build(snap, @today)

      assert Enum.map(result.months, &{&1.year, &1.month}) == [{2026, 10}, {2026, 12}, {2027, 1}]
    end

    test "no_due_date sorted by invoice date then id" do
      snap =
        snapshot([
          {invoice(2, invoice_date: ~D[2026-09-01], due_date: nil), [eur(10)]},
          {invoice(1, invoice_date: ~D[2026-09-01], due_date: nil), [eur(20)]},
          {invoice(3, invoice_date: ~D[2026-08-15], due_date: nil), [eur(30)]}
        ])

      result = CashFlow.build(snap, @today)

      assert bucket_ids(result.no_due_date) == [3, 1, 2]
    end
  end

  # -- totals (BUD-05, BIL-03) ------------------------------------------------------------------

  describe "totals (BUD-05, BIL-03)" do
    @today ~D[2026-10-15]

    test "multi-line invoices use Valuation.Invoices.total/2, exact to the cent" do
      snap =
        snapshot([
          {invoice(1, due_date: ~D[2026-10-20]),
           [eur(Decimal.new("1234.56")), eur(Decimal.new("0.01"))]},
          {invoice(2, due_date: ~D[2026-10-25]), [eur(Decimal.new("100.00"))]}
        ])

      result = CashFlow.build(snap, @today)

      assert [%{total: month_total, invoices: [entry1, entry2]}] = result.months
      assert_money(entry1.total, eur(Decimal.new("1234.57")), "invoice 1 total")
      assert_money(entry2.total, eur(Decimal.new("100.00")), "invoice 2 total")
      assert_money(month_total, eur(Decimal.new("1334.57")), "month bucket total")
      assert_money(result.total, eur(Decimal.new("1334.57")), "overall total")
    end
  end

  # -- empty (DR-75) -----------------------------------------------------------------------------

  describe "empty" do
    test "no invoices" do
      result = CashFlow.build(%Snapshot{}, ~D[2026-10-15])

      assert result.overdue == nil
      assert result.months == []
      assert result.no_due_date == nil
      assert_money(result.total, eur(0), "total")
    end
  end

  # -- property: partition (DR-75) ---------------------------------------------------------------

  describe "property: partition of unpaid invoices" do
    @describetag :property

    test "every unpaid invoice appears in exactly one bucket, matching an independent oracle" do
      seed = {79, 1, 1}
      :rand.seed(:exsss, seed)
      today = ~D[2026-10-15]

      for iteration <- 1..200 do
        {invoice_specs, oracle} = random_invoices(today)
        snap = snapshot(invoice_specs)

        result = CashFlow.build(snap, today)

        assert_partition(result, oracle, today, seed, iteration)
      end
    end
  end

  # -- property-test helpers ---------------------------------------------------------------------

  defp random_invoices(today) do
    count = :rand.uniform(31) - 1

    {specs, oracle} =
      Enum.map_reduce(1..count//1, %{}, fn id, oracle ->
        paid? = :rand.uniform(2) == 1
        due_offset = if :rand.uniform(4) == 1, do: nil, else: Enum.random(-400..400)
        due_date = due_offset && Date.add(today, due_offset)
        invoice_offset = Enum.random(-500..0)
        invoice_date = Date.add(today, invoice_offset)
        paid_on = if paid?, do: Date.add(today, Enum.random(-100..0))

        line_cents = for _ <- 1..Enum.random(1..3), do: Enum.random(0..1_000_00)
        amounts = Enum.map(line_cents, &eur(Decimal.new(&1) |> Decimal.div(100)))

        invoice = invoice(id, due_date: due_date, invoice_date: invoice_date, paid_on: paid_on)

        entry = %{
          paid?: paid?,
          due_offset: due_offset,
          invoice_offset: invoice_offset,
          cents: Enum.sum(line_cents)
        }

        {{invoice, amounts}, Map.put(oracle, id, entry)}
      end)

    {specs, oracle}
  end

  # Rebuilds the expected partition from `oracle` (independent of `CashFlow`): unpaid ids
  # split into overdue / dated-not-overdue / no-due-date by day offsets, then dated ones
  # grouped into calendar months via `Date.add/2`.
  defp oracle_result(oracle, today) do
    unpaid = for {id, %{paid?: false} = e} <- oracle, do: {id, e}

    {overdue, not_overdue} =
      Enum.split_with(unpaid, fn {_id, e} -> e.due_offset != nil and e.due_offset < 0 end)

    {no_due, dated} = Enum.split_with(not_overdue, fn {_id, e} -> e.due_offset == nil end)

    overdue_ids =
      overdue |> Enum.sort_by(fn {id, e} -> {e.due_offset, id} end) |> Enum.map(&elem(&1, 0))

    no_due_ids =
      no_due |> Enum.sort_by(fn {id, e} -> {e.invoice_offset, id} end) |> Enum.map(&elem(&1, 0))

    months =
      dated
      |> Enum.group_by(fn {_id, e} ->
        date = Date.add(today, e.due_offset)
        {date.year, date.month}
      end)
      |> Enum.map(fn {key, group} ->
        ids =
          group |> Enum.sort_by(fn {id, e} -> {e.due_offset, id} end) |> Enum.map(&elem(&1, 0))

        {key, ids}
      end)
      |> Enum.sort_by(&elem(&1, 0))

    %{overdue: overdue_ids, months: months, no_due_date: no_due_ids, unpaid: unpaid}
  end

  defp cents_total(ids, oracle) do
    cents = ids |> Enum.map(&oracle[&1].cents) |> Enum.sum()
    eur(Decimal.new(cents) |> Decimal.div(100))
  end

  defp failure(seed, iteration, context) do
    "seed #{inspect(seed)}, iteration #{iteration}: #{context}"
  end

  defp assert_partition(result, oracle, today, seed, iteration) do
    expected = oracle_result(oracle, today)
    unpaid_ids = Enum.map(expected.unpaid, &elem(&1, 0))

    # every unpaid invoice appears in exactly one bucket; no paid invoice appears
    all_ids =
      bucket_ids(result.overdue) ++
        Enum.flat_map(result.months, &bucket_ids/1) ++ bucket_ids(result.no_due_date)

    assert Enum.sort(all_ids) == Enum.sort(unpaid_ids),
           failure(
             seed,
             iteration,
             "partition membership: got #{inspect(all_ids)}, expected #{inspect(unpaid_ids)}"
           )

    assert length(all_ids) == length(Enum.uniq(all_ids)),
           failure(
             seed,
             iteration,
             "an invoice appeared in more than one bucket: #{inspect(all_ids)}"
           )

    # each bucket's members and total match the oracle
    assert bucket_ids(result.overdue) == expected.overdue,
           failure(seed, iteration, "overdue members")

    assert_money(
      bucket_total_or_zero(result.overdue),
      cents_total(expected.overdue, oracle),
      failure(seed, iteration, "overdue total")
    )

    assert bucket_ids(result.no_due_date) == expected.no_due_date,
           failure(seed, iteration, "no_due_date members")

    assert_money(
      bucket_total_or_zero(result.no_due_date),
      cents_total(expected.no_due_date, oracle),
      failure(seed, iteration, "no_due_date total")
    )

    assert length(result.months) == length(expected.months),
           failure(
             seed,
             iteration,
             "month count: #{length(result.months)} vs #{length(expected.months)}"
           )

    for {actual_month, {{year, month}, ids}} <- Enum.zip(result.months, expected.months) do
      assert {actual_month.year, actual_month.month} == {year, month},
             failure(seed, iteration, "month key")

      assert bucket_ids(actual_month) == ids,
             failure(seed, iteration, "month #{year}-#{month} members")

      assert_money(
        actual_month.total,
        cents_total(ids, oracle),
        failure(seed, iteration, "month #{year}-#{month} total")
      )
    end

    # months strictly ascending, no empty month
    keys = Enum.map(result.months, &{&1.year, &1.month})

    assert keys == Enum.sort(keys),
           failure(seed, iteration, "months not ascending: #{inspect(keys)}")

    assert keys == Enum.uniq(keys), failure(seed, iteration, "duplicate month: #{inspect(keys)}")

    assert Enum.all?(result.months, &(&1.invoices != [])),
           failure(seed, iteration, "an empty month bucket")

    # total == oracle's sum of every unpaid invoice
    assert_money(result.total, cents_total(unpaid_ids, oracle), failure(seed, iteration, "total"))

    # an invoice is in overdue iff unpaid ∧ due < today (integer day offsets)
    for {id, e} <- expected.unpaid do
      in_overdue? = id in bucket_ids(result.overdue)
      expected_overdue? = e.due_offset != nil and e.due_offset < 0

      assert in_overdue? == expected_overdue?,
             failure(
               seed,
               iteration,
               "invoice #{id} overdue mismatch (offset #{inspect(e.due_offset)})"
             )
    end
  end

  defp bucket_total_or_zero(nil), do: eur(0)
  defp bucket_total_or_zero(%{total: total}), do: total
end
