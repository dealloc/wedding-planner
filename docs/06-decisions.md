# Settled Decisions

These were decided deliberately during analysis. Revisit only with a concrete reason.

| # | Decision | Rationale | Rejected alternative |
|---|---|---|---|
| D-01 | The guest list is **person-based**; groups are optional and organisational | Many guests are individuals; household-based invitations would be cumbersome | Household as the unit of invitation |
| D-02 | A +1 is a **linked person** that follows its host, with a per-event opt-out | A +1 doesn't exist without their host; still needs to count and cost | Boolean "+1 allowed" flag on the host |
| D-03 | Headcount is **never stored**, always computed via **presets** producing ranges | There is no single true number; ranges drive negotiations and budget | A stored guest count |
| D-04 | Offers are structured as **lines with states and pricing bases**, compared in a **matrix** | Offers differ in structure; fair comparison requires aligned services and toggles | Free-form offers with a single price; full vendor management |
| D-05 | Pricing bases are **flat and per person** only | Per-hour pricing is rare in practice for these vendors | Per-hour pricing (dropped) |
| D-06 | Formulas are **generated from structured data**, never typed by users | Transparency without breakage when data changes | Spreadsheet-style free expressions |
| D-07 | Missing services are **flagged**, not filled from other categories | Cross-category linking adds significant complexity for limited gain | Automatic linking to other categories' offers |
| D-08 | **Offers and invoices are separate** entities | What was proposed differs from what is billed; variance must be visible | Override amounts / adjustment lines on the offer |
| D-09 | Invoices carry **no payment structure beyond a due date and a paid flag** (they still have a date, lines and references, see BIL-02) | Enough for spent/outstanding/available and cash flow; avoids bookkeeping | Payment schedules, ledgers, partial payments |
| D-10 | Tasks have **deadlines but no durations**; no classic Gantt | The users won't estimate durations; cascading deadlines give the value | Gantt with durations |
| D-11 | **No named scenarios** | Presets (guest side), matrix toggles and planning pick (cost side) cover the what-if needs | Named scenario copies of the plan |
| D-12 | **Passkeys only** with enrollment links | Two users, personal devices; no passwords to manage | Passwords, OAuth, identity-aware proxy |
| D-13 | No guest- or vendor-facing features; RSVPs entered manually | Two users only; manual entry is fine at this scale | RSVP website/forms |
| D-14 | Elixir/Phoenix LiveView + SQLite on Fly.io (single machine) | Matches the owner's stack; live multi-user updates for free; tiny data | Postgres, separate SPA, multi-machine |
| D-15 | ex_money for all money, `Money.Ecto.Map.Type` for storage | Correct currency arithmetic; the composite type is Postgres-only | Integer cents, raw Decimals |
| D-16 | Each person belongs to **at most one group**; no addresses or contact details in v1 | Keeps bulk actions unambiguous; the app sends nothing | Multiple groups/tags; contact management |
| D-17 | A +1 **inherits want tier and certainty** from the host and has a **possible / confirmed** status; a possible +1 is capped at *uncertain* | Two-stage +1s without adding a new headcount filter dimension | Separate "may bring" flag; +1s with independent attributes |
| D-18 | **No waitlist status**; the B-list is want tier *maybe* without an invitation | The want tier and what-if simulation already cover it | Waitlist invitation status |
| D-19 | Default presets: Minimum (certain), Likely (certain + likely), Maximum (any certainty), all over planned/invited/accepted | Covers worst, expected and best case; possible +1s land in Maximum only | — |
| D-20 | **Multiple confirmed offers per category** are allowed; categories are as granular as the users want | Attire per person, separate ceremony and party venues | One confirmed offer per category |
| D-21 | **VAT**: per-offer basis and default rate, per-line override; everything compared and budgeted VAT inclusive; invoices entered VAT inclusive | Offers mix VAT treatment and rates; invoices are what is paid | Comparing mixed VAT bases |
| D-22 | **Planning pick** per category until an offer is confirmed | Makes guest-list simulation meaningful before anything is booked | Target-only budgeting until confirmation |
| D-23 | Forecast = larger of committed and invoiced until **invoicing complete** | A deposit invoice must not make the forecast drop | Invoiced amount replaces committed immediately |
| D-24 | Dates **day-first everywhere** (UI and CSV); timestamps in the **browser's time zone** with a configurable fallback | Browser locale reports language, not regional format, and would yield US dates | Locale detection; per-user format settings |
| D-25 | Offer amounts are entered in the **offer's own VAT basis**; each line is grossed up on **its own rate** before summing; **minimum spend is VAT inclusive** (CST-36) | Offers mix rates within one quote (food vs. drinks), so a single gross-up at the end is wrong; a minimum spend is a floor on what is actually paid | Summing then applying one rate; expressing minimums VAT exclusive |
| D-26 | An offer line orphaned by a deleted event is **flagged invalid, contributes €0, and marks the offer and its category as needing attention** (XC-42) | Money must never disappear from the budget silently; deleting the line would lose the price that was negotiated | Deleting the lines; keeping them at their last computed value |
| D-27 | Confirmation freezes **services and optional ad hoc lines, not individual lines**; a later line for a frozen-in service counts, one for a frozen-out service needs an explicit, logged extension of scope (CST-43) | CST-43 allows corrections to confirmed offers, so the freeze has to be over something more stable than line identity | Freezing line IDs; forbidding edits after confirmation |
| D-28 | Task **owner is a user reference plus a *shared* flag**, not a four-value enum (TSK-01) | `03-domain-model.md` forbids hard-coding the user count and AUTH-05 can create a third user | Enum of user A / user B / both / unassigned |
| D-29 | A person's name is **two optional fields** (first, last) plus a derived display name (PER-02) | The list sorts by last name and CSV exports the parts separately; both optional so "Oma" and unnamed +1s work | One free-text name field |
| D-30 | A +1's per-event opt-out is **its own Person × Event record**, never an Invitation | A +1 that could hold an invitation could drift away from its host, which D-02 exists to prevent | Reusing Invitation with an extra status |
| D-31 | Preset selection for single-figure views is **per-view, not persisted**, defaulting to *Likely* (HC-10) | Two people on the same screen must be able to discuss different cases without changing each other's view | Per-user setting; app-wide setting |
| D-32 | Uploaded files are backed up by a **separate periodic sync** to the same bucket Litestream writes to (NFR-04) | Litestream replicates the SQLite WAL only; it cannot cover files on disk, and XC-23 rules out an object store in the request path | Litestream alone; serving files from an object store |
| D-33 | The bootstrap **setup token is operator-supplied through configuration**, never generated or logged by the app (AUTH-03) | Survives a restart, and never lands in the logs of an internet-facing machine | Printing a generated token to the server log |
| D-34 | A service with offer lines **cannot be deleted** — it is merged away or set to *not wanted* (CST-06) | Deleting it would destroy prices that were negotiated and quoted | Cascading delete of its offer lines |

## Detailed defaults (agreed)

| Topic | Rule |
|---|---|
| Sessions | 30 days, sliding (AUTH-10) |
| Enrollment links | Single-use, 15 minutes (AUTH-06) |
| Last passkey | Cannot be revoked from the UI (AUTH-08) |
| Uploads | PDF, PNG, JPEG, WebP; 10 MB per file (XC-21) |
| Blocked tasks | May be marked done, with a warning naming unfinished dependencies (TSK-12) |
| Task owner | A user, *shared*, or unassigned — stored as a reference, not an enum (TSK-01, D-28) |
| Bulk action logging | One summarising entry **plus** one entry per affected entity (XC-12) |
| Default time zone | `Europe/Brussels` when the browser reports none (NFR-22) |
| Un-confirming an offer | Always returns to *shortlisted*, whatever the prior status (CST-42) |
| Empty category target | Counts as zero in the forecast, not as "excluded" (BUD-03) |
| Deleting a group | Members become ungrouped; no persons are deleted (PER-07) |
| Deleting an event | Offer lines referencing it are flagged invalid; relative deadlines anchored to it become *none* and are logged (XC-41) |
| Services | Renameable, reorderable, mergeable (CST-04) |
| Rejected offers | Hidden in the matrix by default, can be shown (CST-55) |
| CSV encoding | UTF-8 with byte-order mark (XC-31) |
| Variations of a service | Optional variation name on service lines; same-named lines form one variation; one active per offer, choice stored as a *chosen* mark on the lines (CST-27) | Reuses lines and the existing total engine; a dropdown in the matrix cell | A separate variation-group entity; a map of choices on the offer (the JSON transfer codec has no map type); label on service lines (CST-20 keeps *service xor label*); cheapest-as-base with deltas |
| Witnesses | A person field *witness of* (a user); the locked *accepted* invitations are real rows, kept in place by every write path (PER-20..23) | The headcount, matrix and export engines need no special case | Deriving a virtual *accepted* status at every read site |
| Deleting activity entries | Allowed from the global log, single or multiple, with confirmation; not logged (XC-13) | The log accumulates noise (e.g. a rename saved per keystroke) the users want to clean up | A strictly append-only log |
