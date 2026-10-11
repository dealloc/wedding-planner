# Module: Seating

## Purpose
Decide who sits at which table, per event, from what the users know about their guests — not by dragging names around. The users describe the social situation (circles, rules, tables, pins); the system computes a plan that respects it. Like headcount (HC-01), the plan is **never stored**: it is recomputed from current data, for whichever headcount preset is being looked at, so it can never be out of date and every "what if fewer people come?" is just a different preset.

Out of scope: a visual floor plan, and the order of seats around a table.

## Plans and scenarios

- **SEAT-01** An event has a seating plan once it has at least one table type or fixed table (SEAT-40). There is at most one plan per event; it consists of that event's tables and pins plus the guest-wide circles and rules.
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
- **SEAT-24 Wedding party.** There is always exactly one built-in circle, **Wedding party** (cohesion *keep together*). It always contains **the couple and every witness** (PER-20); that part of its membership is derived, so designating or removing a witness changes it with no further action, and neither the couple nor a witness can be taken out of it. Anyone else MAY be added to and removed from it like any circle. It can be renamed and its cohesion changed, but not deleted (`D-43`).

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

- **SEAT-40** The users do not count tables; the venue sets as many as the guests need. An event's tables are described as (`D-42`):
  - **table types** — "Round, 8–10 seats": a name, a minimum and a maximum number of seats (1 ≤ min ≤ max), and OPTIONALLY a **limit** ("at most 6") for when the venue only has so many of that size. A table type stands for as many identical tables as the plan needs, within its limit; the plan numbers them "Round 1", "Round 2", …, skipping numbers whose name a fixed table already has;
  - **fixed tables** — "Head table, 2–8 seats": one specific table with a name and a minimum and maximum. A fixed table seats **exactly who is pinned to it** (SEAT-42), with their seating units, and nobody else; with nothing pinned it stays empty (`D-44`).

  Both have a sort order.
- **SEAT-41** Every table of a plan — a fixed one or one of a type — seats between its minimum and maximum, inclusive. A fixed table MAY stay **empty**; it then costs nothing. Everyone not pinned sits at a table of a type.
- **SEAT-42** A **pin** puts a person, the couple, or a **circle** at a **fixed table** of that event. Pinning a circle pins each of its seated members; pinning anyone pins their whole seating unit. "Wedding party → Head table" is one pin.
- **SEAT-43 Inactive pins.** A pin whose person is not seated in the scenario — for a circle, none of whose members is — is inactive: it is kept unchanged, has no effect, and is listed in the health panel (SEAT-60).
- **SEAT-44 Freeze.** *Freeze table* pins every unit currently at that table in the scenario being viewed. A table of a type is first turned into a fixed table with the same name and seats (taking one from the type's limit, if it has one), so the pins have a table to name. A name already taken in the event gets a suffix ("Round 3 (2)"); when the type's limit was 1, taking it leaves the type nothing to stand for, so the type is deleted. Freezing is offered only on a valid plan, and only where someone sits. *Unfreeze* removes every pin to that table; the fixed table stays until deleted. Freezing is how the users approve part of a plan so that later changes do not move those people. Both are bulk actions (XC-12).
- **SEAT-45 How many tables.** The plan uses **as few tables as a valid plan needs**: every fixed table is available, and the table types make up the rest. When the fewest tables that hold everyone allow no valid plan (two people who must never share a table, while everyone fits at one), the plan uses more, one at a time. Among equally few tables it prefers the fewest empty seats, then the types earlier in sort order. It never uses more tables of a type than its limit. How many of each type a plan uses is a result, shown in the plan, never an input.

## Computing the plan

- **SEAT-50** The plan MUST never be stored; it is computed from current data every time it is needed, and recomputed whenever any of its inputs changes, in either user's session (XC-01). Computation MAY take longer than NFR-33's "well under a second". If it does, it runs in the background: the view stays usable and shows the previous result marked as recalculating until the new one is ready.
- **SEAT-51 Determinism.** The same inputs MUST always produce the same plan, on any machine, for any viewer, at any time. The computation MUST NOT depend on the clock, on elapsed time or on a time budget. It may only depend on the stored data and the preset.
- **SEAT-52 Objective.** Within the hard constraints, the plan SHOULD maximise the pulls (circles, groups, *seat with*) and minimise the pushes (*keep apart*) between people at the same table. It should also avoid **strangers**: a unit with no pull towards anyone at its table outside the unit is penalised heavily, unless every member of the unit is *fine anywhere*. And it should avoid **lone members**: when a circle or group is split over tables, a unit that is the only one of it at its table is penalised in proportion to how many of it sit elsewhere — so six colleagues split 4 + 2 rather than 5 + 1, and one table beats both. The plan is not required to be provably optimal. It MUST find the expected plan in every worked example.
- **SEAT-53 Hard constraints.** A plan MUST satisfy all of: units intact (SEAT-10), table bounds (SEAT-41), *never with* rules, and active pins. If no plan satisfying them is found, the system MUST say so. It MAY show its best attempt, clearly marked as invalid, with every broken hard constraint listed. It MUST NOT present such a plan as valid.
- **SEAT-54 Traceability (NFR-32).** Every table shows its members and its score. For every person, what pulls them to their table and which of their soft rules are broken MUST be visible in at most one interaction.

## Health panel

- **SEAT-60** Next to the inputs, a health panel shows, live for the selected scenario: feasibility (SEAT-61), conflicts (SEAT-61), loose ends (SEAT-62) and inactive pins (SEAT-43).
- **SEAT-61 Blocking problems.** These stop computation, because no valid plan can exist:
  - no table types and no fixed tables;
  - more people than the total maximum seats — only possible when every table type has a limit;
  - a unit larger than the largest table of any type or fixed table;
  - a unit that contains both sides of a *never with* rule (e.g. A *always with* B, B *always with* C, A *never with* C). The message names the chain;
  - someone pinned to two different tables, directly, through a circle or through their unit;
  - more pinned seats at a fixed table than its maximum, or fewer than its minimum (but more than none).

  Non-blocking **conflicts** are listed as warnings:
  - two contradictory soft rules of the same specificity (SEAT-33);
  - a soft rule overruled by a hard one.
- **SEAT-62 Loose ends.** A unit is a loose end when no member has any pull towards anyone outside the unit, and not every member is *fine anywhere*. Loose ends are listed by name: they are the guests the system cannot place sensibly, and therefore the users' to-do list. They are a warning, never blocking.

## Plan view

- **SEAT-70** The plan view shows the plan for the selected scenario, table by table, in table sort order, with the unseated problems from SEAT-53/SEAT-61 if any.
- **SEAT-71 Corrections are inputs.** Every correction made from the plan view edits an input. The plan itself is never edited.
  - Selecting two people offers to create or edit the rule between them, pre-filled.
  - Moving a person to another table creates or changes a pin, and so only a fixed table is a target (SEAT-42). The person's seating unit follows; the unit's other direct pins elsewhere are replaced, so nobody ends up pinned to two tables. A person pinned only through a circle is moved by changing that pin.
  - Freezing and unfreezing a table (SEAT-44).
- **SEAT-72** The plan view SHOULD be able to compare two scenarios and show which units sit at a different table in each.
- **SEAT-73** A CSV export of the plan per scenario (XC-30..32 style) MAY be offered; it is not required for v1.

## Logging and deletion

- **SEAT-80** Creating, editing and deleting circles, circle memberships, rules, tables and pins, and changing *fine anywhere*, are logged (XC-10). The computed plan is not data and is not logged.
- **SEAT-81** Deleting a person removes them from every circle and deletes their rules and pins. Deleting a circle deletes its rules. Deleting a fixed table deletes its pins. Each confirmation states what goes with it (XC-40). Deleting an event deletes its tables and pins, and EVT-05's warning MUST mention them.

## Acceptance criteria

- Given six adults A–F, a table type of exactly 3 seats, circle X {A, B, C} and circle Y {D, E, F}, both *keep together*, then one table seats A, B, C and the other D, E, F.
- Given the same, plus "A *never with* C", then A and C sit at different tables in every computed plan.
- Given Anna has a confirmed +1, then the +1 sits at Anna's table in every scenario that seats both. If the +1 opts out of the event, Anna is a unit of one.
- Given "A *always with* B", "B *always with* C" and "A *never with* C", then the plan is not computed and the health panel names the chain A → B → C.
- Given Dinner with *couple attends* on and "Anna *always with* the couple", then Anna sits at the couple's table. With the flag off, the rule is inactive and Anna is placed like anyone else.
- Given Ben is pinned to the fixed table "Head" and counted by Maximum but not by Minimum, then under Minimum the health panel lists the pin as inactive, and the pin still exists and applies under Maximum.
- Given 11 people and one table type of 4–5 seats limited to 2, then the health panel reports 11 seats needed against 10 available, and no plan is computed.
- Given 3 people and one table type of 8–10 seats, then no valid plan exists (any table used would be below its minimum), and the system says so.
- Given circle "Uni friends" {A, B, Tom, Lisa} *keep together*, a table type of 2–3 seats and "Tom *keep apart* Lisa", then Tom and Lisa sit at different tables.
- Given a person with no circle, no group and no rule, then they are listed as a loose end. Once they are marked *fine anywhere*, they are not.
- Given the same inputs and preset, computing the plan twice yields identical plans.
- Given Dinner with *couple attends* on, two witnesses (one with a confirmed +1), a fixed table "Head" of 2–8 seats and the pin "Wedding party → Head", then Head seats exactly the couple, both witnesses and that +1 — 5 seats — and nobody else.
- Given a fixed table "Head" with nothing pinned to it, then it stays empty in every plan, however many guests there are.
- Given 10 people — 6 in the *keep together* circle "Colleagues", the other 4 sharing a group — and a table type of exactly 5 seats, then no colleague is the only colleague at their table.
- Given 44 people and one table type "Round" of 8–10 seats with no limit, then the plan uses exactly 5 Round tables (Round 1–5), each seating 8–10.
- Given 30 people, a table type "Round" of 10–12 seats limited to 2 and a table type "Square" of 6–8 seats, then the plan uses both Rounds and one Square.
- Given 6 people seated at "Round 1" of a table type "Round" limited to 2, then freezing Round 1 creates the fixed table "Round 1" with the type's seats, pins all six to it and leaves the type limited to 1; unfreezing removes the six pins and keeps the table.
