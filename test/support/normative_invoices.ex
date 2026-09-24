defmodule WeddingPlanner.NormativeInvoices do
  @moduledoc """
  Normative examples **B1** and **B2** (`docs/07-normative-examples.md`) as **real structs**
  in an in-memory `WeddingPlanner.Valuation.Snapshot` — no database, no `headcount:` seam.
  Test support only; the invoice figures engine's tests
  (`WeddingPlanner.Valuation.InvoicesTest`) evaluate these.

  Built on top of `WeddingPlanner.NormativeSnapshots.snapshot(:venue_a)`: Venue A with its
  offer made **confirmed** (a struct change, `DR-58`) together with its **frozen
  selection** (`CST-40`, `DR-61`) — one `%FrozenService{}` per id
  `WeddingPlanner.Valuation.Selection.freeze/2` gives on the pre-confirmation snapshot
  (Seating, Catering, Sound, Late-night snack), never hand-listed — the doc's shared Dinner
  guest list
  (`shared_guests/0`) so the real headcount engine gives Likely 72 + 6, and the example's
  invoices as `%Invoice{}`/`%InvoiceLine{}` structs in `snapshot.invoices` /
  `snapshot.invoice_lines`. Every amount is `WeddingPlanner.NormativeExamples.given/1`'s own
  `%Money{}`, never retyped (`DR-18`).

  ## The shared Dinner guests — `shared_guests/0`

  The in-memory twin of `WeddingPlanner.NormativeGuests.shared_dinner!/2` (same
  construction, `DR-26` D8): 60 *certain* adults, 4 *certain* children, 12 *likely* adults,
  2 *likely* children, all *invited* to Dinner, want tier *yes*, no +1, no group. So the
  default Minimum is 60 + 4 and Likely 72 + 6
  (`WeddingPlanner.NormativeExamples.shared_headcount/0`); self-checked under
  `:normative_fixture` in `WeddingPlanner.Valuation.InvoicesTest`. Person ids are
  `1001…1078`, invitation ids `2001…2078`.

  ## Test construction, not normative data

  The docs give each invoice's label, amount and (for B1's deposit) that it is paid —
  nothing else. This fixture's own choices, none asserted as normative:

    * one line per invoice, labelled like its invoice, carrying the whole amount;
    * invoice dates, the deposit's paid date, and **no** due dates;
    * B2's final invoice is **unpaid** (the doc does not say, `given("B2")` marks it
      `:not_stated`, and B2's expectations do not depend on it) — which also means a
      "sum only the paid invoices" bug cannot pass B2;
    * invoice ids `1`, `2` in the docs' order, line ids `11`, `12`; both invoices in
      Venue A's category and linked to Venue A;
    * frozen-service ids `101, 102, …` in service order.
  """

  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Invitations.Invitation
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Invoices.InvoiceLine
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeSnapshots
  alias WeddingPlanner.Offers.FrozenService
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Snapshot

  @typedoc "What `build/1` returns."
  @type built :: %{
          snapshot: Snapshot.t(),
          offer: Offer.t(),
          preset: Preset.t(),
          invoices: [Invoice.t()]
        }

  # {count, certainty, age} — NormativeGuests.shared_dinner!/2's construction (DR-26 D8).
  @shared_roles [
    {60, :certain, :adult},
    {4, :certain, :child},
    {12, :likely, :adult},
    {2, :likely, :child}
  ]

  @invoice_dates [~D[2027-01-15], ~D[2027-06-20]]
  @deposit_paid_on ~D[2027-01-31]

  @doc """
  Builds example `"B1"` or `"B2"` (see the moduledoc): the snapshot, the confirmed Venue A
  offer as it sits in `snapshot.offers`, the example's preset (a default, by name), and the
  example's invoices in the docs' order.
  """
  @spec build(String.t()) :: built()
  def build(id) when id in ["B1", "B2"] do
    given = NE.given(id)
    %{snapshot: snapshot, offer: offer} = NormativeSnapshots.snapshot(:venue_a)
    # The example's offer is the fixture's Venue A; fail loudly if either ever changes.
    true = given.confirmed_offer.vendor == offer.vendor_name

    # CST-40: confirming freezes what is effectively wanted *now* — computed by the engine
    # on the pre-confirmation snapshot, so the fixture cannot drift from the rule.
    frozen_services =
      snapshot
      |> Selection.freeze(offer)
      |> Enum.with_index(1)
      |> Enum.map(fn {service_id, n} ->
        %FrozenService{id: 100 + n, offer_id: offer.id, service_id: service_id}
      end)

    offer = %{offer | status: :confirmed, invoicing_complete: given.invoicing_complete}
    {persons, invitations} = shared_guests()

    {invoices, lines} =
      given.invoices
      |> Enum.with_index(1)
      |> Enum.map(fn {%{label: label, amount: amount, paid: paid}, id} ->
        invoice = %Invoice{
          id: id,
          category_id: offer.category_id,
          offer_id: offer.id,
          label: label,
          invoice_date: Enum.at(@invoice_dates, id - 1),
          due_date: nil,
          paid_on: if(paid == true, do: @deposit_paid_on)
        }

        {invoice, %InvoiceLine{id: 10 + id, invoice_id: id, label: label, amount: amount}}
      end)
      |> Enum.unzip()

    snapshot = %{
      snapshot
      | offers: [offer],
        persons: persons,
        invitations: invitations,
        headcount_presets: Preset.defaults(),
        invoices: invoices,
        invoice_lines: lines,
        frozen_services: frozen_services
    }

    %{snapshot: snapshot, offer: offer, preset: preset(given.preset), invoices: invoices}
  end

  @doc """
  The shared Dinner guest list as in-memory `{persons, invitations}` (see the moduledoc),
  on `WeddingPlanner.NormativeSnapshots`' Dinner event.
  """
  @spec shared_guests() :: {[Person.t()], [Invitation.t()]}
  def shared_guests do
    %{event: dinner} = NormativeSnapshots.snapshot(:venue_a)

    persons =
      @shared_roles
      |> Enum.flat_map(fn {count, certainty, age} -> List.duplicate({certainty, age}, count) end)
      |> Enum.with_index(1)
      |> Enum.map(fn {{certainty, age}, n} ->
        %Person{
          id: 1000 + n,
          first_name: "Shared",
          last_name: String.pad_leading(Integer.to_string(n), 2, "0"),
          certainty: certainty,
          age_category: age,
          want_tier: :yes
        }
      end)

    invitations =
      for %Person{id: id} <- persons do
        %Invitation{id: id + 1000, person_id: id, event_id: dinner.id, status: :invited}
      end

    {persons, invitations}
  end

  @doc "The default preset named `name` (`HC-06`)."
  @spec preset(String.t()) :: Preset.t()
  def preset(name) do
    Enum.find(Preset.defaults(), &(&1.name == name)) ||
      raise ArgumentError, "no default preset named #{inspect(name)}"
  end
end
