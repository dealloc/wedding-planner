defmodule WeddingPlanner.Valuation.InvoicesTest do
  @moduledoc """
  `WeddingPlanner.Valuation.Invoices` — invoice totals (`BIL-03`), paid and overdue
  (`BIL-02`, `BIL-06`, `DR-59`), an offer's invoiced / paid / outstanding (`BUD-02`) and
  `BIL-07`'s variance (`DR-58`) — over in-memory snapshots, plus one round trip through
  the real contexts and `WeddingPlanner.Valuation.Snapshot.load/1`.

  * `@tag example: "B1"` / `"B2"` — the **offer-level and variance halves** of B1 and B2,
    through the real engines (headcount, offer total, invoices) with no `headcount:` seam.
    Their forecast halves are slice B3's.
  * `@tag :normative_fixture` — `WeddingPlanner.NormativeInvoices`' self-checks.
  * `@tag :real_path` — B1/B2 over real rows; not `example:`-tagged (the pure tests carry
    the tags, `WeddingPlanner.Valuation.OfferDbTest` precedent).

  The property tests compare the engine with an oracle written here in exact integer
  cents (NFR-12 governs production arithmetic, not test oracles — `DR-50`), which shares
  no code with it: it sums the generator's own integer amounts and compares plain
  integer day offsets.
  """
  use WeddingPlanner.DataCase, async: true

  import WeddingPlanner.OfferFixtures, only: [scope_fixture: 0, confirm_directly!: 1]

  alias WeddingPlanner.Invoices, as: InvoicesContext
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Invoices.InvoiceLine
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeGuests
  alias WeddingPlanner.NormativeInvoices
  alias WeddingPlanner.NormativeOfferRows, as: Rows
  alias WeddingPlanner.NormativeSnapshots
  alias WeddingPlanner.Offers.FrozenService
  alias WeddingPlanner.Valuation.Formula
  alias WeddingPlanner.Valuation.Formula.Step
  alias WeddingPlanner.Valuation.Headcount
  alias WeddingPlanner.Valuation.Invoices
  alias WeddingPlanner.Valuation.Offer
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Snapshot

  @today ~D[2027-03-10]

  # -- helpers -------------------------------------------------------------------------------

  defp eur(amount), do: WeddingPlanner.Money.new(amount)

  defp assert_money(actual, expected, what) do
    assert Money.equal?(actual, expected),
           "#{what}: expected #{Money.to_string!(expected)}, got #{Money.to_string!(actual)}"
  end

  # The app's rendering (nl-BE, non-breaking space) of a rounded amount.
  defp shown(money), do: money |> Money.round() |> Money.to_string!()

  defp committed(snapshot, offer, preset) do
    %Formula{total: {:money, money}} = Offer.total(snapshot, offer, preset)
    money
  end

  defp invoice(attrs), do: struct!(%Invoice{label: "Invoice", offer_id: nil}, attrs)

  # Adds one invoice (with one line of `amount`) linked to the built offer.
  defp add_invoice(%{snapshot: snapshot, offer: offer} = built, id, label, amount, attrs \\ []) do
    invoice = invoice([id: id, offer_id: offer.id, label: label] ++ attrs)
    line = %InvoiceLine{id: id * 100, invoice_id: id, label: label, amount: amount}

    snapshot =
      Snapshot.apply(snapshot, [{:put, :invoices, invoice}, {:put, :invoice_lines, line}])

    %{built | snapshot: snapshot}
  end

  defp with_offer(%{snapshot: snapshot} = built, attrs) do
    offer = struct!(built.offer, attrs)
    %{built | offer: offer, snapshot: Snapshot.apply(snapshot, {:put, :offers, offer})}
  end

  # -- the fixture -----------------------------------------------------------------------------

  describe "NormativeInvoices (fixture self-checks)" do
    @describetag :normative_fixture

    test "the in-memory shared guests evaluate to the shared headcount on Dinner" do
      %{snapshot: snapshot} = NormativeInvoices.build("B1")
      [dinner] = snapshot.events

      for {name, counts} <- NE.shared_headcount()["Dinner"] do
        assert Headcount.evaluate(snapshot, NormativeInvoices.preset(name), dinner) == counts,
               "#{name}"
      end
    end

    test "B1/B2 carry the given invoices, amounts untouched, on a confirmed Venue A" do
      for id <- ["B1", "B2"] do
        given = NE.given(id)
        built = NormativeInvoices.build(id)

        assert built.offer.status == :confirmed
        assert built.offer.invoicing_complete == given.invoicing_complete
        assert built.snapshot.offers == [built.offer]
        assert built.preset.name == given.preset

        assert length(built.invoices) == length(given.invoices)

        for {invoice, g} <- Enum.zip(built.invoices, given.invoices) do
          assert invoice.label == g.label
          assert invoice.offer_id == built.offer.id
          assert Invoice.paid?(invoice) == (g.paid == true)
          [line] = Enum.filter(built.snapshot.invoice_lines, &(&1.invoice_id == invoice.id))
          assert line.amount == g.amount
        end
      end
    end

    test "Venue A's committed total under Likely is the given €11,726 (via the real headcount)" do
      %{snapshot: snapshot, offer: offer, preset: preset} = NormativeInvoices.build("B1")
      assert_money(committed(snapshot, offer, preset), NE.given("B1").committed, "committed")
      assert_money(NE.given("B1").committed, NE.expected("O1").total, "O1")
    end
  end

  # -- B1 / B2 -------------------------------------------------------------------------------

  describe "normative examples B1, B2 (offer-level and variance halves)" do
    @tag example: "B1"
    test "B1 offer-level paid/invoiced/outstanding and variance only (the forecast half is B3's)" do
      expected = NE.expected("B1")
      %{snapshot: snapshot, offer: offer, preset: preset} = NormativeInvoices.build("B1")

      figures = Invoices.offer_figures(snapshot, offer)
      assert_money(figures.invoiced, expected.invoiced, "invoiced")
      assert_money(figures.paid, expected.paid, "paid")
      assert_money(figures.outstanding, expected.outstanding, "outstanding")

      assert %{amount: amount, direction: direction, committed: committed, invoiced: invoiced} =
               Invoices.variance(snapshot, offer, preset)

      assert %Formula{total: {:money, committed_money}} = committed
      assert_money(committed_money, NE.given("B1").committed, "committed")
      assert_money(invoiced, expected.invoiced, "variance invoiced")
      assert_money(amount, expected.variance.amount, "variance amount")
      assert direction == expected.variance.direction

      assert shown(amount) == "€ 8.726,00"
      assert shown(figures.outstanding) == "€ 0,00"
    end

    @tag example: "B2"
    test "B2 variance: two invoices above committed, unchanged by invoicing complete (forecast: B3)" do
      expected = NE.expected("B2")
      given = NE.given("B2")
      %{snapshot: snapshot, offer: offer, preset: preset} = built = NormativeInvoices.build("B2")
      assert offer.invoicing_complete

      figures = Invoices.offer_figures(snapshot, offer)
      given_sum = given.invoices |> Enum.map(& &1.amount) |> WeddingPlanner.Money.sum()
      assert_money(figures.invoiced, given_sum, "invoiced")
      assert shown(figures.invoiced) == "€ 11.900,00"

      variance = Invoices.variance(snapshot, offer, preset)
      assert_money(variance.invoiced, given_sum, "variance invoiced")
      assert_money(variance.amount, expected.variance.amount, "variance amount")
      assert variance.direction == expected.variance.direction
      assert shown(variance.amount) == "€ 174,00"

      %{snapshot: incomplete_snapshot, offer: incomplete} =
        with_offer(built, invoicing_complete: false)

      assert Invoices.variance(incomplete_snapshot, incomplete, preset) == variance
    end
  end

  # -- variance/3 ---------------------------------------------------------------------------

  describe "variance/3 (BIL-07, DR-58)" do
    test "committed equal to invoiced → :matches, amount €0" do
      built = NormativeInvoices.build("B1") |> add_invoice(3, "Balance", eur(8726))

      assert %{amount: amount, direction: :matches, formula: %Formula{total: {:money, total}}} =
               Invoices.variance(built.snapshot, built.offer, built.preset)

      assert_money(amount, eur(0), "amount")
      assert_money(total, eur(0), "formula total")
    end

    test "an offer that is not confirmed → :not_confirmed" do
      built = NormativeInvoices.build("B2")

      for status <- [:considering, :shortlisted, :rejected] do
        %{snapshot: snapshot, offer: offer} = with_offer(built, status: status)
        assert Invoices.variance(snapshot, offer, built.preset) == :not_confirmed
      end
    end

    test "the committed side is the offer's total under the chosen preset (Minimum: O2)" do
      %{snapshot: snapshot, offer: offer} = NormativeInvoices.build("B1")
      minimum = NormativeInvoices.preset("Minimum")

      variance = Invoices.variance(snapshot, offer, minimum)
      assert %Formula{total: {:money, committed}} = variance.committed
      assert_money(committed, NE.expected("O2").total, "committed under Minimum")
      assert_money(variance.amount, eur(8478), "amount")
      assert variance.direction == :not_yet_invoiced
    end

    test "the formula names the preset, then committed, each linked invoice, invoiced" do
      %{snapshot: snapshot, offer: offer, preset: preset} = NormativeInvoices.build("B2")

      assert %Formula{label: "Variance", steps: steps, total: {:money, total}} =
               Invoices.variance(snapshot, offer, preset).formula

      assert [
               %Step{label: "Headcount preset", value: {:preset, "Likely"}},
               %Step{label: "Committed", value: {:money, committed}},
               %Step{label: "Deposit", value: {:money, deposit}},
               %Step{label: "Final invoice", value: {:money, final}},
               %Step{label: "Invoiced", value: {:money, invoiced}}
             ] = steps

      assert_money(committed, eur(11_726), "committed step")
      assert_money(deposit, eur(3000), "deposit step")
      assert_money(final, eur(8900), "final step")
      assert_money(invoiced, eur(11_900), "invoiced step")
      assert_money(total, eur(174), "total")
    end

    test "no preset step when the committed total does not depend on the preset (DR-50)" do
      %{snapshot: snapshot} = built = NormativeInvoices.build("B1")
      per_person = for line <- snapshot.offer_lines, line.basis != :flat, do: line.id

      built = %{
        built
        | snapshot:
            Snapshot.apply(snapshot, for(id <- per_person, do: {:delete, :offer_lines, id}))
      }

      %Formula{steps: steps} =
        Invoices.variance(built.snapshot, built.offer, built.preset).formula

      refute Enum.any?(steps, &match?(%Step{value: {:preset, _}}, &1))
      assert %Step{label: "Committed"} = hd(steps)
    end

    test "invoices of other offers and unlinked invoices are not counted" do
      built =
        NormativeInvoices.build("B1")
        |> add_invoice(3, "Other offer", eur(500), offer_id: 999)
        |> add_invoice(4, "Unlinked", eur(700), offer_id: nil)

      assert_money(
        Invoices.variance(built.snapshot, built.offer, built.preset).invoiced,
        eur(3000),
        "invoiced"
      )

      assert_money(
        Invoices.offer_figures(built.snapshot, built.offer).invoiced,
        eur(3000),
        "figures"
      )

      assert [%Invoice{id: 1}] = Invoices.for_offer(built.snapshot, built.offer)
    end
  end

  # -- total/2, paid?/1, overdue?/2, for_offer/2 ------------------------------------------

  describe "total/2 (BIL-03)" do
    test "sums the invoice's own lines, in cents exactly" do
      snapshot = %Snapshot{
        invoice_lines: [
          %InvoiceLine{id: 1, invoice_id: 7, label: "a", amount: eur(Decimal.new("100.10"))},
          %InvoiceLine{id: 2, invoice_id: 8, label: "other", amount: eur(5)},
          %InvoiceLine{id: 3, invoice_id: 7, label: "b", amount: eur(Decimal.new("0.05"))}
        ]
      }

      assert_money(Invoices.total(snapshot, invoice(id: 7)), eur(Decimal.new("100.15")), "7")
      assert shown(Invoices.total(snapshot, invoice(id: 7))) == "€ 100,15"
    end

    test "an invoice without lines totals €0" do
      assert_money(Invoices.total(%Snapshot{}, invoice(id: 1)), eur(0), "empty")
    end
  end

  describe "paid?/1 and overdue?/2 (BIL-02, BIL-06, DR-59)" do
    test "paid iff paid_on is set" do
      assert Invoices.paid?(invoice(paid_on: ~D[2027-01-01]))
      refute Invoices.paid?(invoice(paid_on: nil))
    end

    test "due yesterday and unpaid → overdue" do
      assert Invoices.overdue?(invoice(due_date: Date.add(@today, -1)), @today)
    end

    test "due today → not overdue yet" do
      refute Invoices.overdue?(invoice(due_date: @today), @today)
    end

    test "due tomorrow → not overdue" do
      refute Invoices.overdue?(invoice(due_date: Date.add(@today, 1)), @today)
    end

    test "paid → never overdue, even long past its due date" do
      refute Invoices.overdue?(
               invoice(due_date: Date.add(@today, -30), paid_on: Date.add(@today, -1)),
               @today
             )
    end

    test "no due date → never overdue" do
      refute Invoices.overdue?(invoice(due_date: nil), @today)
    end
  end

  # -- properties ----------------------------------------------------------------------------

  @runs 400
  @base_date ~D[2027-01-01]

  describe "properties (independent integer-cents oracle)" do
    test "offer_figures/2, variance/3, total/2 and overdue?/2 agree with the oracle; invoiced == paid + outstanding" do
      outcomes =
        for run <- 1..@runs do
          generated = random_case()
          %{snapshot: snapshot, offer: offer, preset: preset, today: today} = generated
          oracle = oracle(generated)
          context = "run #{run}: #{inspect(generated.spec, limit: :infinity)}"

          figures = Invoices.offer_figures(snapshot, offer)
          assert cents(figures.invoiced) == oracle.invoiced, context
          assert cents(figures.paid) == oracle.paid, context
          assert cents(figures.outstanding) == oracle.outstanding, context

          assert cents(figures.invoiced) == cents(figures.paid) + cents(figures.outstanding),
                 context

          case {Invoices.variance(snapshot, offer, preset), oracle.variance} do
            {:not_confirmed, :not_confirmed} ->
              :ok

            {%{amount: amount, direction: direction, invoiced: invoiced, formula: formula},
             {oracle_amount, oracle_direction}} ->
              assert cents(amount) == oracle_amount, context
              assert direction == oracle_direction, context
              assert cents(invoiced) == oracle.invoiced, context
              # one step per linked invoice, between "Committed" and "Invoiced"
              labels = Enum.map(formula.steps, & &1.label)

              assert Enum.count(labels, &String.starts_with?(&1, "Linked ")) ==
                       oracle.linked_count,
                     context

            {actual, expected} ->
              flunk("#{context}\nvariance: expected #{inspect(expected)}, got #{inspect(actual)}")
          end

          assert map_size(oracle.invoices) == length(snapshot.invoices), context

          for invoice <- snapshot.invoices do
            %{cents: invoice_cents, overdue: overdue} = Map.fetch!(oracle.invoices, invoice.id)
            assert cents(Invoices.total(snapshot, invoice)) == invoice_cents, context
            assert Invoices.overdue?(invoice, today) == overdue, context
          end

          overdue_seen = Enum.map(Map.values(oracle.invoices), & &1.overdue)

          case oracle.variance do
            :not_confirmed -> [:not_confirmed | overdue_seen]
            {_amount, direction} -> [direction | overdue_seen]
          end
        end

      # Not vacuous: every variance outcome, and both overdue answers, actually occurred.
      seen = outcomes |> List.flatten() |> MapSet.new()

      for outcome <- [:not_confirmed, :not_yet_invoiced, :above_committed, :matches, true, false] do
        assert outcome in seen, "#{inspect(outcome)} never generated in #{@runs} runs"
      end
    end
  end

  # A random case: a normative offer (Venue A or Caterer C) over the shared guests, a random
  # status and default preset, invoices linked to it (sometimes summing exactly to its
  # committed total) plus distractors linked elsewhere or to nothing, each with random lines,
  # paid date and due date, and a random `today`. Dates are day offsets from @base_date.
  defp random_case do
    which = Enum.random([:venue_a, :caterer_c])
    %{snapshot: snapshot, offer: offer} = NormativeSnapshots.snapshot(which)
    {persons, invitations} = NormativeInvoices.shared_guests()

    status =
      Enum.random([:confirmed, :confirmed, :confirmed, :considering, :shortlisted, :rejected])

    # CST-40, DR-61: a confirmed offer carries the frozen selection its confirmation took.
    frozen_services =
      if status == :confirmed do
        for service_id <- Selection.freeze(snapshot, offer),
            do: %FrozenService{id: service_id, offer_id: offer.id, service_id: service_id}
      else
        []
      end

    offer = %{offer | status: status}
    preset = Enum.random(Preset.defaults())

    snapshot = %{
      snapshot
      | offers: [offer],
        persons: persons,
        invitations: invitations,
        frozen_services: frozen_services
    }

    committed_cents = cents(committed(snapshot, offer, preset))

    linked_count = Enum.random(0..5)
    exact? = linked_count > 0 and :rand.uniform(4) == 1

    linked_line_cents =
      if exact?,
        do: split(committed_cents, linked_count),
        else: for(_ <- 1..linked_count//1, do: random_lines())

    distractors =
      for _ <- 1..Enum.random(0..3)//1, do: {Enum.random([nil, 999]), random_lines()}

    specs =
      Enum.map(linked_line_cents, &{offer.id, &1}) ++ distractors

    specs =
      specs
      |> Enum.shuffle()
      |> Enum.with_index(1)
      |> Enum.map(fn {{offer_id, line_cents}, id} ->
        %{
          id: id,
          offer_id: offer_id,
          line_cents: line_cents,
          paid: random_offset(),
          due: random_offset()
        }
      end)

    invoices =
      for spec <- specs do
        %Invoice{
          id: spec.id,
          category_id: offer.category_id,
          offer_id: spec.offer_id,
          label: if(spec.offer_id == offer.id, do: "Linked #{spec.id}", else: "Other #{spec.id}"),
          invoice_date: @base_date,
          paid_on: date(spec.paid),
          due_date: date(spec.due)
        }
      end

    lines =
      specs
      |> Enum.flat_map(fn spec ->
        spec.line_cents
        |> Enum.with_index()
        |> Enum.map(fn {c, n} ->
          %InvoiceLine{
            id: spec.id * 10 + n,
            invoice_id: spec.id,
            label: "L",
            amount: from_cents(c)
          }
        end)
      end)
      |> Enum.shuffle()

    today_offset = Enum.random(-5..60)

    %{
      snapshot: %{snapshot | invoices: invoices, invoice_lines: lines},
      offer: offer,
      preset: preset,
      today: Date.add(@base_date, today_offset),
      spec: %{
        which: which,
        status: status,
        preset: preset.name,
        committed_cents: committed_cents,
        invoices: specs,
        today: today_offset
      }
    }
  end

  # The oracle: integer cents and integer day offsets only.
  defp oracle(%{offer: offer, spec: spec}) do
    per_invoice =
      Enum.map(spec.invoices, fn s ->
        c = Enum.sum(s.line_cents)
        overdue = is_nil(s.paid) and not is_nil(s.due) and s.due < spec.today
        {s, c, overdue}
      end)

    linked = for {s, c, _} <- per_invoice, s.offer_id == offer.id, do: {s, c}
    invoiced = linked |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    paid = for({s, c} <- linked, not is_nil(s.paid), do: c) |> Enum.sum()

    variance =
      cond do
        spec.status != :confirmed -> :not_confirmed
        spec.committed_cents > invoiced -> {spec.committed_cents - invoiced, :not_yet_invoiced}
        spec.committed_cents < invoiced -> {invoiced - spec.committed_cents, :above_committed}
        true -> {0, :matches}
      end

    %{
      invoiced: invoiced,
      paid: paid,
      outstanding: invoiced - paid,
      variance: variance,
      linked_count: length(linked),
      invoices:
        Map.new(per_invoice, fn {s, c, overdue} -> {s.id, %{cents: c, overdue: overdue}} end)
    }
  end

  # 0–3 lines of 0 … €6,000.00 each (an invoice without lines is impossible for loaded data
  # but defined, so it is generated too, rarely); zero-cent lines occur.
  defp random_lines do
    for _ <- 1..Enum.random([0, 1, 1, 1, 2, 2, 3])//1 do
      if :rand.uniform(10) == 1, do: 0, else: Enum.random(1..600_000)
    end
  end

  # `total` split into `parts` invoices of one or two lines each, summing exactly to it.
  defp split(total, parts) do
    cuts = for(_ <- 1..(parts - 1)//1, do: Enum.random(0..total)) |> Enum.sort()
    bounds = [0] ++ cuts ++ [total]

    bounds
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] ->
      part = b - a
      if part > 1 and :rand.uniform(2) == 1, do: [div(part, 3), part - div(part, 3)], else: [part]
    end)
  end

  defp random_offset, do: if(:rand.uniform(3) == 1, do: nil, else: Enum.random(-10..60))

  defp date(nil), do: nil
  defp date(offset), do: Date.add(@base_date, offset)

  defp from_cents(c), do: WeddingPlanner.Money.new(Decimal.new(1, c, -2))

  defp cents(%Money{amount: amount}), do: amount |> Decimal.mult(100) |> Decimal.to_integer()

  # -- the real path -------------------------------------------------------------------------

  describe "B1/B2 over real rows (contexts → Snapshot.load/1 → the engine)" do
    @describetag :real_path

    test "B1 then B2: figures and variance survive storage and the loader" do
      scope = scope_fixture()
      dinner = Rows.dinner!(scope)
      {venue, services} = Rows.category!(scope, NE.venue_category())
      %{offer: offer} = Rows.offer!(scope, :venue_a, venue, services, dinner)
      _guests = NormativeGuests.shared_dinner!(scope, dinner)

      # CST-40, DR-61: confirmed with its frozen selection (task 73's context later).
      offer = confirm_directly!(offer)
      [deposit_given] = NE.given("B1").invoices

      {:ok, deposit} =
        InvoicesContext.create_invoice(
          scope,
          venue,
          %{label: deposit_given.label, invoice_date: ~D[2027-01-15], offer_id: offer.id},
          %{label: deposit_given.label, amount: deposit_given.amount}
        )

      {:ok, _deposit} = InvoicesContext.mark_paid(scope, deposit, ~D[2027-01-31])

      snapshot = Snapshot.load(Repo)
      loaded = Enum.find(snapshot.offers, &(&1.id == offer.id))
      likely = Enum.find(snapshot.headcount_presets, &(&1.role == :likely))
      assert likely.name == "Likely"

      b1 = NE.expected("B1")
      figures = Invoices.offer_figures(snapshot, loaded)
      assert_money(figures.invoiced, b1.invoiced, "B1 invoiced")
      assert_money(figures.paid, b1.paid, "B1 paid")
      assert_money(figures.outstanding, b1.outstanding, "B1 outstanding")

      variance = Invoices.variance(snapshot, loaded, likely)
      assert_money(variance.amount, b1.variance.amount, "B1 variance")
      assert variance.direction == b1.variance.direction

      final_given = Enum.find(NE.given("B2").invoices, &(&1.label == "Final invoice"))

      {:ok, _final} =
        InvoicesContext.create_invoice(
          scope,
          venue,
          %{label: final_given.label, invoice_date: ~D[2027-06-20], offer_id: offer.id},
          %{label: final_given.label, amount: final_given.amount}
        )

      {:ok, _offer} = InvoicesContext.set_invoicing_complete(scope, offer, true)

      snapshot = Snapshot.load(Repo)
      loaded = Enum.find(snapshot.offers, &(&1.id == offer.id))
      assert loaded.invoicing_complete

      b2 = NE.expected("B2")
      variance = Invoices.variance(snapshot, loaded, likely)
      assert_money(variance.invoiced, eur(11_900), "B2 invoiced")
      assert_money(variance.amount, b2.variance.amount, "B2 variance")
      assert variance.direction == b2.variance.direction
    end
  end
end
