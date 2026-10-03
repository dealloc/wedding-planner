# Module: Offers & Comparison

## Purpose
Capture offers from vendors (venues, caterers, churches, attire…) in a structured way, compare them side by side in a **matrix** of services × offers, toggle services on and off to simulate prices, and see how each total depends on the guest list. This is **not** a vendor-management or procurement system.

## Categories and services

- **CST-01** Categories are user-defined (venue, catering, church, attire, photography…), each with an optional **target** amount and a sort order.
- **CST-02** Each category has its own list of **services**: the rows of its comparison matrix. Services are created on the fly while entering offers.
- **CST-03** Each service has a **wanted priority**: *not wanted*, *nice-to-have* or *must-have*. Wanted = nice-to-have or must-have. This is the category-wide selection used to compare all offers fairly.
- **CST-04** Services SHOULD be renameable, reorderable and **mergeable** (two services discovered to be the same thing are merged, and all offer lines move to the surviving service).
- **CST-05** Categories MAY be as granular as the users like (e.g. separate categories for the ceremony venue and the party venue, or one attire category per person). Multiple confirmed offers per category are allowed (see CST-40).
- **CST-06 Deleting a service.** A service with no offer lines is deleted after a plain confirmation. A service that has offer lines MUST NOT be deleted: the confirmation offers **merge into another service** (CST-04) or **set its wanted priority to *not wanted*** instead, which removes it from every comparison without destroying priced data. Deleting a service that is part of a confirmed offer's frozen selection (CST-40) is never offered.

## Offers

- **CST-10** An offer belongs to a category and has: vendor name, optional URL, notes, status (*considering*, *shortlisted*, *rejected*, *confirmed*), VAT basis (CST-33), optional **minimum spend**, and references (files/URLs, see `04-cross-cutting.md`).
- **CST-11** A simple offer (e.g. a dress: one vendor, one flat price) MUST be enterable in a single short form without touching services or the matrix. Internally it is an offer with one mandatory flat line.

## Offer lines

- **CST-20** An offer consists of lines. A line refers to a **service** of the category, **or** is **ad hoc** with its own label (e.g. "Base price", "Cleaning fee").
- **CST-21** Each line has a **state**:

| State | Meaning | Counts toward total |
|---|---|---|
| Included | Part of what you get without extra charge | Contributes €0; service is provided |
| Optional | Available at extra cost | Only if effectively wanted (CST-24) |
| Mandatory | Always charged | Always |
| Not offered | Vendor does not provide it | €0; a gap if wanted |
| Unknown | Not yet asked / not specified | €0; a gap if wanted |

- **CST-22** Ad hoc lines can only be *mandatory* or *optional*. An optional ad hoc line has its own on/off toggle, default off.
- **CST-23** A service MAY have several lines within one offer (e.g. an adult rate and a child rate for catering).
- **CST-24 Effective selection.** For an offer, a service is *effectively wanted* if its category wanted priority is nice-to-have or must-have, unless an **override** for that offer turns it off, or it is not wanted and an override turns it on.
- **CST-25 Gaps.** If a service is effectively wanted and the offer's lines for it are *not offered* or *unknown*, or the offer has no line for it at all (treated as *unknown*), the offer has a **gap**:
  - must-have + not offered → prominent warning
  - nice-to-have + not offered → subtle marker
  - unknown (any wanted priority) → "ask the vendor" marker
  Gaps never add cost. There is no automatic linking to other categories.
- **CST-26** A line MAY carry free-text **notes** (e.g. "excludes drinks", "quote valid until June"). Notes are informational: they never affect a total or a gap. They are edited in the line editor, shown on the line's row on the offer page, and changes to them are logged like any other line field (XC-10).

## Pricing

- **CST-30** Pricing basis per line: *flat*, *per adult*, *per child*, *per attendee* (adults + children). There is no per-hour pricing.
- **CST-31** Per-person lines MUST reference an event. The count is the evaluated headcount preset (see `headcount.md`) for that event, restricted to the basis's age category.
- **CST-32** Modifiers, all optional. CST-36 fixes the order in which they apply:
  - **Included quantity** (per-person lines): only persons above this number are billed. `billable = max(0, count − included)`.
  - **Minimum charge** (any line): `line subtotal = max(computed, minimum charge)`, in the offer's own VAT basis.
  - **Minimum spend** (offer): `offer total = max(sum of line totals, minimum spend)`, VAT inclusive.
- **CST-33** VAT handling: each offer declares whether its amounts are *VAT inclusive* or *VAT exclusive*. For exclusive offers, a VAT rate is set on the offer and MAY be overridden per line (offers can mix rates, e.g. food vs. drinks). Everything displayed for comparison and budgeting is **VAT inclusive**.
- **CST-34 Formula.** Every offer total MUST be displayable as a labelled formula showing each counted line, its inputs and its result, the preset used, and any minimum applied. Formulas are generated from structured lines; users never type expressions.
- **CST-35** All money arithmetic follows `05-non-functional.md` (ex_money, no floats, rounding policy).
- **CST-36 Order of operations.** Every amount entered against an offer — line amounts, per-line minimum charges — is expressed in **that offer's own basis**. The **minimum spend is always VAT inclusive**, because it is a floor on what will actually be paid. An offer total is evaluated in this order, and no other, because each step changes the result:

  1. **Count** — the evaluated headcount preset for the line's event, restricted to the basis's age category. Flat lines count 1.
  2. **Included quantity** — `billable = max(0, count − included)`.
  3. **Extend** — `computed = amount × billable`.
  4. **Minimum charge** — `line subtotal = max(computed, minimum charge)`, both in the offer's basis.
  5. **VAT** — for a VAT-exclusive offer, `line total = line subtotal × (1 + rate)`, using the line's own rate if it overrides the offer's. For a VAT-inclusive offer, `line total = line subtotal`. **Each line is grossed up separately**; summing first and grossing up once is wrong as soon as two lines carry different rates, which D-21 explicitly expects.
  6. **Minimum spend** — `offer total = max(sum of line totals, minimum spend)`, VAT inclusive on both sides.

  Every step is computed unrounded; rounding happens only on display (NFR-14).

## Comparison matrix

- **CST-50** Per category, a matrix with **offers as columns** and **services as rows**, followed by an "other charges" section for ad hoc lines, and a **totals row**.
- **CST-51** Rows are grouped by wanted priority (must-have, nice-to-have, not wanted). Changing a service's wanted priority from the row header recalculates all offers immediately.
- **CST-52** Each cell shows the state and the price summary (e.g. "€85 / adult · €40 / child"). Per-offer overrides are toggled from the cell and visibly marked.
- **CST-53** The totals row is computed for a selectable headcount preset, and MUST additionally show the range across the default presets (Minimum–Maximum). This matches BUD-04 and goal 2 in `01-vision-and-scope.md`: a guest-dependent cost is always shown as a range, never as a single number.
- **CST-54** Column headers show vendor, status, VAT basis, and gap counts (warnings / markers / unknowns).
- **CST-55** Rejected offers are hidden by default and can be shown.

## Confirmation

- **CST-40** Setting an offer to *confirmed* **freezes its effective selection** (which services and optional ad hoc lines are on). Later changes to wanted priorities or overrides MUST NOT change a confirmed offer's committed total.
  The freeze captures **services and optional ad hoc lines, not individual lines**. That matters because CST-43 still allows the lines themselves to be edited afterwards.
- **CST-41** A confirmed offer's **committed** total remains a live formula: it still follows the guest list through the headcount preset.
- **CST-42** A confirmed offer can be un-confirmed after an explicit confirmation; its frozen selection is discarded and it returns to *shortlisted*, whatever its status was before confirmation. This is deliberate: an offer that has been confirmed once has been negotiated, so *considering* would understate it, and restoring the prior status would mean remembering state nobody looks at.
- **CST-43** Lines of a confirmed offer MAY still be edited (corrections); every such edit is recorded in the activity log. Because the freeze is over services rather than lines (CST-40):
  - a **new line for a service already in the frozen selection** counts toward the committed total immediately;
  - a **new line for a service outside it** does not count, and is shown greyed out with an "add to confirmed scope" action. Taking that action extends the frozen selection and is itself logged;
  - a **new optional ad hoc line** starts off, exactly as CST-22 says, and turning it on extends the frozen selection in the same way;
  - **deleting the last line for a frozen-in service** leaves that service in the frozen selection, contributing nothing, and the offer is marked as having a gap (CST-25) so the loss is visible rather than silent.

  The rule behind all four: the guest list may move a confirmed offer's total, and corrections may move it, but nothing that happens elsewhere in the category ever may.
- **CST-44** **Planning pick**: in a category without a confirmed offer, the users MAY mark one non-rejected offer as the *planning pick*. The budget then uses its total instead of the category target (see `invoices-and-budget.md`). This makes guest-list simulation meaningful before anything is booked.

## Worked example (normative)

Category **Venue**. Services: Seating (nice-to-have), Catering (**must-have**), Sound (nice-to-have), Garden ceremony (not wanted), Late-night snack (nice-to-have). All amounts VAT inclusive. Preset **Likely** gives, for the Dinner event, 72 adults + 6 children = 78 attendees.

**Venue A**

| # | Line | State | Basis | Amount | Modifiers | Result |
|---|---|---|---|---|---|---|
| 1 | Base price (ad hoc) | mandatory | flat | €4,000 | | €4,000 |
| 2 | Seating | mandatory | per attendee, Dinner | €12 | included 50 | (78 − 50) × €12 = €336 |
| 3 | Catering | optional | per adult, Dinner | €85 | min. charge €6,800 | max(72 × €85 = €6,120; €6,800) = €6,800 |
| 4 | Catering | optional | per child, Dinner | €40 | | 6 × €40 = €240 |
| 5 | Sound | included | | | | €0 |
| 6 | Garden ceremony | optional | flat | €500 | | not wanted → excluded |
| 7 | Cleaning fee (ad hoc) | mandatory | flat | €350 | | €350 |
| 8 | Late-night snack | unknown | | | | "ask the vendor" marker |

**Total (Likely) = €11,726.** (Mandatory lines count regardless of the service's wanted priority.)

The same offer under preset **Minimum** (Dinner: 60 adults + 4 children = 64 attendees):

| # | Line | Result |
|---|---|---|
| 1 | Base price | €4,000 |
| 2 | Seating | (64 − 50) × €12 = €168 |
| 3 | Catering, adults | max(60 × €85 = €5,100; €6,800) = €6,800 |
| 4 | Catering, children | 4 × €40 = €160 |
| 7 | Cleaning fee | €350 |

**Total (Minimum) = €11,478.**

**Venue B** has no line for Catering, or a *not offered* line → prominent must-have warning in its column; its total excludes catering, and the warning makes clear the totals are not like-for-like.

## Worked example: VAT exclusive, mixed rates, minimum spend (normative)

Exercises the parts CST-36 orders that the Venue example above does not: a **VAT-exclusive**
offer, **two different VAT rates** within it, a **minimum charge** on an ad hoc line, and a
**minimum spend** that bites under one preset and not the other.

Category **Catering**, offer **Caterer C**. VAT basis *exclusive*, default rate **21%**,
minimum spend **€7,000 (VAT inclusive)**. Services: Dinner catering (**must-have**), Drinks
(nice-to-have). Preset **Likely** gives, for Dinner, 72 adults + 6 children = 78 attendees.

| # | Line | State | Basis | Amount (excl.) | Rate | Modifiers |
|---|---|---|---|---|---|---|
| 1 | Dinner catering | mandatory | per adult, Dinner | €60 | 12% | |
| 2 | Dinner catering | mandatory | per child, Dinner | €30 | 12% | |
| 3 | Drinks | optional | per attendee, Dinner | €25 | 21% (offer default) | |
| 4 | Travel (ad hoc) | mandatory | flat | €150 | 21% (offer default) | min. charge €200 excl. |

**Likely** — each line is extended, floored, then grossed up on its own rate:

| # | Subtotal (excl.) | × rate | Line total (incl.) |
|---|---|---|---|
| 1 | 72 × €60 = €4,320 | × 1.12 | €4,838.40 |
| 2 | 6 × €30 = €180 | × 1.12 | €201.60 |
| 3 | 78 × €25 = €1,950 | × 1.21 | €2,359.50 |
| 4 | max(€150; €200) = €200 | × 1.21 | €242.00 |

Sum = €7,641.50. Minimum spend €7,000 does not bite. **Total (Likely) = €7,641.50.**

**Minimum** (Dinner: 60 adults + 4 children = 64 attendees):

| # | Subtotal (excl.) | × rate | Line total (incl.) |
|---|---|---|---|
| 1 | 60 × €60 = €3,600 | × 1.12 | €4,032.00 |
| 2 | 4 × €30 = €120 | × 1.12 | €134.40 |
| 3 | 64 × €25 = €1,600 | × 1.21 | €1,936.00 |
| 4 | max(€150; €200) = €200 | × 1.21 | €242.00 |

Sum = €6,344.40, which is below the minimum spend. **Total (Minimum) = €7,000.00.**

Note what would go wrong under a different order: summing the four subtotals (€6,650 under
Likely) and applying a single 21% would give €8,046.50 rather than €7,641.50, because
lines 1 and 2 are taxed at 12%. Applying the minimum spend before VAT would give €8,470
under Minimum rather than €7,000.
