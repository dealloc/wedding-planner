# Populates a development database with realistic demo data at the scale the locked
# UI designs were judged at (`DR-26` Q4, `.claude/plans/w6-plan.md` Q4):
#
#     mix run priv/repo/seeds.exs
#
# `mix ecto.setup` (and so `mix ecto.reset`) run this automatically. Dev-only — guarded
# below by `Mix.env()`, so it never runs against a release and `mix test`'s alias never
# calls it. Idempotent per block (events / people / categories / tasks): each block
# below runs only while its own table is empty, so running this twice creates nothing
# the second time.
#
# Every block goes through its domain context (`WeddingPlanner.Events`,
# `WeddingPlanner.Guests`, `WeddingPlanner.Categories`, `WeddingPlanner.Tasks`), never
# `Repo.insert!` directly, so every row gets real activity-log entries (`XC-10`) and
# real validation, exactly as if a user had typed it.
#
# `DR-22`/`AUTH-03`: this seed never creates a user — the setup flow is reachable only
# while none exists, and creating one here would lock a real first-time setup. It acts
# as the first user with a registered passkey (`WeddingPlanner.Accounts.Users.list_assignable/0`)
# instead; with none yet, it prints a message and exits successfully so
# `mix ecto.setup` still succeeds on a brand-new database.

alias WeddingPlanner.Accounts.Scope
alias WeddingPlanner.Accounts.Users

if Mix.env() == :dev do
  Code.require_file("seeds/events.exs", __DIR__)
  Code.require_file("seeds/people.exs", __DIR__)
  Code.require_file("seeds/categories.exs", __DIR__)
  Code.require_file("seeds/tasks.exs", __DIR__)

  case Users.list_assignable() do
    [] ->
      IO.puts("No user yet — sign up at /setup first, then run `mix run priv/repo/seeds.exs`")

    [actor | rest] ->
      scope = Scope.for_user(actor)
      second_user = List.first(rest)

      WeddingPlanner.Seeds.Events.run(scope)
      WeddingPlanner.Seeds.People.run(scope)
      WeddingPlanner.Seeds.Categories.run(scope)
      WeddingPlanner.Seeds.Tasks.run(scope, second_user)
  end
else
  IO.puts("Demo seeds only run in :dev (Mix.env()=#{Mix.env()}) — skipping.")
end
