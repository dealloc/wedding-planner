# Module: Guests & Events

## Purpose
Maintain the guest list at the level of individual persons, decide per person which events they are invited to, and capture the signals (want tier, certainty, age) that drive headcount and cost.

## Persons

- **PER-01** The guest list consists of **persons**. Every invitation, count and cost is ultimately per person.
- **PER-02** A person has: name, age category (*adult*/*child*), want tier (*yes*/*maybe*/*no*/*obligated*), certainty (*certain*/*likely*/*uncertain*), optional group, notes.
  **Name** is an optional first name and an optional last name, plus a derived display name — not a single free-text field, so that the list can sort by last name (PER-05) and CSV can export the parts separately (XC-30). Both parts are optional, so a one-word name ("Oma") works. Every person except an unnamed +1 MUST have at least one of the two.
- **PER-03** A person belongs to **at most one** group. Groups are optional and purely organisational.
- **PER-04** Groups MUST support bulk actions that write per-person data, at minimum: set invitation status for an event for all members; set want tier; set certainty. Bulk actions MUST NOT create any group-level state that overrides persons.
- **PER-05** The guest list MUST be viewable both flat (sortable/filterable by every attribute) and grouped by group.
- **PER-06** Persons have no postal address or contact details in v1; the notes field is sufficient.
- **PER-07** Deleting a group does **not** delete its members: they become ungrouped, and the confirmation says how many persons are affected (XC-40). Deleting persons is always done person by person, or through a bulk action that names them.

## +1s

- **PER-10** A +1 is a person with a *guest of* link to a host. The host MUST NOT itself be a +1 (no chains).
- **PER-11** A +1 has a *name known* flag. An unnamed +1 is displayed as "+1 of ⟨host⟩" and counts exactly like any other person.
- **PER-12** A +1 has a **+1 status**:
  - *possible* — the host might bring someone (e.g. unknown whether they have a partner)
  - *confirmed* — the host will bring someone
  Adding a +1 to a host creates the +1 person (status *possible* or *confirmed*, named or unnamed). If the host turns out not to bring anyone, the +1 is deleted. Upgrading *possible* → *confirmed* and filling in the name MUST each be a single action. +1 status and *name known* are independent.
- **PER-13** A +1 has **no invitations of its own**. For every event, the +1's effective status equals its host's status — unless the +1 has **opted out** of that event, in which case the +1 counts as *declined* for that event.
  An opt-out is its own Person × Event record (*plus-one opt-out*, see `03-domain-model.md`), deliberately separate from Invitation: a +1 must never acquire an invitation of its own, because that would let it drift away from its host. Absence of an opt-out means the +1 follows the host. An opt-out on a person who is not a +1 is meaningless and MUST NOT be creatable.
- **PER-14** When the host is not invited to an event, or declines it, the +1 is not attending that event either, regardless of opt-outs. The +1's data is retained.
- **PER-15** A +1 has its own age category. Want tier and certainty are inherited from the host and not editable on the +1, whether it is *possible* or *confirmed*. The +1 status is informational: it never changes headcount or seating (see HC-05).
- **PER-16** Deleting a host MUST delete their +1s, after an explicit confirmation that names them.

## Witnesses (*getuigen*)

- **PER-20** A person MAY be designated a **witness of one of the two users** (the couple). Each user has **at most 2** witnesses. A witness is a regular, non-+1 person; a +1 cannot be a witness. A witness MAY still have a +1 of their own, which follows PER-13 like any other.
- **PER-21** A witness is **always invited to every event, as *accepted*, and this cannot be overridden**: designating a person as witness sets their invitation for every existing event to *accepted*; every event created later gets an *accepted* invitation for each witness; and while a person is a witness their invitation status is locked in every editing surface (single cell, group bulk action, what-if apply). Bulk actions skip witnesses silently, as they do +1s.
- **PER-22** A witness's want tier is forced to *obligated* and certainty to *certain*, and neither is editable while the person is a witness (bulk actions skip them). Removing the witness designation unlocks all of it but changes nothing else: the invitations stay *accepted* and the tier and certainty keep their values until edited.
- **PER-23** Designating and removing a witness is a single action on the person, and is logged (XC-10) with the invitations it creates as children.

## Events

- **EVT-01** An event has a name, optional date, optional free-text location, a sort order, notes and a *couple attends* flag (default on; see HC-11).
- **EVT-02** Events MAY be on different days. Nothing may assume events share a date.
- **EVT-03** An event's date MAY be unknown and set later. Features depending on the date (relative deadlines, milestones) MUST handle "no date yet" explicitly.
- **EVT-04** Events are always displayed in their manual sort order.
- **EVT-05** Deleting an event MUST warn when invitations, offer lines or tasks reference it, and list what will be affected.

## Invitations

- **INVT-01** An invitation is the status of one (non-+1) person for one event: *planned*, *invited*, *accepted*, *declined*. No invitation means *not invited*.
  - *planned* — intended, not yet sent
  - *invited* — sent, no answer yet
  - *accepted* / *declined* — RSVP entered manually
- **INVT-02** The main editing surface SHOULD be a **matrix**: persons (optionally grouped) as rows, events as columns, status per cell, with fast keyboard/tap editing. +1 rows show the derived status and allow toggling the opt-out.
- **INVT-03** RSVPs are entered manually by the users. There is no guest-facing input.
- **INVT-04** There is no waitlist status. A "B-list" is expressed as persons with want tier *maybe* who are not (yet) invited to an event; the guest list MUST be filterable to find them, and the what-if simulation (BUD-20) shows the cost of inviting them.

## Acceptance criteria

- Given Anna is made a witness of Wannes and there are two events, then Anna is *accepted* for both, her cells in the matrix are locked, her want tier is *obligated* and certainty *certain*; a third event created afterwards also has her as *accepted*. Making a third person a witness of Wannes is refused; making one a witness of the other user is allowed.
- Given host Anna is *accepted* for Dinner and her unnamed +1 has no opt-out, then the +1 counts as attending Dinner.
- Given the +1 opts out of Dinner, then Anna still counts and the +1 does not.
- Given Anna changes to *declined* for the Party, then her +1 is not attending the Party, even without an opt-out.
- Given Ben is *invited* and *likely* for Dinner and has a *possible* +1, then the +1 counts in exactly the presets Ben counts in; marking it *confirmed* changes nothing for headcount.
- Given a group "Family Peeters" with 4 members, when the user bulk-sets "invited" for the Reception, then each of the 4 members gets an individual *invited* invitation and each can afterwards be changed individually.
