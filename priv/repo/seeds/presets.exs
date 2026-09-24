defmodule WeddingPlanner.Seeds.Presets do
  @moduledoc """
  One demo custom headcount preset ("Family & friends", `HC-07`, `DR-53`) over
  `priv/repo/seeds/people.exs`'s seeded groups — task 62's optional seed, so
  `/headcount`'s preset management section has at least one preset showing a non-empty
  group criterion (and something to rename/edit/delete) without the couple having to
  build one by hand first. Idempotent: runs only while no preset named "Family &
  friends" exists — see `priv/repo/seeds.exs`. The three `HC-06` defaults are seeded by
  the `headcount_presets` migration itself, not here, and are locked (`DR-54` revised)
  — this seed only ever creates a custom preset, never touches them.
  """

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Guests
  alias WeddingPlanner.Presets

  @name "Family & friends"
  @group_names ["Family Peeters", "Family Van Damme", "University friends"]

  @spec run(Scope.t()) :: :ok
  def run(%Scope{} = scope) do
    if Enum.any?(Presets.list_presets(), &(&1.name == @name)) do
      IO.puts("skipping presets — already has data")
    else
      group_ids =
        Guests.list_groups()
        |> Enum.filter(&(&1.name in @group_names))
        |> Enum.map(& &1.id)

      case group_ids do
        [] ->
          IO.puts("skipping presets — no seeded groups to build '#{@name}' from yet")

        ids ->
          {:ok, _preset} =
            Presets.create_preset(scope, %{
              "name" => @name,
              "invitation_statuses" => ["planned", "invited", "accepted"],
              "group_ids" => ids
            })

          IO.puts("presets: created '#{@name}' over #{length(ids)} seeded group(s)")
      end
    end

    :ok
  end
end
