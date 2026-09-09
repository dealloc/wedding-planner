import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :wedding_planner, WeddingPlanner.Repo,
  database: Path.expand("../wedding_planner_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox,
  # SQLite allows exactly one writer at a time. The adapter's default busy_timeout of
  # 2000ms is what turns brief contention into "database is locked"; waiting longer costs
  # nothing when there is no contention.
  busy_timeout: 5_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :wedding_planner, WeddingPlannerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "YWT7xzpzKMKPi8momMEcHOlI4p8aghWKJqW40BlmJuMziCwbM+BsHqqFr05wdBVA",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
