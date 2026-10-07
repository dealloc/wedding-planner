# Module: Home

## Purpose
A read-only landing page that answers "what should we look at today?" by summarising the other modules and linking into them. It owns no data and no rules: every figure comes from the module that owns it.

## Rules

- **HOME-01** `/home` is the landing page after login. It shows, in this order: a countdown, *Next up* (tasks), *Money*, *Guests*, *Needs attention* and *Recent activity*. Each card links to the screen it summarises. It is phone-first (NFR-31): one column on a phone.
- **HOME-02 Next up.** The next **actionable** (not blocked, TSK-11) tasks, overdue first, then by effective deadline (TSK-13), then those without a deadline; at most 5. Each shows its deadline relative to today in the viewer's zone (NFR-22): *overdue · n days*, *due today*, *due in n days*, a date, or *no deadline*. It also says how many open tasks are blocked.
- **HOME-03 Money.** Paid, still to pay (invoiced, unpaid), the forecast and what is available, as the Minimum–Maximum range over the default presets (BUD-04, BUD-05; one value when they agree), a bar of paid / to pay / rest of forecast / left against the larger of budget and forecast, and an *over budget* notice when the forecast exceeds the overall budget. Below it: unpaid invoices with a due date, overdue first, then the soonest due; at most 4 (BIL-06). Without an overall budget, *available* reads "no overall budget set".
- **HOME-04 Guests.** Per event the Minimum, Likely and Maximum headcount (HC-03, HC-09), the number of invitations per status (planned, invited, accepted, declined) and the number of people and of *possible* +1s. If a default preset is unassigned the headcount part says so instead of showing figures.
- **HOME-05 Needs attention.** Items that are not tasks but need a decision, most urgent first, at most 6 plus "n more": (1) a must-have service missing from a confirmed offer or a planning pick (CST-25), (2) invalid offer lines of those offers (XC-42), (3) a category that has offers but none confirmed or picked. Each links to the offer or category.
- **HOME-06 Countdown.** Days until the nearest event whose date is today or later (EVT-03); nothing is shown as a number when no event has a date.
- **HOME-07 Live.** Every card updates in place when the data it summarises changes, in this session or the other user's (XC-01, XC-02), with no refresh and no change indicator.
