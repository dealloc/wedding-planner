# Glossary

Use these terms consistently in code, UI and conversation.

| Term | Definition |
|---|---|
| **User** | One of the two people who log in to the app (the couple). |
| **Person** | Anyone on the guest list, adult or child. The core unit of the guest list. |
| **Witness** (*getuige*) | A person designated as witness of one of the two users (max. 2 each). Always *accepted* for every event, locked, obligated and certain (PER-20..22). |
| **Group** | An optional, purely organisational container for persons (e.g. a household or a circle of friends). Used for display and bulk actions; carries no invitation semantics of its own. |
| **Host** | A person who brings a +1. |
| **+1 (plus-one)** | A person linked to a host via "guest of". May be unnamed (placeholder). Attends what the host attends unless opted out per event. |
| **+1 status** | *Possible* (the host might bring someone) or *confirmed* (the host will bring someone). |
| **Opt-out** | A record that a +1 does *not* attend one event that its host does. The only per-event state a +1 has; deliberately not an invitation. |
| **Want tier** | How much the couple wants a person there: *yes*, *maybe*, *no*, *obligated* (socially obligated). |
| **Certainty** | How likely a person is to attend if invited: *certain*, *likely*, *uncertain*. |
| **Age category** | *Adult* or *child*. Drives pricing and practical planning. |
| **Event** | One part of the wedding (civil ceremony, church ceremony, reception, dinner, party…). Events may be on different days and may not have a date yet. |
| **Invitation** | The status of one person for one event. +1s never have one. |
| **Headcount preset** | A saved, named filter over invitations that yields live counts per event (adults, children, total). Defaults: *Minimum*, *Likely*, *Maximum*. |
| **Seating plan** | Who sits at which table for one event, under one headcount preset. Computed live, never stored (SEAT-50). |
| **Seating unit** | People who always share a table: a host and their +1, the couple, and everyone joined by *always with* rules (SEAT-10). |
| **Circle** | A named, overlapping set of persons who know each other, with a cohesion. Exists only for seating; not a group (SEAT-20). |
| **Cohesion** | How strongly a circle pulls its members together: *keep together*, *like together*, *know each other*. |
| **Seating rule** | Subject, relation (*always with*, *seat with*, *keep apart*, *never with*), object and reason; sides are persons, circles or the couple (SEAT-30). |
| **Table type** | A size of table the venue provides for one event ("Round, 8–10 seats"), optionally limited ("at most 6"). The plan decides how many to use (SEAT-40, SEAT-45). |
| **Fixed table** | One specific table of an event, such as the head table. Seats exactly who is pinned to it; empty otherwise (SEAT-40, SEAT-42). |
| **Wedding party** | The built-in circle holding the couple and every witness, plus anyone added to it (SEAT-24). |
| **Pin** | Puts a person, the couple or a circle (and so their units) at a fixed table (SEAT-42). *Freezing* a table pins everyone at it, first making it a fixed table if it came from a type. |
| **Loose end** | A seating unit with no pull towards anyone else, so it cannot be placed sensibly (SEAT-62). |
| **Fine anywhere** | A person content at any table; exempt from the stranger penalty and never a loose end (SEAT-35). |
| **Category** | A kind of cost: venue, catering, church, attire, photography… User-defined. |
| **Service** | A comparable row within a category ("catering", "sound system", "garden use"). Services align offers in the comparison matrix. |
| **Wanted priority** | Per service: *not wanted*, *nice-to-have*, *must-have*. |
| **Offer** | A vendor's proposal within a category. Has a status: *considering*, *shortlisted*, *rejected*, *confirmed*. |
| **Offer line** | One priced element of an offer, tied to a service or ad hoc (e.g. a cleaning fee). |
| **Line state** | *Included*, *optional*, *mandatory*, *not offered*, *unknown*. |
| **Pricing basis** | *Flat*, *per adult*, *per child*, *per attendee*. |
| **Variation** | One of several mutually exclusive ways a vendor offers the same service (e.g. cava vs champagne): service lines of one offer sharing a variation name. Exactly one is active per offer and counts toward the total (CST-27). |
| **Override** | A per-offer deviation from the category's wanted services (turn a service on or off for that offer only). |
| **Gap** | A wanted service that an offer does not provide (*not offered*) or for which the price is not known (*unknown*). |
| **Invalid line** | An offer line orphaned by the deletion of the event it counted heads for. Contributes nothing and marks its offer as needing attention. |
| **Frozen selection** | The set of services and optional ad hoc lines captured when an offer is confirmed, so that later changes elsewhere in the category cannot move its committed total. |
| **Formula** | The labelled, human-readable calculation of an offer's total ("Base €4,000 + Dinner adults 72 × €85 …"). |
| **Planning pick** | A non-confirmed offer marked as the working assumption for a category's budget until something is confirmed. |
| **Invoice** | What a vendor actually bills. Static amounts, optional due date, paid/unpaid. |
| **Target** | The budgeted placeholder amount for a category. |
| **Committed** | The live formula total of confirmed offers. |
| **Invoiced / Paid** | Sum of invoices / sum of paid invoices. |
| **Forecast** | Best known expected cost (see budget rules). |
| **Overall budget** | The total amount the couple has available for the wedding. |
| **Task** | A todo item with optional deadline, owner and dependencies. |
| **Effective deadline** | The earliest date a task must be done by, considering its own deadline and everything that depends on it. |
| **Relative deadline** | A deadline expressed as an offset from an event date ("8 weeks before the civil ceremony"). |
| **Milestone** | A dated, non-task item shown on the timeline: event dates and unpaid invoice due dates. |
| **Reference** | A labelled attachment to an offer or invoice: either an uploaded file or a URL. |
| **Enrollment link** | A single-use, expiring link that registers a passkey — for another of your own devices, for a newly created user, or for recovering an account whose devices are all lost. |
| **Setup token** | The operator-supplied secret that allows the very first user to be created. Stops working permanently once any user exists. |
