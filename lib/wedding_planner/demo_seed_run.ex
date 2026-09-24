defmodule WeddingPlanner.DemoSeedRun do
  @moduledoc """
  One demo-data block applied to this database (`DR-79`).

  Bookkeeping for the dev demo seeds (`priv/repo/seeds/demo.exs`), not domain data: it is
  never shown in the UI, never valued and never written to the activity log. Any row
  marks the database as a demo database; see `WeddingPlanner.Seeds.Demo` for how
  `mix ecto.setup` uses that.
  """
  use Ecto.Schema

  schema "demo_seed_runs" do
    field :name, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
