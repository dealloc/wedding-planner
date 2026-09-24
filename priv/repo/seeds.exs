# Populates a development database with realistic demo data at the scale the locked
# UI designs were judged at (`DR-26` Q4, `.claude/plans/w6-plan.md` Q4) and keeps it
# current wave after wave (`DR-79`):
#
#     mix run priv/repo/seeds.exs
#
# `mix ecto.setup` (and so `mix ecto.reset`) run this automatically. Dev-only — guarded
# below by `Mix.env()`, so it never runs against a release and `mix test`'s alias never
# calls it. The work is done by `WeddingPlanner.Seeds.Demo.run/0` (`seeds/demo.exs`),
# which records every demo block it applies, by name, in the `demo_seed_runs` table and
# first sorts the database into one of three kinds:
#
#   * **fresh** — no `demo_seed_runs` rows and events, persons, categories, offers,
#     invoices and tasks all empty: every block runs (and is recorded), which makes it a
#     demo database.
#   * **demo** — `demo_seed_runs` has rows: only the blocks not yet recorded run, in
#     order. Running this again on an up-to-date demo database creates nothing.
#   * **in use** — no `demo_seed_runs` rows but some domain data: nothing is seeded. The
#     blocks depend on each other's rows (the offers need the demo events, the invoices
#     the demo offers …), and mixing demo rows into a database someone has started using
#     for real would be worse than seeding nothing.
#
# **Adding a wave's demo data:** write the new block file under `seeds/` and append it to
# the ordered block list in `seeds/demo.exs` under a new name. That is how `mix
# ecto.setup` picks it up on an existing demo database — the older blocks are recorded
# and skipped, the new one runs once. Never rename or reuse a block's name.
#
# Every block goes through its domain context (`WeddingPlanner.Events`,
# `WeddingPlanner.Guests`, `WeddingPlanner.Categories`, `WeddingPlanner.Tasks` …), never
# `Repo.insert!` directly, so every row gets real activity-log entries (`XC-10`) and
# real validation, exactly as if a user had typed it. (Each block also keeps its own
# "table is empty" check.)
#
# `DR-22`/`AUTH-03`: this seed never creates a user — the setup flow is reachable only
# while none exists, and creating one here would lock a real first-time setup. It acts
# as the first user with a registered passkey (`WeddingPlanner.Accounts.Users.list_assignable/0`)
# instead; with none yet, it prints a message and exits successfully so
# `mix ecto.setup` still succeeds on a brand-new database. In dev, registering the first
# passkey on `/setup` then runs the same `Demo.run/0` (`:demo_seed_after_setup` in
# `config/dev.exs`), so `mix ecto.setup` + sign-up is all a demo needs.

if Mix.env() == :dev do
  Code.require_file("seeds/demo.exs", __DIR__)
  WeddingPlanner.Seeds.Demo.run()
else
  IO.puts("Demo seeds only run in :dev (Mix.env()=#{Mix.env()}) — skipping.")
end
