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

## Seating (`modules/seating.md`)

| # | Given | Expect |
|---|---|---|
| S1 | Adults A–F; a table type of exactly 3 seats; circles X {A, B, C} and Y {D, E, F}, both *keep together* | {A, B, C} at one table, {D, E, F} at the other |
| S2 | S1 plus "A *never with* C" | A and C at different tables |
| S3 | Anna with a confirmed +1; the +1 then opts out of the event | +1 at Anna's table in every scenario seating both; after the opt-out Anna is a unit of one |
| S4 | "A *always with* B", "B *always with* C", "A *never with* C" | Blocking conflict naming A → B → C; no plan computed |
| S5 | Dinner *couple attends* on; "Anna *always with* the couple" | Anna at the couple's table; with the flag off the rule is inactive |
| S6 | Ben pinned to the fixed table "Head"; counted by Maximum, not by Minimum | Under Minimum the pin is listed inactive and kept; it applies under Maximum |
| S7 | 11 people; one table type of 4–5 seats, limited to 2 | "11 seats needed, 10 available"; no plan computed |
| S8 | 3 people; one table type of 8–10 seats | No valid plan; the system says so |
| S9 | "Uni friends" {A, B, Tom, Lisa} *keep together*; a table type of 2–3 seats; "Tom *keep apart* Lisa" | Tom and Lisa at different tables (SEAT-33) |
| S10 | A person with no circle, group or rule; then marked *fine anywhere* | Listed as a loose end; afterwards not |
| S11 | Same inputs and preset, computed twice | Identical plans (SEAT-51) |
| S12 | 44 people; table type "Round" 8–10, no limit | Exactly 5 Rounds (Round 1–5), each seating 8–10 (SEAT-45) |
| S13 | 30 people; "Round" 10–12 limited to 2; "Square" 6–8 | Both Rounds and one Square (SEAT-45) |
| S14 | 6 people; table type 1–6 seats; "A *never with* B" | Two tables, A and B apart — one would hold everyone but allow no valid plan (SEAT-45) |
| S15 | Dinner, couple attends; 2 witnesses, one with a confirmed +1; fixed "Head" 2–8; pin "Wedding party → Head" | Head seats exactly the couple, both witnesses and the +1 (5 seats), nobody else (SEAT-24, SEAT-42) |
| S16 | Fixed "Head" with nothing pinned | Head stays empty in every plan (SEAT-40, D-44) |
| S17 | 10 people: 6 in *keep together* "Colleagues", 4 sharing a group; table type of exactly 5 seats | No colleague is the only colleague at their table — 4 + 2 or 3 + 3, never 5 + 1 (SEAT-52) |
| S18 | 6 people seated at "Round 1" of table type "Round" (limit 2); freeze Round 1, then unfreeze it | Fixed table "Round 1" with the type's seats, six pins, type limit 1; afterwards the six pins are gone and the table stays (SEAT-44) |
| S19 | Scenarios A and B of the same event; A seats {1, 2, 3} and {4, 5, 6}; B seats the same groups under swapped table numbers; then B moves 3 and 4 across; then guest 7 is counted only in B | Swapped numbers: no unit listed. After the move: 3 and 4 listed with their table in A and in B. Guest 7: listed as not seated in A. A blocked or invalid scenario is named, not diffed (SEAT-72) |

Each seating expectation asserts only what every correct plan shares (S1 is unique up to
swapping identical tables), so the examples hold whatever the internal weights are.

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
| Seating | S1–S19 |
