# Module: Tasks & Timeline

## Purpose
Primarily the couple's shared **todo list**. Dependencies between tasks provide a cascading view of what blocks what and what must be done by when. There are no durations and no classic Gantt chart.

## Tasks

- **TSK-01** A task has: title, notes, status (*to do*, *in progress*, *done*), owner, optional deadline, zero or more dependencies, and an optional link to a category, offer, invoice or event (navigable).
  **Owner** is a reference to a user, or *shared*, or unassigned. In practice that surfaces as four choices — each of the two users, both, or nobody — but it MUST NOT be stored as a four-value enumeration: `03-domain-model.md` requires the number of users not to be hard-coded, and AUTH-05 allows a third user to be created. *Shared* means every user, not "the other two".
- **TSK-02** A deadline is one of:
  - none
  - a **fixed date**
  - a **relative deadline**: an offset in days or weeks, before or after a chosen event's date ("8 weeks before Civil ceremony")
- **TSK-03** A relative deadline whose event has no date is **unresolved**: shown as such ("8 weeks before Civil ceremony — date not set"), treated as having no deadline for sorting and cascading, and resolved automatically when the event gets a date. Changing the event's date moves the deadline.
- **TSK-04** Tasks have no duration or start date.

## Dependencies

- **TSK-10** A task MAY depend on any number of other tasks. Dependency cycles MUST be rejected at the moment they would be created, with a message naming the cycle.
- **TSK-11 Blocked.** A task is *blocked* while at least one of its dependencies is not *done*.
- **TSK-12** Marking a blocked task as done is allowed but MUST show a warning naming the unfinished dependencies.
- **TSK-13 Effective deadline.** A task's effective deadline is the earliest of: its own resolved deadline, and the effective deadlines of all tasks that depend on it (directly or transitively).
  Example: "Book caterer" (due 1 March) depends on "Confirm venue" (no deadline) → "Confirm venue" has effective deadline 1 March.
- **TSK-14 Conflict.** If a task's own deadline is later than the effective deadline of a task that depends on it, the task MUST show a conflict warning ("due 15 March, but 'Book caterer' waits on it and is due 1 March").
- **TSK-15** A task's detail view shows what it waits on and what waits on it (both directions, transitively expandable).

## Views

- **TSK-20 Todo list** (default, phone-friendly): not-done tasks, sorted by effective deadline (tasks without one last), with quick filters: *actionable* (not blocked), *blocked*, *overdue*, *this week*, *by owner*. Completing a task is one tap.
- **TSK-21 Timeline**: a horizontal time axis showing
  - tasks as points at their effective deadline, colour-coded by status, blocked and overdue
  - dependency arrows between them
  - **milestones**: event dates, and due dates of unpaid invoices (with amount)
  - a "today" marker
  Tasks without an effective deadline and unresolved relative deadlines are listed in a side lane, not placed on the axis.
- **TSK-22** The timeline is desktop-first; on phones it MAY degrade to a chronological list with the same items.
- **TSK-23** Overdue = effective deadline before today and not done.

## Acceptance criteria

- Given A depends on B and B depends on C, when the user tries to make C depend on A, then it is rejected naming A → B → C → A.
- Given "Send invitations" has a relative deadline "12 weeks before Reception" and the Reception has no date, then the task shows as unresolved; when the Reception date is set to 2028-05-13, the deadline becomes 2028-02-19.
- Given an unpaid invoice due 2027-03-01, then it appears as a milestone on the timeline; once paid, it disappears from the timeline.
