defmodule WeddingPlanner.BudgetSnapshots do
  @moduledoc """
  In-memory `WeddingPlanner.Valuation.Snapshot`s for the budget engine
  (`WeddingPlanner.Valuation.Budget`, slice B3) and the modules that read its result
  (breakdowns, charts). Test support only; no database, no `headcount:` seam.

  Built on `WeddingPlanner.NormativeInvoices` / `WeddingPlanner.NormativeSnapshots` /
  `WeddingPlanner.NormativeExamples`: normative amounts are the fixture's own `%Money{}`
  values, never retyped (`DR-18`). Amounts this module adds itself are test construction
  (integers through `WeddingPlanner.Money.new/1`), not normative data.

    * `b1/0`, `b2/0` — `NormativeInvoices.build("B1" | "B2")`, unchanged.
    * `b3/0` — example B3: one category "Attire", target `NE.given("B3")`'s, no offers,
      no invoices, `Preset.defaults()`.
    * `branches/0` — one snapshot with every `BUD-03` branch (below).

  ## `branches/0`

  B1's snapshot (Venue, the confirmed Venue A with its frozen selection, the paid €3,000
  deposit, invoicing not complete, the shared Dinner guests — Likely 72 + 6,
  Minimum 60 + 4, and Maximum equal to Likely since every shared guest is *certain* or
  *likely*) plus four categories, `Preset.defaults()` and an overall budget of
  **€20,000**. Categories in this order (`snapshot.categories` order):

  | id | Category    | Target  | Offers | Invoices | Branch |
  |----|-------------|---------|--------|----------|--------|
  | 1  | Venue       | —       | 1 Venue A (confirmed, not complete) | 1 Deposit €3,000 paid, linked | `:confirmed`, `source: :committed` |
  | 2  | Photography | —       | 21 Photographer P (confirmed, **invoicing complete**; one flat mandatory ad hoc line "Photography package" €2,000) | 31 "Photographer invoice" €1,800 paid, linked | `:confirmed`, `source: :invoicing_complete` — forecast €1,800, **below** committed |
  | 3  | Flowers     | €1,000  | 22 Florist F (shortlisted, **planning pick**; per-attendee mandatory ad hoc line "Table flowers" €10 at Dinner + flat mandatory ad hoc line "Arch" €500), 23 Florist G (considering; flat mandatory ad hoc line "Everything" €5,000) | 32 "Florist deposit" €300 unpaid, unlinked | `:planning_pick`, `fallback_winner: :base` — Likely €1,280, Minimum €1,140 |
  | 4  | Attire      | €2,500 (B3's) | — | 33 "Tailor invoice" €3,100 paid, unlinked | `:target`, `fallback_winner: :unlinked_invoices` — €3,100 |
  | 5  | Church      | —       | — | — | `:no_target` — €0 |

  Under Likely the forecast totals €11,726 + €1,800 + €1,280 + €3,100 + €0 = €17,906,
  so Available is €2,094.

  Ids (distinct from `NormativeInvoices`' — invoices `1`, `2`, lines `11`, `12`, frozen
  services `101…`, persons `1001…`, invitations `2001…`, and `NormativeSnapshots`' —
  category `1`, offer `1`, offer lines `1…8`, services `101…`, event `1`): categories
  `2…5`; offers `21`, `22`, `23`; offer lines `201` (Photography package), `202` (Table
  flowers), `203` (Arch), `204` (Everything); invoices `31`, `32`, `33`; invoice lines
  `131`, `132`, `133` (one per invoice, labelled like it, carrying its whole amount); frozen
  services `301…`.
  All offers VAT inclusive, no minimum spend. The Photographer's frozen selection is
  `Selection.freeze/2`'s (empty: the category has no services).
  """

  alias WeddingPlanner.Categories.Category
  alias WeddingPlanner.Invoices.Invoice
  alias WeddingPlanner.Invoices.InvoiceLine
  alias WeddingPlanner.NormativeExamples, as: NE
  alias WeddingPlanner.NormativeInvoices
  alias WeddingPlanner.Offers.FrozenService
  alias WeddingPlanner.Offers.Offer
  alias WeddingPlanner.Offers.OfferLine
  alias WeddingPlanner.Settings
  alias WeddingPlanner.Valuation.Preset
  alias WeddingPlanner.Valuation.Selection
  alias WeddingPlanner.Valuation.Snapshot

  @dinner_id 1

  @doc "Example B1 — `NormativeInvoices.build(\"B1\")`, unchanged."
  @spec b1() :: NormativeInvoices.built()
  def b1, do: NormativeInvoices.build("B1")

  @doc "Example B2 — `NormativeInvoices.build(\"B2\")`, unchanged."
  @spec b2() :: NormativeInvoices.built()
  def b2, do: NormativeInvoices.build("B2")

  @doc """
  Example B3: category "Attire" (id `4`) with `NE.given("B3")`'s target, no offers, no
  invoices, `Preset.defaults()`. Returns `%{snapshot: snapshot, category: category}`.
  """
  @spec b3() :: %{snapshot: Snapshot.t(), category: Category.t()}
  def b3 do
    category = attire()

    %{
      snapshot: %Snapshot{categories: [category], headcount_presets: Preset.defaults()},
      category: category
    }
  end

  @doc "The overall budget `branches/0` sets: €20,000 (test construction)."
  @spec branches_budget() :: Money.t()
  def branches_budget, do: eur(20_000)

  @doc """
  The snapshot with every `BUD-03` branch (see the moduledoc). Returns the snapshot and
  its categories, offers and invoices by name for readable assertions:

      %{snapshot: snapshot,
        categories: %{"Venue" => cat, "Photography" => cat, "Flowers" => cat,
                      "Attire" => cat, "Church" => cat},
        offers: %{"Venue A" => offer, "Photographer P" => offer, "Florist F" => offer,
                  "Florist G" => offer},
        invoices: %{"Deposit" => inv, "Photographer invoice" => inv,
                    "Florist deposit" => inv, "Tailor invoice" => inv}}
  """
  @spec branches() :: map()
  def branches do
    %{snapshot: b1, offer: venue_a, invoices: [deposit]} = b1()
    [venue] = b1.categories

    photography = %Category{id: 2, name: "Photography", sort_order: 1}
    flowers = %Category{id: 3, name: "Flowers", sort_order: 2, target: eur(1_000)}
    attire = %{attire() | sort_order: 3}
    church = %Category{id: 5, name: "Church", sort_order: 4}

    photographer = offer(21, photography, "Photographer P", :confirmed, invoicing_complete: true)
    florist_f = offer(22, flowers, "Florist F", :shortlisted, planning_pick: true)
    florist_g = offer(23, flowers, "Florist G", :considering)

    lines = [
      flat_line(201, photographer, "Photography package", eur(2_000)),
      %OfferLine{
        id: 202,
        offer_id: florist_f.id,
        label: "Table flowers",
        state: :mandatory,
        basis: :per_attendee,
        event_id: @dinner_id,
        amount: eur(10),
        enabled: false
      },
      flat_line(203, florist_f, "Arch", eur(500)),
      flat_line(204, florist_g, "Everything", eur(5_000))
    ]

    snapshot = %{
      b1
      | categories: [venue, photography, flowers, attire, church],
        offers: b1.offers ++ [photographer, florist_f, florist_g],
        offer_lines: b1.offer_lines ++ lines
    }

    # CST-40: the Photographer's frozen selection is what the engine freezes (empty here —
    # the category has no services), never hand-listed. `freeze/2` ignores the status.
    frozen =
      snapshot
      |> Selection.freeze(photographer)
      |> Enum.with_index(301)
      |> Enum.map(fn {service_id, id} ->
        %FrozenService{id: id, offer_id: photographer.id, service_id: service_id}
      end)

    {invoices, invoice_lines} =
      [
        {31, photography, photographer.id, "Photographer invoice", eur(1_800), ~D[2027-02-01]},
        {32, flowers, nil, "Florist deposit", eur(300), nil},
        {33, attire, nil, "Tailor invoice", eur(3_100), ~D[2027-03-01]}
      ]
      |> Enum.map(fn {id, category, offer_id, label, amount, paid_on} ->
        {%Invoice{
           id: id,
           category_id: category.id,
           offer_id: offer_id,
           label: label,
           invoice_date: ~D[2027-01-10],
           due_date: nil,
           paid_on: paid_on
         }, %InvoiceLine{id: 100 + id, invoice_id: id, label: label, amount: amount}}
      end)
      |> Enum.unzip()

    snapshot = %{
      snapshot
      | frozen_services: b1.frozen_services ++ frozen,
        invoices: b1.invoices ++ invoices,
        invoice_lines: b1.invoice_lines ++ invoice_lines,
        headcount_presets: Preset.defaults(),
        settings: %Settings{overall_budget: branches_budget()}
    }

    [photographer_invoice, florist_deposit, tailor_invoice] = invoices

    %{
      snapshot: snapshot,
      categories: Map.new(snapshot.categories, &{&1.name, &1}),
      offers: %{
        "Venue A" => venue_a,
        "Photographer P" => photographer,
        "Florist F" => florist_f,
        "Florist G" => florist_g
      },
      invoices: %{
        "Deposit" => deposit,
        "Photographer invoice" => photographer_invoice,
        "Florist deposit" => florist_deposit,
        "Tailor invoice" => tailor_invoice
      }
    }
  end

  # -- building --------------------------------------------------------------------------------

  defp attire do
    %{category: %{name: name, target: target}} = NE.given("B3")
    %Category{id: 4, name: name, sort_order: 0, target: target}
  end

  defp offer(id, category, vendor, status, attrs \\ []) do
    struct!(
      %Offer{
        id: id,
        category_id: category.id,
        vendor_name: vendor,
        status: status,
        vat_basis: :inclusive,
        invoicing_complete: false,
        planning_pick: false
      },
      attrs
    )
  end

  defp flat_line(id, offer, label, amount) do
    %OfferLine{
      id: id,
      offer_id: offer.id,
      label: label,
      state: :mandatory,
      basis: :flat,
      amount: amount,
      enabled: false
    }
  end

  defp eur(amount), do: WeddingPlanner.Money.new(amount)
end
