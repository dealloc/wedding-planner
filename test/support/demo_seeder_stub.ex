defmodule WeddingPlanner.DemoSeederStub do
  @moduledoc """
  Stands in for `WeddingPlanner.Seeds.DemoLoader` in tests (`DR-79`), via
  `config :wedding_planner, :demo_seeder`, so the real dev seeds never run in the suite.

  Behaviour comes from `Application.get_env(:wedding_planner, :demo_seeder_stub)`:
  `{:ok, pid}` sends `{:demo_seeder_called, self()}` to `pid` and returns `:ok`;
  `{:raise, pid}` sends the same message, then raises.
  """

  def run do
    {mode, pid} = Application.fetch_env!(:wedding_planner, :demo_seeder_stub)
    send(pid, {:demo_seeder_called, self()})

    case mode do
      :ok -> :ok
      :raise -> raise "demo seeding blew up"
    end
  end
end
