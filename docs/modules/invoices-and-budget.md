# Module: Invoices & Budget

## Purpose
Keep a truthful, live financial overview: what was budgeted, what is committed, what has been billed, what has been paid, what is still due and when, and what is left. Support "what if" questions about the guest list. This is **not** bookkeeping: no ledgers, accounts, installment plans or tax reporting.

## Invoices

- **BIL-01** An invoice belongs to a category and MAY be linked to a (confirmed) offer. Invoices without an offer are allowed for small purchases that never had a quote.
- **BIL-02** An invoice has: label or number, invoice date, optional **due date**, **paid** flag with **paid date**, one or more lines (label + amount), and references.
- **BIL-03** Invoice amounts are **static** (not formulas) and entered **VAT inclusive** (what is actually paid).
- **BIL-04** An offer MAY have several invoices (e.g. a deposit invoice and a final invoice).
- **BIL-05** A confirmed offer has an **invoicing complete** flag, set when the final invoice has been received.
- **BIL-06** Unpaid invoices with a due date appear as **milestones** on the timeline (see `tasks-and-timeline.md`). Overdue unpaid invoices MUST be highlighted wherever invoices are listed.
- **BIL-07 Variance.** For an offer with invoices, the difference between its committed total (under a chosen preset) and its invoiced total MUST be shown.

## Budget

- **BUD-01** The users set one **overall budget** amount.
- **BUD-02** Per category, the budget shows these layers:

| Layer | Definition | Depends on headcount? |
|---|---|---|
| Target | Category target amount | No |
| Committed | Sum of committed totals of confirmed offers (frozen selection, live formula) | Yes |
| Invoiced | Sum of all invoices in the category | No |
| Paid | Sum of paid invoices | No |
| Outstanding | Invoiced − Paid | No |
| Forecast | See BUD-03 | Yes |

- **BUD-03 Forecast**:
  - For each **confirmed** offer: its invoiced total if *invoicing complete*, otherwise the larger of its committed total and its invoiced total so far.
  - Plus invoices in the category not linked to any offer.
  - If the category has **no** confirmed offer: the larger of (planning pick total if set, else target) and the unlinked invoices. A category with no target set counts as **zero** here, so its forecast is just its unlinked invoices — a category with nothing in it at all forecasts zero rather than being excluded.
- **BUD-04** Layers that depend on headcount MUST be shown per preset (columns for at least the three default presets), producing a **range**.
- **BUD-05 Overall figures.** Totals of every layer across categories, plus:
  - **Available** = overall budget − forecast (per preset)
  - **Spent** = total paid
  - **Outstanding** = total unpaid invoices
- **BUD-06 Cash flow.** Unpaid invoices grouped by due month, with a separate bucket for "no due date". Overdue amounts shown separately.
- **BUD-07 Breakdowns.**
  - By category (the default view).
  - By event: per-person lines are attributed to their event; flat lines, ad hoc lines and invoices are shown as "General".
  - Per guest: forecast ÷ distinct attending persons, per preset.
- **BUD-08** Every committed or forecast amount MUST be expandable into its formula (CST-34).

## Simulation (what-if)

- **BUD-20** From the guest list, the users can select one or more persons (or a group) who are currently not counted, or change their statuses, and see a **preview** of the effect: headcount per event and forecast delta per category and overall, per preset. Nothing is saved until the user applies the change.
- **BUD-21** The delta MUST be computed by evaluating the full forecast with and without the change — not by summing per-person rates — so that included quantities, minimum charges and minimum spends are respected.
- **BUD-22** A per-person "marginal cost" SHOULD be available on the person detail view, computed the same way (forecast with vs. without that person, including their +1).
- **BUD-23** Offer-side what-if is covered by the comparison matrix (toggling services) and by the planning pick; no separate scenario mechanism exists (see `06-decisions.md`).

## Acceptance criteria

- Given the confirmed Venue A (Likely total €11,726) with a paid deposit invoice of €3,000 and invoicing not complete, then Venue forecast (Likely) = €11,726, Paid = €3,000, Outstanding = €0, Invoiced = €3,000, variance = €8,726 not yet invoiced.
- Given the final invoice of €8,900 arrives and invoicing is marked complete, then forecast = €11,900 (3,000 + 8,900), and variance shows +€174 above committed.
- Given the Attire category has no offers and a target of €2,500, then its forecast is €2,500 under every preset.
- Given a what-if adds a household of 2 adults + 1 child invited to Dinner, then the preview shows the recomputed Venue A total, not simply 2 × €85 + €40 + 3 × €12.
