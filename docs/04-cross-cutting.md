# Cross-cutting Functional Requirements

## Live collaboration

- **XC-01** Both users may use the app at the same time. Changes made by one user MUST appear on the other user's open screens without a manual refresh.
- **XC-02** Concurrent edits are resolved as last write wins, per field. No locking, no merge UI.

## Activity log

- **XC-10** Every create, update and delete of domain data MUST produce an activity entry: UTC timestamp, user, affected entity (navigable if it still exists), and a human-readable description ("Wannes marked invoice 'Venue deposit' as paid", "Invitation for Anna Peeters to Dinner: invited → accepted").
- **XC-11** The log is viewable globally (newest first, filterable by user, entity type and date range) and per entity (on its detail view).
- **XC-12** A bulk action produces **one summarising entry plus one entry per affected entity**. The summarising entry carries the human-readable description of the action as a whole ("Wannes set 4 people in 'Family Peeters' to invited for Reception"); the per-entity entries are what makes each entity's own history complete (XC-11). Per-entity entries record the summarising entry they belong to, so the global log can collapse them.
- **XC-13** The activity log is read-only and is not an undo mechanism.

## References (files and URLs)

- **XC-20** Offers and invoices can have any number of **references**. A reference has a label and either an uploaded file or a URL.
- **XC-21** Allowed file types: PDF, PNG, JPEG, WebP. Maximum size per file: 10 MB. Uploads from a phone camera MUST work.
- **XC-22** Files are shown inline (image preview, PDF opened in the browser) and are downloadable. URLs open in a new tab.
- **XC-23** File storage should stay minimal: files live alongside the database on the same persistent storage and are included in backups. No external object store is required for files.
- **XC-24** Deleting an offer or invoice deletes its references and their files, after confirmation.

## CSV export

- **XC-30** Each module can export its data as CSV: persons (including group, host, age, want tier, certainty, and one column per event with the effective status), events, headcount (per event × preset), offers with lines, invoices with lines, budget per category and layer, and tasks.
- **XC-31** CSV uses UTF-8 with a BOM (for spreadsheet compatibility), a header row, day-first dates (`dd/mm/yyyy`, see NFR-23), and money as a plain decimal amount plus a currency column.
- **XC-32** Exports reflect current live data, including computed values (headcounts, committed and forecast amounts) for the selected preset or, where relevant, all default presets.

## Deletion

- **XC-40** Every destructive action MUST require confirmation and state what else is affected (e.g. deleting a host deletes their +1s; deleting an event affects invitations, offer lines and relative deadlines).
- **XC-41** When an event referenced by offer lines is deleted, those lines MUST be flagged as **invalid** rather than silently deleted; when an event anchoring a relative deadline is deleted, the task's deadline becomes *none* and the change is logged.
- **XC-42 Effect of an invalid line.** An invalid offer line contributes **nothing** to any total — it is treated as €0 in the offer total, in the comparison matrix and in the committed amount of a confirmed offer. It MUST NOT be silently ignored:
  - the line is shown struck through with the reason ("event deleted"), wherever the offer's lines are listed;
  - the offer carries a *needs attention* marker in the matrix column header, alongside its gap counts (CST-54);
  - if the offer is **confirmed**, its committed total and therefore the category's budget (BUD-02) are affected, so the budget MUST show the same marker against that category rather than letting the figure quietly drop.

  An invalid line is repaired by pointing it at another event or by changing its pricing basis to *flat*; it is never repaired automatically.
