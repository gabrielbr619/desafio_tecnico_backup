import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :pbkdf2_elixir, :rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :w_core, WCore.Repo,
  database: Path.expand("../priv/repo/w_core_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox,
  journal_mode: :wal

config :w_core, WCore.Mailer, adapter: Swoosh.Adapters.Test

# WriteBehind reduced intervals for deterministic tests
config :w_core, :write_behind_interval_ms, 1_000
config :w_core, :write_behind_dirty_threshold, 50

config :w_core, :api_key, "test_api_key"

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :w_core, WCoreWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "YbJL0CiUYU62GnMYjvgo9wGZZVyy2HH9arUS6Kg7t1AaLz3kFqQGHV7CTzMglyLa",
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
