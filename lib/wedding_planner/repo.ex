defmodule WeddingPlanner.Repo do
  use Ecto.Repo,
    otp_app: :wedding_planner,
    adapter: Ecto.Adapters.SQLite3
end
