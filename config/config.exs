import Config

config :ash_oban, pro?: false

config :alplus, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  queues: [default: 10, notify: 10, telemetry: 5, billing: 5, mailer: 10],
  repo: Alplus.Repo,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", Alplus.Monitoring.MaintenanceWorker},
       {"10 0 * * *", Alplus.Monitoring.ExpiryScanWorker},
       {"15 0 * * *", Alplus.Monitoring.MaintenanceWorker, args: %{"mode" => "daily"}},
       {"* * * * *", Alplus.Status.MaintenanceWorker},
       {"*/5 * * * *", Alplus.Status.RecoveryWorker},
       {"1 0 * * *", Alplus.Billing.UsageRolloverWorker},
       {"10 0 * * *", Alplus.Measure.MaintenanceWorker},
       {"25 0 * * *", Alplus.Analytics.MaintenanceWorker},
       {"30 0 * * *", Alplus.Seo.MaintenanceWorker},
       {"20 0 * * *", Alplus.Observe.MaintenanceWorker},
       {"10 0 * * *", Alplus.Billing.ReconciliationWorker},
       {"45 0 * * *", Alplus.Growth.RetentionWorker},
       {"40 0 * * *", Alplus.Billing.DataPurgeWorker}
     ]},
    # Ten webhook attempts exhaust their retry schedule within this window.
    # Keep terminal rows for seven days so operators can inspect recent jobs.
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}
  ]

# These enable behaviors that will become the default in the next major
# version of Ash. Setting them now opts your application into the new
# behavior and ensures a seamless upgrade. See the backwards compatibility
# guide for an explanation of each setting:
# https://hexdocs.pm/ash/backwards-compatibility-config.html
config :ash,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  many_to_many_destroy_destination_on_match?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :authentication,
        :token,
        :user_identity,
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [section_order: [:resources, :policies, :authorization, :domain, :execution]]
  ]

config :alplus,
  ecto_repos: [Alplus.Repo],
  ingest_repo: Alplus.IngestRepo,
  ingest_pool_size: 4,
  visitor_state_max_entries: 250_000,
  observe_payload_store: Alplus.Observe.PayloadStore.Unconfigured,
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [
    Alplus.Accounts,
    Alplus.Orgs,
    Alplus.Projects,
    Alplus.Sources,
    Alplus.Content,
    Alplus.Audit,
    Alplus.Measure,
    Alplus.Analytics,
    Alplus.Seo,
    Alplus.Observe,
    Alplus.Changelog,
    Alplus.Mcp,
    Alplus.Monitoring,
    Alplus.Notifications,
    Alplus.Status,
    Alplus.Billing,
    Alplus.Growth,
    Alplus.PublicPages
  ]

# Security gates around AshAuthentication (ARCHITECTURE.md §10).
# Production values are read from env vars in config/runtime.exs.
config :alplus,
  signups_enabled?: true,
  hibp_timeout_ms: 3_000,
  # Fail closed: reject the password if HIBP can't be reached, rather
  # than silently accepting an unchecked password.
  hibp_fail_closed?: true,
  turnstile_timeout_ms: 3_000

config :alplus, :mcp_adapters, [
  Alplus.Analytics.McpAdapter,
  Alplus.Changelog.McpAdapter,
  Alplus.Measure.McpAdapter,
  Alplus.Seo.McpAdapter,
  Alplus.Monitoring.McpAdapter,
  Alplus.Observe.McpAdapter,
  Alplus.Projects.McpAdapter,
  Alplus.PublicPages.McpAdapter,
  Alplus.Status.McpAdapter
]

# Configure the endpoint
config :alplus, AlplusWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  http: [
    thousand_island_options: [
      num_acceptors: 16,
      num_connections: 64,
      max_connections_retry_count: 0,
      read_timeout: 10_000
    ],
    http_1_options: [max_requests: 100],
    http_2_options: [max_requests: 1_000]
  ],
  render_errors: [
    formats: [html: AlplusWeb.ErrorHTML, json: AlplusWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Alplus.PubSub,
  live_view: [signing_salt: "++tbVw/8"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :alplus, Alplus.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  alplus: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  alplus: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :remote_ip, :user_id, :org_id, :project_id, :job_id, :signal, :reason]

# Use Jason for JSON parsing in Phoenix
config :phoenix,
  json_library: Jason,
  filter_parameters: [
    "password",
    "password_confirmation",
    "token",
    "turnstile_token",
    "session_token",
    "reset_token",
    "confirmation_token",
    "secret",
    "key",
    "api_key",
    "authorization",
    "csrf",
    "turnstile",
    "session",
    "code",
    "code_verifier",
    "target_url",
    "keyword"
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# Compile-time Sentry SDK settings (self-observability). The Dockerfile runs
# `mix sentry.package_source_code`, which reads the source paths from here.
config :sentry,
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()],
  in_app_otp_apps: [:alplus],
  integrations: [oban: [capture_errors: true]]

import_config "#{config_env()}.exs"
