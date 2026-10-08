# Module: Headcount

## Purpose
There is no single "number of guests". Headcount is always computed **live** from the guest list, through named filters, producing a **range** (e.g. minimum / likely / maximum) per event, split into adults and children.

## Rules

- **HC-01** Headcount MUST never be stored; it is computed from current data every time it is needed.
- **HC-02** A **headcount preset** is a named, saved filter with the following criteria (each a set of allowed values; empty = no restriction):
  - invitation statuses
  - effective certainties (see HC-04)
  - want tiers
  - age categories
  - groups
- **HC-03** Evaluating a preset for an event yields: adults, children, total. Evaluating it for "all events" yields the number of **distinct persons counted for at least one event** — that is, persons the preset counts under HC-02/HC-04/HC-05 for at least one event. "Counted" is not the same as "attending": a *planned* invitation is counted by all three default presets although nothing has been sent yet. A person counted for three events contributes 1.
- **HC-04 Effective certainty.** A person who has *accepted* an event is treated as *certain* for that event. A person who has *declined* is never counted, whatever the filter.
- **HC-05** +1s are evaluated with their host's invitation status (PER-13/14), their host's want tier, their own age category, and an effective certainty equal to the host's — except that a *possible* +1's effective certainty is capped at *uncertain*. HC-04 applies to the +1 through its host (an accepting host makes a *confirmed* +1 certain; a *possible* +1 stays *uncertain*). An opted-out +1 is not counted for that event.
- **HC-06** The system MUST ship with three default presets, editable and deletable like any other:

| Preset | Statuses | Effective certainty |
|---|---|---|
| **Minimum** | planned, invited, accepted | certain |
| **Likely** | planned, invited, accepted | certain, likely |
| **Maximum** | planned, invited, accepted | any |

- **HC-07** Users MAY create any number of additional presets and MAY run an ad hoc (unsaved) filter.
- **HC-08** Wherever a count or a per-person cost is displayed, the preset used MUST be visible.
- **HC-09** A headcount overview MUST show, per event, the counts for every preset side by side.
- **HC-10 Selecting a preset.** Where a view computes a single figure rather than a range (the matrix totals row, CST-53; a formula expansion, CST-34), the preset in use is **per-view and not persisted** — it is neither a per-user setting nor an app-wide one, because two people looking at the same screen must be able to disagree about which case they are discussing without changing what the other sees. It defaults to **Likely**. Views that show a range (BUD-04) do not select at all; they show every default preset.

- **HC-11 The couple.** The two users are not persons on the guest list but they eat, so every headcount MUST include them as **2 adults** for each event whose *couple attends* flag is set (default **on**; an event such as a ceremony that is not catered MAY switch it off). The couple is counted whatever the preset, is part of `adults` and `total` everywhere a per-adult or per-attendee cost or a per-head budget figure uses it, and is shown as its own labelled line in the headcount formula (HC-08, CST-34). For "all events" (HC-03) the couple counts once (2) when at least one event has the flag set.

## Acceptance criteria

- Given 10 persons with Dinner invitations: 4 *accepted* (any certainty), 3 *invited*+*certain*, 2 *invited*+*likely*, 1 *planned*+*uncertain*: Minimum = 7, Likely = 9, Maximum = 10.
- Given one of the 4 accepted persons has a *confirmed* unnamed adult +1 without opt-out, then each preset count increases by 1.
- Given instead that +1 is *possible*, then only Maximum increases by 1.
- Given a person without any invitation to Dinner, then they count in no preset for Dinner, regardless of want tier.
- Given 60 guests counted by Likely for Dinner and Dinner's *couple attends* on, then Likely = 62 (60 + 2 couple), with a separate "Couple — 2 adults" step in its formula; with the flag off, 60. For "all events" the couple adds 2 once, not once per event.
