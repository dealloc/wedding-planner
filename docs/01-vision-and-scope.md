# Vision and Scope

## Problem

The couple has never planned a wedding and both tend to get overwhelmed by planning at this scale. Information is spread across emails, quotes, spreadsheets and memory. The hardest questions are cross-cutting: *"what does adding these people cost?"*, *"which venue is actually cheapest for what we want?"*, *"what do we need to do now, and what is blocked?"*.

## Users

Exactly **two users**: the couple. Both are equal owners with full read/write access to everything. There are no guest-facing, vendor-facing or helper-facing features. There is no concept of roles or permissions beyond "authenticated user".

## Goals

1. **Reduce overwhelm.** Surface what is actionable now; hide what is blocked or irrelevant.
2. **Make cost consequences visible and live.** Every cost that depends on the guest list recalculates when the guest list changes, as a range rather than a single number.
3. **Compare offers fairly.** Put vendor offers with different structures side by side against the same wanted services.
4. **Keep a truthful financial overview.** Target vs committed vs invoiced vs paid, and what is still available.

## Scope of v1

| Module | Summary |
|---|---|
| Authentication | Passkey-only login for two users, device enrollment via one-time links |
| Guests & events | Person-based guest list, optional grouping, +1s, multiple events with optional dates, per-person invitations |
| Headcount | Live, filter-based headcount presets producing ranges per event |
| Offers & comparison | Vendor offers per category, a comparison matrix with toggleable services, structured cost formulas |
| Invoices & budget | Invoices with due dates and paid status, budget layers, overall budget, cash flow, what-if simulation |
| Tasks & timeline | Todo list with dependencies, cascading and relative deadlines, timeline view with milestones |
| Cross-cutting | Activity log, references (files/URLs), CSV export, live multi-user updates |

## Explicitly out of scope for v1 (deferred)

- Meal choices, dietary requirements and allergies
- Seating chart
- Day-of run sheet
- Decision log
- Gifts and thank-you tracking
- RSVP collection by guests, a wedding website, sending invitations or emails of any kind (RSVPs are entered manually)
- Vendor contact management, contracts, and payment schedules beyond a paid/unpaid flag per invoice
- Per-hour pricing
- Automatic linking between categories (e.g. a venue without catering pulling in a caterer's offer)
- Checklist templates ("12 months before…")
- Classic Gantt charts with durations
- Multiple currencies in the UI (the money library supports it; the app uses one currency)
- Non-English UI

The domain model SHOULD NOT make the deferred features harder to add later (most of them hang off Person and Event), but no speculative structures should be built for them.
