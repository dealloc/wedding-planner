# Non-functional Requirements and Technical Constraints

These are constraints decided by the users. Everything else about the technical design is open to the implementation team.

## Stack and hosting

- **NFR-01** Elixir with Phoenix **LiveView** for the full UI. No separate SPA frontend.
- **NFR-02** **SQLite** as the only database (via the Ecto SQLite3 adapter).
- **NFR-03** Hosted on **Fly.io** as a **single machine** with a persistent volume. Because of SQLite, the app MUST NOT be scaled to multiple machines. Release tooling (`Dockerfile`, fly config, `rel/` with release commands) MUST be produced as part of the foundation work, before any module is deployed. AUTH-09's operator recovery command depends on it.
- **NFR-04** Continuous backups of the SQLite database **and** uploaded files, in two parts, because one mechanism does not cover both:
  - **Database** — Litestream replicating the SQLite WAL to Fly's S3-compatible storage (Tigris).
  - **Uploaded files** — Litestream does not replicate files on disk. A periodic one-way sync (`rclone`, `aws s3 sync` or equivalent) MUST copy the uploads directory to the same bucket. This does not contradict XC-23: files are still served from the local volume and no object store sits in the request path; the bucket is a backup target only.

  Restoring both MUST be documented and tested once.
- **NFR-05** HTTPS only.

## Money

- **NFR-10** All money values MUST be `%Money{}` structs from **ex_money** (`~> 6.0`), persisted with **ex_money_sql** (`~> 2.1`) using **`Money.Ecto.Map.Type`**. The Postgres-only composite type (`Money.Ecto.Composite.Type`, `money_with_currency`) MUST NOT be used.
- **NFR-11** ex_money 6.0 replaced the `ex_cldr` dependency family with the **`localize`** package and removed the compile-time CLDR backend. Do **not** create a `MyApp.Cldr` backend module or configure `:default_cldr_backend`; configure locales via `config :localize`. Follow the ex_money 6.0 migration guide if older examples suggest otherwise.
- **NFR-12** **All money arithmetic MUST go through ex_money functions** (`Money.add`, `Money.sub`, `Money.mult`, `Money.div`, `Money.round`, …). No arithmetic on raw `Decimal` amounts extracted from money, no floats anywhere, no manual currency handling.
- **NFR-13** No money aggregation in SQL. Totals, formulas and budget roll-ups are computed in Elixir from loaded structs (the stored amount is a string inside JSON and SQL arithmetic on it is unreliable).
- **NFR-14** Rounding policy: calculations keep full precision; rounding to the currency's minor unit happens only for display and when a value represents an actually billed amount (invoice lines are entered and stored rounded).
  Specifically, CST-32's comparisons (`max(computed, minimum charge)`, `max(sum of lines, minimum spend)`) and CST-33's VAT gross-up are performed on **unrounded** values. Rounding is applied once, at the end, to the figure being shown. A formula (CST-34) displays each step rounded but computes from the unrounded chain, so a displayed sub-total may differ from the displayed total by a cent; that is expected and MUST NOT be corrected by rounding earlier.
- **NFR-15** Single app currency: EUR. The currency is still stored with every amount.

## Dates and times

- **NFR-20** **Calendar dates** — event dates, fixed task deadlines, invoice dates, due dates, paid dates — MUST be stored as plain dates (`Date`) without time or time zone. Converting them through UTC can shift them by a day.
- **NFR-21** **Moments in time** — activity entries, record timestamps, passkey usage, enrollment link expiry — MUST be stored as UTC (`DateTime`).
- **NFR-22** UTC moments are displayed in the time zone reported by the user's browser, falling back to an app-wide configurable default time zone when unavailable. That default is **`Europe/Brussels`**, overridable through application configuration.
- **NFR-23** All dates are displayed day-first (`dd/mm/yyyy`, e.g. 21/09/2026) everywhere, including CSV exports. There is no locale detection and no per-user date format setting.

## UX

- **NFR-30** English UI only.
- **NFR-31** Responsive design from the start. Phone-first quality is required for: the todo list, finding and viewing a person, entering an RSVP (invitation status), and the budget overview. The comparison matrix and the timeline are desktop-first but MUST remain usable (e.g. horizontal scrolling) on a phone.
- **NFR-32** Every computed number (headcount, committed, forecast, available) MUST be traceable to its inputs in at most one interaction (formula expansion, preset shown).
- **NFR-33** Calculations update live on every relevant change; at the expected data size (≤ ~150 persons, ≤ ~10 events, ≤ ~100 offers) any view SHOULD recompute in well under a second.

## Quality

- **NFR-40** The worked examples and acceptance criteria in these documents SHOULD be implemented as automated tests.
- **NFR-41** The cost calculation (formula evaluation, headcount evaluation, budget layers) SHOULD be implemented as pure, UI-independent logic so it can be tested exhaustively.
