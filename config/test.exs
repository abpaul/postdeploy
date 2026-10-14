import Config
config :alplus, Oban, testing: :manual
config :alplus, ingest_repo: Alplus.Repo
config :alplus, monitor_scheduler_enabled?: false

# No background reconcile tick in tests: it would query outside the checked-out
# sandbox connection. `scheduler_lifecycle_test.exs` sends `:reconcile_all`
# itself, which is the same code path without the timer.
config :alplus, monitor_reconcile_interval_ms: 0
config :alplus, incident_draft_reconcile_interval_ms: 0
config :alplus, observe_payload_store: Alplus.Observe.PayloadStore.Fake

config :alplus,
  token_signing_secret: "4tyjUqXYBXg9diz4e88JrwVsQ+Nqtg37",
  stripe_environment: "local",
  stripe_webhook_secret: "whsec_alplus_test_webhook_secret",
  stripe_price_id: "price_test_postdeploy_monthly",
  stripe_adapter: Alplus.Billing.StripeAdapter.Fake,
  analytics_engine_adapter: Alplus.Measure.AnalyticsEngine.DevAdapter

config :stripity_stripe, api_key: "sk_test_alplus_test_secret_key"

config :bcrypt_elixir, log_rounds: 1

config :alplus, Alplus.NotificationsVault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: :crypto.hash(:sha256, "alplus-test-notifications-vault")}
  ]

config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Cloudflare Turnstile "always passes" test keys — see
# https://developers.cloudflare.com/turnstile/troubleshooting/testing/
config :alplus,
  turnstile_site_key: "1x00000000000000000000AA",
  turnstile_secret: "1x0000000000000000000000000000000AA"

# Route the HIBP and Turnstile HTTP clients through Req.Test instead of
# the real network. test/test_helper.exs installs a default global stub;
# individual tests override it with Req.Test.stub/2 to exercise the
# breached/failure paths.
config :alplus,
  hibp_req_plug: {Req.Test, Alplus.Accounts.Hibp.Client},
  turnstile_req_plug: {Req.Test, Alplus.Turnstile.Client},
  dataforseo_req_plug: {Req.Test, Alplus.Seo.DataForSeo},
  dataforseo_credentials: %{login: "test-login", password: "test-password"}

config :alplus, Alplus.Monitoring.AnonymousProbe.RateLimiter,
  ip_limit: 1_000,
  global_limit: 10_000

config :alplus, Alplus.Monitoring.AnonymousProbe.Gate, max_concurrency: 32

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :alplus, Alplus.Repo,
  username: "alplus_local",
  password: "alplus_local_only_disposable",
  hostname: "127.0.0.1",
  port: 54_329,
  database: "alplus_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :alplus, AlplusWeb.Endpoint,
  url: [
    host: "localhost",
    port: String.to_integer(System.get_env("MCP_TEST_PORT") || "4002"),
    scheme: "http"
  ],
  http: [
    ip: {127, 0, 0, 1},
    port: String.to_integer(System.get_env("MCP_TEST_PORT") || "4002")
  ],
  secret_key_base: "dXemSFvd4rU+0Yb5uv1N7sis4SVBf7RXBcEQLsqzf8b+37ZnXCkASfIlQeMgV2QU",
  server: false

# In test we don't send emails
config :alplus, Alplus.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

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
