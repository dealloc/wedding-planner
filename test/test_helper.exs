# Test modules run one at a time. SQLite allows a single writer, and each sandboxed
# test holds a transaction for its whole duration; with ExUnit's default of 2x cores
# concurrent modules this produced intermittent "Database busy" failures (~1 run in 3).
# The whole suite runs in well under a second, so concurrency buys nothing.
# The real-connection race tests (`@moduletag :real_connection_race`) flip the sandbox to
# :auto and race independent connections through `BEGIN IMMEDIATE`. Inside the full suite,
# under machine load, SQLite occasionally exceeds `busy_timeout` there and exqlite raises
# (measured ~1 run in 6 with parallel workers). Alone they pass reliably, so they're excluded
# here and run as a separate step of `mix precommit` (`mix test --only real_connection_race`).
ExUnit.start(max_cases: 1, exclude: [:real_connection_race])
Ecto.Adapters.SQL.Sandbox.mode(WeddingPlanner.Repo, :manual)
