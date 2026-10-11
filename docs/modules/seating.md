# Module: Seating

## Purpose
Decide who sits at which table, per event, from what the users know about their guests — not by dragging names around. The users describe the social situation (circles, rules, tables, pins); the system computes a plan that respects it. Like headcount (HC-01), the plan is **never stored**: it is recomputed from current data, for whichever headcount preset is being looked at, so it can never be out of date and every "what if fewer people come?" is just a different preset.

Out of scope: a visual floor plan, and the order of seats around a table.

## Plans and scenarios

- **SEAT-01** An event has a seating plan once it has at least one table (SEAT-40). There is at most one plan per event; it consists of that event's tables and pins plus the guest-wide circles and rules.
- **SEAT-02 Scenario.** A plan is always evaluated for a **headcount preset** (or an ad hoc filter, HC-07). The persons to seat are exactly those the preset counts for that event (HC-02..HC-05). The preset in use is per-view, not persisted, and defaults to *Likely* (HC-10), and it MUST be visible (HC-08).
- **SEAT-03 The couple.** When the event's *couple attends* flag is set (HC-11), the couple is seated as well. The couple is shown by the users' display names ("Wannes & …"), not as "the couple".

## Seating units

- **SEAT-10** The solver places **seating units**, not individuals. A unit is a set of people who always share a table. Units are formed by:
  - a host and their +1, whenever both are seated in the scenario — automatically, and this cannot be switched off;
  - the couple (SEAT-03);
  - every *always with* rule (SEAT-31), transitively: if A is always with B and B always with C, then A, B and C form one unit.
- **SEAT-11** A unit's size is the number of its members seated in the scenario. A +1 that is opted out of the event (PER-13) or not counted by the preset is not part of it.

## Circles

- **SEAT-20** A **circle** is a named set of persons who know each other: "uni friends", "Wannes' work", "tennis club". A person MAY belong to any number of circles. Circles exist only for seating: they carry no invitation, headcount or cost semantics, and they are not groups (see D-36).
- **SEAT-21** A circle has a **cohesion**: *keep together* (strong), *like together* (medium) or *know each other* (weak).
- **SEAT-22 Groups.** Every group (PER-03) acts as an implicit circle with cohesion *know each other*. This is deliberately the weakest pull: a group says people know each other, not that they must share a table. A group cannot be given a different cohesion; make a circle for that.
- **SEAT-23** Pulls add up: two people who share two circles are pulled together more strongly than two who share one.

## Rules

- **SEAT-30** A **seating rule** has a subject, a relation, an object and an optional reason (free text). Subject and object are each a **person**, a **circle**, or **the couple**, and are different from each other. A rule is symmetric: "A keep apart B" is the same rule as "B keep apart A". There is at most one rule per unordered pair of subject and object; to change it, edit it.
- **SEAT-31** The relation is one of:

| Relation | Kind | Meaning |
|---|---|---|
| *always with* | hard | Merges both sides into one seating unit (SEAT-10) |
| *seat with* | soft | A strong pull to share a table |
| *keep apart* | soft | A strong push to sit at different tables |
| *never with* | hard | No member of one side may share a table with any member of the other |

  There is no *neutral* relation: no rule means neutral. Relations have no user-visible weights (D-37).
- **SEAT-32** A rule with a circle on one or both sides applies to **every pair** of members across the two sides. A person who is on both sides is not paired with themselves.
- **SEAT-33 Precedence.** For any pair of people:
  1. hard rules always apply and cannot be outweighed;
  2. among soft rules and pulls, the **most specific** one decides that pair: person ↔ person (the couple counts as a person here) beats person ↔ circle, which beats circle ↔ circle, which beats shared circle membership (SEAT-21), which beats a shared group (SEAT-22).

  So "Tom *keep apart* Lisa" holds even though both are in the *keep together* circle "Uni friends". Two soft rules of the same specificity that contradict each other for some pair are a conflict (SEAT-61).
- **SEAT-34** A rule whose subject or object is not seated in the scenario (absent person, empty circle, couple not attending) is inactive for that scenario. It is kept and is not flagged.
- **SEAT-35 Fine anywhere.** A person MAY be marked *fine anywhere* (default **off**): they are content at any table, so the stranger penalty (SEAT-52) does not apply to them and they are never a loose end (SEAT-62).

## Tables and pins

- **SEAT-40** A **table** belongs to one event and has a name, a minimum and a maximum number of seats (1 ≤ min ≤ max), and a sort order. The users MAY add several identical tables at once ("9 tables, 8–10 seats, named Table 1–9"); each is then a table of its own.
- **SEAT-41** A table is either **empty** or seats between its minimum and maximum, inclusive. An empty table is not a problem and costs nothing; it is how one set of tables serves both the Minimum and the Maximum scenario.
- **SEAT-42** A **pin** fixes a person, or the couple, to a table of that event's plan. Pinning any member of a unit pins the whole unit there.
- **SEAT-43 Inactive pins.** A pin whose person is not seated in the scenario is inactive: it is kept unchanged, has no effect, and is listed in the health panel (SEAT-60).
- **SEAT-44 Freeze.** *Freeze table* pins every unit currently at that table in the scenario being viewed; *unfreeze* removes every pin to that table. Freezing is how the users approve part of a plan so that later changes do not move those people. Both are bulk actions (XC-12).

## Computing the plan

- **SEAT-50** The plan MUST never be stored; it is computed from current data every time it is needed, and recomputed whenever any of its inputs changes, in either user's session (XC-01). Computation MAY take longer than NFR-33's "well under a second". If it does, it runs in the background: the view stays usable and shows the previous result marked as recalculating until the new one is ready.
- **SEAT-51 Determinism.** The same inputs MUST always produce the same plan, on any machine, for any viewer, at any time. The computation MUST NOT depend on the clock, on elapsed time or on a time budget. It may only depend on the stored data and the preset.
- **SEAT-52 Objective.** Within the hard constraints, the plan SHOULD maximise the pulls (circles, groups, *seat with*) and minimise the pushes (*keep apart*) between people at the same table. It should also avoid **strangers**: a unit with no pull towards anyone at its table outside the unit is penalised heavily, unless every member of the unit is *fine anywhere*. The plan is not required to be provably optimal. It MUST find the expected plan in every worked example.
- **SEAT-53 Hard constraints.** A plan MUST satisfy all of: units intact (SEAT-10), table bounds (SEAT-41), *never with* rules, and active pins. If no plan satisfying them is found, the system MUST say so. It MAY show its best attempt, clearly marked as invalid, with every broken hard constraint listed. It MUST NOT present such a plan as valid.
- **SEAT-54 Traceability (NFR-32).** Every table shows its members and its score. For every person, what pulls them to their table and which of their soft rules are broken MUST be visible in at most one interaction.

## Health panel

- **SEAT-60** Next to the inputs, a health panel shows, live for the selected scenario: feasibility (SEAT-61), conflicts (SEAT-61), loose ends (SEAT-62) and inactive pins (SEAT-43).
- **SEAT-61 Blocking problems.** These stop computation, because no valid plan can exist:
  - more people than the total maximum seats;
  - a unit larger than the largest table;
  - a unit that contains both sides of a *never with* rule (e.g. A *always with* B, B *always with* C, A *never with* C). The message names the chain;
  - members of one unit pinned to different tables;
  - more pinned people at a table than its maximum.

  Non-blocking **conflicts** are listed as warnings:
  - two contradictory soft rules of the same specificity (SEAT-33);
  - a soft rule overruled by a hard one.
- **SEAT-62 Loose ends.** A unit is a loose end when no member has any pull towards anyone outside the unit, and not every member is *fine anywhere*. Loose ends are listed by name: they are the guests the system cannot place sensibly, and therefore the users' to-do list. They are a warning, never blocking.

## Plan view

- **SEAT-70** The plan view shows the plan for the selected scenario, table by table, in table sort order, with the unseated problems from SEAT-53/SEAT-61 if any.
- **SEAT-71 Corrections are inputs.** Every correction made from the plan view edits an input. The plan itself is never edited.
  - Selecting two people offers to create or edit the rule between them, pre-filled.
  - Moving a person to another table creates or changes a pin.
  - Freezing and unfreezing a table (SEAT-44).
- **SEAT-72** The plan view SHOULD be able to compare two scenarios and show which units sit at a different table in each.
- **SEAT-73** A CSV export of the plan per scenario (XC-30..32 style) MAY be offered; it is not required for v1.

## Logging and deletion

- **SEAT-80** Creating, editing and deleting circles, circle memberships, rules, tables and pins, and changing *fine anywhere*, are logged (XC-10). The computed plan is not data and is not logged.
- **SEAT-81** Deleting a person removes them from every circle and deletes their rules and pins. Deleting a circle deletes its rules. Deleting a table deletes its pins. Each confirmation states what goes with it (XC-40). Deleting an event deletes its tables and pins, and EVT-05's warning MUST mention them.

## Acceptance criteria

- Given six adults A–F, two tables of 3–3 seats, circle X {A, B, C} and circle Y {D, E, F}, both *keep together*, then one table seats A, B, C and the other D, E, F.
- Given the same, plus "A *never with* C", then A and C sit at different tables in every computed plan.
- Given Anna has a confirmed +1, then the +1 sits at Anna's table in every scenario that seats both. If the +1 opts out of the event, Anna is a unit of one.
- Given "A *always with* B", "B *always with* C" and "A *never with* C", then the plan is not computed and the health panel names the chain A → B → C.
- Given Dinner with *couple attends* on and "Anna *always with* the couple", then Anna sits at the couple's table. With the flag off, the rule is inactive and Anna is placed like anyone else.
- Given Ben is pinned to Table 1 and counted by Maximum but not by Minimum, then under Minimum the health panel lists the pin as inactive, and the pin still exists and applies under Maximum.
- Given 11 people and two tables of 4–5 seats, then the health panel reports 11 seats needed against 10 available, and no plan is computed.
- Given 3 people and one table of 8–10 seats, then no valid plan exists (the table can neither be empty nor reach its minimum), and the system says so.
- Given circle "Uni friends" {A, B, Tom, Lisa} *keep together*, two tables of 2–3 seats and "Tom *keep apart* Lisa", then Tom and Lisa sit at different tables.
- Given a person with no circle, no group and no rule, then they are listed as a loose end. Once they are marked *fine anywhere*, they are not.
- Given the same inputs and preset, computing the plan twice yields identical plans.
