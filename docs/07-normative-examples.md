# Normative Examples

`README.md` states that worked numeric examples are normative and SHOULD become automated
tests. This is the checklist of every one of them, with its expected result, so that no
example is quietly left unimplemented.

Each row names the document it comes from and the build slice that owns it. **Every figure
below was re-derived by hand during the documentation audit and is arithmetically
correct** — they are safe to freeze as test fixtures rather than recomputed from the code.

## Shared fixtures

The offer and budget examples share one guest-list fixture. Implementations SHOULD build it
once and reuse it, so the numbers stay comparable across modules.

| Fixture | Value |
|---|---|
| Event | **Dinner** |
| Headcount, preset **Likely** | 72 adults + 6 children = 78 attendees |
| Headcount, preset **Minimum** | 60 adults + 4 children = 64 attendees |

The headcount examples use their own, unrelated ten-person fixture.

## Headcount (`modules/headcount.md`)

| # | Given | Expect |
|---|---|---|
| H1 | 10 persons with Dinner invitations: 4 *accepted* (any certainty), 3 *invited*+*certain*, 2 *invited*+*likely*, 1 *planned*+*uncertain* | Minimum = 7, Likely = 9, Maximum = 10 |
| H2 | H1, plus one of the accepted persons has a *confirmed* unnamed adult +1 with no opt-out | Every preset +1 → 8 / 10 / 11 |
| H3 | H1, but that +1 is *possible* | Only Maximum +1 → 7 / 9 / 11 |
| H4 | A person with no invitation to Dinner, any want tier | Counts in no preset for Dinner |

## Guests and events (`modules/guests-and-events.md`)

| # | Given | Expect |
|---|---|---|
| G1 | Host Anna *accepted* for Dinner, unnamed +1, no opt-out | +1 counts as attending Dinner |
| G2 | G1, +1 opts out of Dinner | Anna counts, +1 does not |
| G3 | Anna *declined* for Party | +1 not attending Party, even with no opt-out |
| G4 | Ben *invited* + *likely* for Dinner with a *possible* +1 | +1 in Maximum only; once *confirmed*, in Likely and Maximum |
| G5 | Group "Family Peeters" (4 members), bulk-set *invited* for Reception | 4 individual invitations, each separately editable afterwards |

## Offers (`modules/offers-and-comparison.md`)

| # | Given | Expect |
|---|---|---|
| O1 | Venue A, all VAT inclusive, preset **Likely** | **€11,726** |
| O2 | Venue A, preset **Minimum** | **€11,478** |
| O3 | Venue B has no Catering line, Catering is *must-have* | Prominent gap warning; total excludes catering and is marked not like-for-like |
| O4 | Caterer C, VAT **exclusive**, rates 12% and 21%, min. charge €200 excl., min. spend €7,000 incl., preset **Likely** | **€7,641.50** (minimum spend does not bite) |
| O5 | Caterer C, preset **Minimum** | **€7,000.00** (sum is €6,344.40; minimum spend bites) |
| O6 | Caterer C, Likely, computed in the wrong order | Summing then applying one 21% rate gives €8,046.50, and applying the minimum spend before VAT gives €8,470 under Minimum. Both are wrong — CST-36 fixes the order, and these two figures make a good regression test |
| O7 | Offer with a common Drinks line (flat €50) and two variations of Drinks, Cava (flat €100) and Champagne (flat €160); no choice made | **€150** (first variation active). Choosing Champagne → **€210**; deleting the Champagne line again falls back to Cava → **€150** (CST-27) |

O4–O6 exist specifically to pin down CST-36; without them the VAT-exclusive path has no
normative coverage.

## Invoices and budget (`modules/invoices-and-budget.md`)

| # | Given | Expect |
|---|---|---|
| B1 | Confirmed Venue A (Likely €11,726), paid deposit €3,000, invoicing **not** complete | Forecast €11,726 · Paid €3,000 · Invoiced €3,000 · Outstanding €0 · variance €8,726 not yet invoiced |
| B2 | B1 plus a final invoice of €8,900, invoicing marked complete | Forecast €11,900 · variance **+€174** above committed |
| B3 | Attire category: no offers, target €2,500 | Forecast €2,500 under every preset |
| B4 | What-if adds 2 adults + 1 child invited to Dinner | Preview shows the recomputed Venue A total — **not** 2 × €85 + €40 + 3 × €12 |

B4 is the test that enforces BUD-21: the delta must come from evaluating the whole forecast
twice, so included quantities, minimum charges and minimum spends are respected.

## Tasks and timeline (`modules/tasks-and-timeline.md`)

| # | Given | Expect |
|---|---|---|
| T1 | A depends on B, B depends on C; user makes C depend on A | Rejected, naming the cycle A → B → C → A |
| T2 | "Book caterer" due 1 March depends on "Confirm venue" (no deadline) | "Confirm venue" has effective deadline 1 March |
| T3 | Own deadline 15 March, a dependent task due 1 March | Conflict warning naming the dependent task |
| T4 | "Send invitations", relative deadline "12 weeks before Reception", Reception has no date | Shown unresolved; when Reception is set to **2028-05-13**, deadline becomes **2028-02-19** |
| T5 | Unpaid invoice due 2027-03-01 | Appears as a timeline milestone; disappears once paid |

## Authentication (`modules/authentication.md`)

| # | Given | Expect |
|---|---|---|
| A1 | No users exist | Only the setup flow is reachable, and it requires the setup token |
| A2 | User logged in on a laptop generates a device link, scans the QR on a phone | Phone registers a passkey and logs in as the same user |
| A3 | An enrollment link already used once | Rejected on reuse |
| A4 | An enrollment link older than its expiry | Rejected |

## Coverage

| Slice | Owns |
|---|---|
| Authentication | A1–A4 |
| Guests & events | G1–G5 |
| Headcount | H1–H4 |
| Offers & comparison | O1–O6 |
| Invoices & budget | B1–B4 |
| Tasks & timeline | T1–T5 |
