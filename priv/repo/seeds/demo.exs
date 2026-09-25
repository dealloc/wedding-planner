for block_file <- ~w(events people invitations categories offers invoices confirmations
                    budget tasks task_links presets what_if) do
  Code.require_file("#{block_file}.exs", __DIR__)
end

defmodule WeddingPlanner.Seeds.Demo do
  @moduledoc """
  Orchestrates the dev demo data (`DR-79`, `DR-26` Q4) — called by `priv/repo/seeds.exs`
  (so by `mix ecto.setup`) and, in dev, right after the first passkey is registered on
  `/setup` (`WeddingPlanner.Seeds.DemoLoader`).

  Every block is recorded by its stable name in `demo_seed_runs`
  (`WeddingPlanner.DemoSeedRun`) once it has run. `run/0` first sorts the database into
  one of three kinds:

    * **demo** — `demo_seed_runs` has rows: runs every block not yet recorded, in order,
      and records it. This is how a later wave's new block reaches an existing demo
      database: append it to `blocks/0` with a new name.
    * **fresh** — no `demo_seed_runs` rows and the domain tables (events, people,
      categories, offers, invoices, tasks) all empty: runs and records every block,
      which makes it a demo database.
    * **in use** — no `demo_seed_runs` rows but some domain data: seeds nothing. The
      blocks depend on each other's rows, and mixing demo rows into a database someone
      uses for real would be worse than seeding nothing.

  `DR-22`/`AUTH-03`: this never creates a user. It acts as the first user with a
  registered passkey; with none yet, it prints a message and returns `:no_user`.
  """

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.Users
  alias WeddingPlanner.DemoSeedRun
  alias WeddingPlanner.Repo
  alias WeddingPlanner.Seeds

  # The domain tables whose rows make a database without `demo_seed_runs` rows "in use".
  @domain_tables [
    {"events", WeddingPlanner.Events.Event},
    {"people", WeddingPlanner.Guests.Person},
    {"categories", WeddingPlanner.Categories.Category},
    {"offers", WeddingPlanner.Offers.Offer},
    {"invoices", WeddingPlanner.Invoices.Invoice},
    {"tasks", WeddingPlanner.Tasks.Task}
  ]

  @spec run() :: :ok | :no_user | :in_use
  def run do
    case Users.list_assignable() do
      [] ->
        IO.puts(
          "No user yet — start the app (`mix phx.server`) and register at /setup; the demo data loads as soon as the first passkey is saved"
        )

        :no_user

      [actor | rest] ->
        seed(Scope.for_user(actor), List.first(rest))
    end
  end

  # Ordered: each block may rely on the rows of the blocks before it. A new wave's
  # block goes at the end with a new, never-reused name.
  defp blocks do
    [
      {"events", fn scope, _second_user -> Seeds.Events.run(scope) end},
      {"people", fn scope, _second_user -> Seeds.People.run(scope) end},
      {"invitations", fn scope, _second_user -> Seeds.Invitations.run(scope) end},
      {"categories", fn scope, _second_user -> Seeds.Categories.run(scope) end},
      {"offers", fn scope, _second_user -> Seeds.Offers.run(scope) end},
      {"invoices", fn scope, _second_user -> Seeds.Invoices.run(scope) end},
      {"confirmations", fn scope, _second_user -> Seeds.Confirmations.run(scope) end},
      {"budget", fn scope, _second_user -> Seeds.Budget.run(scope) end},
      {"tasks", &Seeds.Tasks.run/2},
      {"task_links", fn scope, _second_user -> Seeds.TaskLinks.run(scope) end},
      {"presets", fn scope, _second_user -> Seeds.Presets.run(scope) end},
      {"what_if", fn scope, _second_user -> Seeds.WhatIf.run(scope) end}
    ]
  end

  defp seed(scope, second_user) do
    applied = Repo.all(DemoSeedRun) |> MapSet.new(& &1.name)

    cond do
      MapSet.size(applied) > 0 ->
        pending = Enum.reject(blocks(), fn {name, _} -> MapSet.member?(applied, name) end)

        case pending do
          [] ->
            IO.puts("demo data: up to date")

          _ ->
            apply_blocks(pending, scope, second_user)
            IO.puts("demo data: applied " <> Enum.map_join(pending, ", ", &elem(&1, 0)))
        end

        :ok

      (in_use = tables_with_data()) != [] ->
        IO.puts(
          "skipping demo seeds — the database already has " <>
            Enum.join(in_use, ", ") <>
            " (demo data is only added to an empty database; `mix ecto.reset` starts over)"
        )

        :in_use

      true ->
        apply_blocks(blocks(), scope, second_user)
        IO.puts("demo data: applied " <> Enum.map_join(blocks(), ", ", &elem(&1, 0)))
        :ok
    end
  end

  defp tables_with_data do
    for {label, schema} <- @domain_tables, Repo.exists?(schema), do: label
  end

  # Each block is recorded right after it runs — whether it created rows or printed its
  # own "skipping … already has data" line — so it never runs against this database again.
  defp apply_blocks(blocks, scope, second_user) do
    Enum.each(blocks, fn {name, block} ->
      block.(scope, second_user)

      Repo.insert!(%DemoSeedRun{name: name}, on_conflict: :nothing, conflict_target: :name)
    end)
  end
end
