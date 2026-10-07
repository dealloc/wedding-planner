# Wedding Planner — Functional Documentation

This folder is the **functional hand-over** for a small, private web application that helps a couple plan their wedding. It describes *what* the system must do and *why*.

Beyond the constraints the users have decided themselves — the stack, hosting, money and date handling in `05-non-functional.md`, and the conceptual entities and cardinalities in `03-domain-model.md` — it deliberately does **not** prescribe the technical design: no module structure, no database schema, no routes, no backlog. That is the implementation team's job.

## Audience and intended use

Written for an implementation agent (Claude Code) and the two users. The expected workflow is:

1. Read everything in this folder.
2. Produce a technical implementation plan and backlog from these documents.

All functional decisions have been made with the users. If something is genuinely ambiguous or contradictory, ask rather than guess.

## Reading order

| # | Document | Contents |
|---|---|---|
| 1 | `01-vision-and-scope.md` | Problem, users, goals, v1 scope, explicit non-goals |
| 2 | `02-glossary.md` | Ubiquitous language — use these terms in code and UI |
| 3 | `03-domain-model.md` | Entities, relationships, diagram |
| 4 | `modules/authentication.md` | Passkeys, enrollment links, recovery |
| 5 | `modules/guests-and-events.md` | Persons, groups, +1s, events, invitations |
| 6 | `modules/headcount.md` | Live headcount presets |
| 7 | `modules/offers-and-comparison.md` | Categories, services, offers, comparison matrix, cost formulas |
| 8 | `modules/invoices-and-budget.md` | Invoices, payments, budget layers, simulation |
| 9 | `modules/tasks-and-timeline.md` | Tasks, dependencies, cascading and relative deadlines, timeline |
| 9a | `modules/home.md` | The `/home` dashboard: a read-only summary of the other modules |
| 10 | `04-cross-cutting.md` | Activity log, references (files/URLs), CSV export, live updates |
| 11 | `05-non-functional.md` | Stack constraints, money and date handling, hosting, UX constraints |
| 12 | `06-decisions.md` | Settled decisions and rejected alternatives — do not re-litigate without cause |
| 13 | `07-normative-examples.md` | Every worked example collected as a test checklist |

## Conventions

- **MUST / SHOULD / MAY** follow RFC 2119 meaning.
- Business rules have stable IDs (e.g. `PER-03`, `CST-31`) so plans, tickets, tests and commits can reference them. IDs are permanent: a withdrawn rule is struck through rather than renumbered, and the numbering within a prefix is not necessarily contiguous.
- Worked numeric examples are normative: they SHOULD become automated tests. `07-normative-examples.md` collects them all in one place; an example added to a module document MUST be added there too.
- Money in examples is in EUR and VAT-inclusive unless stated otherwise.
