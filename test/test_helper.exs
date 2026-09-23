# Test modules run one at a time. SQLite allows a single writer, and each sandboxed
# test holds a transaction for its whole duration; with ExUnit's default of 2x cores
# concurrent modules this produced intermittent "Database busy" failures (~1 run in 3).
# The whole suite runs in well under a second, so concurrency buys nothing.
ExUnit.start(max_cases: 1)
Ecto.Adapters.SQL.Sandbox.mode(WeddingPlanner.Repo, :manual)
