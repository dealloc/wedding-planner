defmodule WeddingPlanner.Seeds.DemoLoader do
  @moduledoc """
  Loads and runs the dev demo seeds from inside the running app (`DR-79`).

  `WeddingPlanner.Seeds.Demo` lives in `priv/repo/seeds/demo.exs`, a script that is not
  compiled with the app, so this requires it from the app's `priv` directory before
  calling it. Used only by `/setup` when `:demo_seed_after_setup` is set (dev only); the
  module to call is `config :wedding_planner, :demo_seeder`, so tests can substitute a
  stub and never run the real seeds.
  """

  @compile {:no_warn_undefined, WeddingPlanner.Seeds.Demo}

  @spec run() :: :ok | :no_user | :in_use
  def run do
    Code.require_file(Application.app_dir(:wedding_planner, "priv/repo/seeds/demo.exs"))
    WeddingPlanner.Seeds.Demo.run()
  end
end
