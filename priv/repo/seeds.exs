# Populates a development database with realistic demo data at the scale the locked
# UI designs were judged at (`DR-26` Q4, `.claude/plans/w6-plan.md` Q4):
#
#     mix run priv/repo/seeds.exs
#
# `mix ecto.setup` (and so `mix ecto.reset`) run this automatically. Dev-only — guarded
# below by `Mix.env()`, so it never runs against a release and `mix test`'s alias never
# calls it. **All or nothing:** the demo set runs only against a database whose seeded
# tables (events, persons, categories, offers, invoices, tasks) are all empty. If any of
# them has rows, nothing is seeded — the demo blocks depend on each other's rows (the
# offers need the demo events, the invoices the demo offers …), and mixing demo rows into
# a database someone has started using for real would be worse than seeding nothing.
# Running this twice therefore creates nothing the second time. (Each block also keeps
# its own "table is empty" check.)
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
  Code.require_file("seeds/invitations.exs", __DIR__)
  Code.require_file("seeds/categories.exs", __DIR__)
  Code.require_file("seeds/offers.exs", __DIR__)
  Code.require_file("seeds/invoices.exs", __DIR__)
  Code.require_file("seeds/confirmations.exs", __DIR__)
  Code.require_file("seeds/tasks.exs", __DIR__)
  Code.require_file("seeds/task_links.exs", __DIR__)
  Code.require_file("seeds/presets.exs", __DIR__)

  seed_demo = fn scope, second_user ->
    WeddingPlanner.Seeds.Events.run(scope)
    WeddingPlanner.Seeds.People.run(scope)
    WeddingPlanner.Seeds.Invitations.run(scope)
    WeddingPlanner.Seeds.Categories.run(scope)
    WeddingPlanner.Seeds.Offers.run(scope)
    WeddingPlanner.Seeds.Invoices.run(scope)
    WeddingPlanner.Seeds.Confirmations.run(scope)
    WeddingPlanner.Seeds.Tasks.run(scope, second_user)
    WeddingPlanner.Seeds.TaskLinks.run(scope)
    WeddingPlanner.Seeds.Presets.run(scope)
  end

  case Users.list_assignable() do
    [] ->
      IO.puts("No user yet — sign up at /setup first, then run `mix run priv/repo/seeds.exs`")

    [actor | rest] ->
      # All or nothing (see the header): never mix demo rows into a database in use.
      in_use =
        for {label, schema} <- [
              {"events", WeddingPlanner.Events.Event},
              {"people", WeddingPlanner.Guests.Person},
              {"categories", WeddingPlanner.Categories.Category},
              {"offers", WeddingPlanner.Offers.Offer},
              {"invoices", WeddingPlanner.Invoices.Invoice},
              {"tasks", WeddingPlanner.Tasks.Task}
            ],
            WeddingPlanner.Repo.exists?(schema),
            do: label

      if in_use != [] do
        IO.puts(
          "skipping demo seeds — the database already has " <>
            Enum.join(in_use, ", ") <>
            " (demo data is only added to an empty database; `mix ecto.reset` starts over)"
        )
      else
        seed_demo.(Scope.for_user(actor), List.first(rest))
      end
  end
else
  IO.puts("Demo seeds only run in :dev (Mix.env()=#{Mix.env()}) — skipping.")
end
