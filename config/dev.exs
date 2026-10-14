import Config
config :ash, policies: [show_policy_breakdowns?: true]

# Cloudflare Turnstile "always passes" test keys — see
# https://developers.cloudflare.com/turnstile/troubleshooting/testing/
# Production reads real keys from env in config/runtime.exs.
config :alplus,
  turnstile_site_key: "1x00000000000000000000AA",
  turnstile_secret: "1x0000000000000000000000000000000AA"

# Local billing runs against the Stripe mirror only. `:stripe_environment`
# must be set (BillingLive.mount reads it via StripeConfig.environment to
# scope invoices); without it the Billing page crashed with a MatchError in
# dev. The Fake adapter keeps checkout and portal off real Stripe.
config :alplus,
  stripe_environment: "local",
  stripe_webhook_secret: "whsec_alplus_dev_webhook_secret",
  # The sandbox $29 monthly price (docs/STRIPE-PRICING-RUNBOOK.md). The Fake
  # adapter below never sends it; it is real if a developer swaps the adapter.
  stripe_price_id: "price_1UGFIV2O1ekbxUaRLtGV0uvd",
  stripe_adapter: Alplus.Billing.StripeAdapter.Fake

config :alplus, Alplus.Repo,
  username: "alplus_local",
  password: "alplus_local_only_disposable",
  hostname: "127.0.0.1",
  port: 54_329,
  # A second checkout sets DEV_DATABASE so its migrations cannot change the
  # schema another checkout's server is using.
  database: System.get_env("DEV_DATABASE", "alplus_dev"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  # Tunable via POOL_SIZE for local load experiments (mix alplus.loadtest);
  # defaults to 10, matching the standard dev pool.
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

config :alplus, AlplusWeb.Endpoint,
  url: [
    host: "localhost",
    port: String.to_integer(System.get_env("PORT", "4000")),
    scheme: "http"
  ],
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "Cq3ZBDgFmD963KQsJbizOLgWkyq6JyUM72IbistxrL9dPaFxGtGKzGZYtgR+xNku",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:alplus, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:alplus, ~w(--watch)]}
  ]

config :alplus,
  dev_routes: true,
  token_signing_secret: "Jl9EhfQRVQ3xHxe+zxtMJs71ifS+89RW",
  analytics_engine_adapter: Alplus.Measure.AnalyticsEngine.DevAdapter,
  homepage_preview_when_unconfigured: true

# Development-only key. Production reads a separate base64 key at runtime.
config :alplus, Alplus.NotificationsVault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: :crypto.hash(:sha256, "alplus-dev-notifications-vault")}
  ]

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true

config :swoosh, :api_client, false

# Dev-only file-backed Observe payload store (tmp/observe_payload_store),
# so release-artifact upload and oversized-event overflow work without S3.
config :alplus, observe_payload_store: Alplus.Observe.PayloadStore.Local
