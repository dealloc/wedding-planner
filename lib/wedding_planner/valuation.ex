defmodule WeddingPlanner.Valuation do
  @moduledoc """
  The valuation layer: every headcount, offer total and budget figure in the app is
  computed here, as **pure functions over an in-memory snapshot** of the planning state.

      snapshot = Snapshot.load(WeddingPlanner.Repo)       # one read pass, bounded queries
      Headcount.evaluate(snapshot, preset, event)          # -> %{adults:, children:, total:}
      Offer.total(snapshot, offer, preset)                 # -> %Formula{}
      Budget.forecast(snapshot, preset)                    # -> per-category layers

  (all modules under `WeddingPlanner.Valuation`).

  ## Why this shape

    * `BUD-21` / `BUD-22` — a what-if delta is the **full** forecast evaluated with and
      without the change: `Budget.forecast(Snapshot.apply(snapshot, change), preset)`
      against `Budget.forecast(snapshot, preset)`. Summing per-person rates would ignore
      included quantities, minimum charges and minimum spends.
    * `NFR-41` — the calculations are pure, UI-independent and testable without Ecto or
      LiveView: a test builds a `%Snapshot{}` in memory and calls an engine.
    * `NFR-13` — no money aggregation in SQL; amounts are combined only in Elixir, through
      `WeddingPlanner.Money` (`NFR-12`).
    * `NFR-33` — at the expected size (≤ ~150 persons, ≤ ~10 events, ≤ ~100 offers)
      loading everything and recomputing is well under a second.
    * `CST-34`, `BUD-08`, `NFR-32` — every figure a user may ask about comes back as a
      `WeddingPlanner.Valuation.Formula`: ordered, labelled, typed, **unrounded** steps
      (`NFR-14`). Rounding happens once, in the web layer, when
      `WeddingPlannerWeb.FormulaPresenter` hands the formula to
      `WeddingPlannerWeb.DisplayComponents.formula/1`.

  ## Rules for every module in this namespace

    * **No database access** except in `WeddingPlanner.Valuation.Snapshot.Loader`, and
      that only reads. **No Phoenix and no `WeddingPlannerWeb`** anywhere.
      `WeddingPlanner.Valuation.PurityTest` enforces both on the compiled modules.
    * **No formatting and no rounding.** Values stay typed (`Money.t()`, counts, rates)
      until the presenter renders them.
    * **Money only through `WeddingPlanner.Money`**: never `Money.new/2` with a string
      (`DR-18`), never raw `Decimal` arithmetic on an amount, never a float.
    * Relations are resolved by id against the snapshot's flat collections, never through
      Ecto association fields.

  ## How the engine slices plug in

    * **G4 (headcount)** — replaces the body of `Headcount.evaluate/3`; adds the persons,
      groups, invitations, opt-outs and presets queries to the loader (whichever of G1–G5
      first persists each), converting stored presets to `WeddingPlanner.Valuation.Preset`.
    * **C3 (offer totals)** — replaces the body of `Offer.total/3`, taking every count from
      `Headcount.evaluate/3`. The categories, services, offers, lines and overrides are
      added to the loader by C1/C2 (and whichever slice first persists overrides).
    * **B3 (budget)** — replaces the body of `Budget.forecast/2`, building on
      `Offer.total/3`. Invoices and invoice lines are added to the loader by B2.
    * **B4 (what-if)** — builds `t:WeddingPlanner.Valuation.Snapshot.change/0` values and
      evaluates the engines twice; nothing in this layer changes for it.

  No slice changes a signature here without the change being agreed first: three streams
  code against them in parallel.
  """
end
