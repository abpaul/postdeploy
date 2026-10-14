import Config

if System.get_env("PHX_SERVER") do
  config :alplus, AlplusWeb.Endpoint, server: true
end

config :alplus, AlplusWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  ingest_db_delay_ms = String.to_integer(System.get_env("INGEST_DB_DELAY_MS", "0"))

  config :alplus, ingest_db_delay_ms: ingest_db_delay_ms

  # A second checkout (a git worktree, a review copy) needs its own database
  # so it can migrate and seed without disturbing the primary dev database.
  if dev_database = System.get_env("DEV_DATABASE") do
    config :alplus, Alplus.Repo, database: dev_database
  end

  config :alplus, AlplusWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        ~r"priv/gettext/.*\.po$"E,
        ~r"lib/alplus_web/router\.ex$"E,
        ~r"lib/alplus_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

founder_emails =
  System.get_env("FOUNDER_EMAILS", "")
  |> String.split(",", trim: true)
  |> Enum.map(&(String.trim(&1) |> String.downcase()))
  |> Enum.reject(&(&1 == ""))
  |> Enum.uniq()

config :alplus, :founder_emails, founder_emails

seo_enabled_org_ids =
  System.get_env("SEO_ENABLED_ORG_IDS", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
  |> Enum.uniq()

config :alplus,
  seo_enabled_org_ids: seo_enabled_org_ids,
  dataforseo_credentials: %{
    login: System.get_env("DATAFORSEO_LOGIN"),
    password: System.get_env("DATAFORSEO_PASSWORD")
  }

if config_env() == :prod do
  # The production AE adapter is installed with the AE Worker configuration.
  # Until then, read failures must surface rather than render zero traffic.
  config :alplus, analytics_engine_adapter: Alplus.Measure.AnalyticsEngine.UnavailableAdapter

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # Encrypt the RDS connection and verify the server certificate. RDS presents
  # a cert that chains to the Amazon RDS root CAs, which are NOT in the OS trust
  # store, so we verify against the bundled AWS RDS global CA bundle (all
  # regions). Override the path with DATABASE_SSL_CA_CERT_PATH if AWS rotates
  # the bundle before this repo does.
  database_ssl_ca_cert =
    System.get_env("DATABASE_SSL_CA_CERT_PATH") ||
      Application.app_dir(:alplus, "priv/certs/aws-rds-global-bundle.pem")

  database_host = URI.parse(database_url).host

  # SSL is on by default and verifies remote database certificates. Set
  # DATABASE_SSL=false only for an isolated same-host Compose PostgreSQL.
  # Remote databases must keep TLS enabled.
  database_ssl =
    if System.get_env("DATABASE_SSL") == "false" do
      false
    else
      [
        verify: :verify_peer,
        cacertfile: database_ssl_ca_cert,
        server_name_indication: to_charlist(database_host),
        depth: 4,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    end

  total_pool_size = String.to_integer(System.get_env("POOL_SIZE") || "10")
  ingest_pool_size = String.to_integer(System.get_env("INGEST_POOL_SIZE") || "4")

  visitor_state_max_entries =
    String.to_integer(System.get_env("VISITOR_STATE_MAX_ENTRIES") || "250000")

  if ingest_pool_size >= total_pool_size do
    raise("INGEST_POOL_SIZE must be smaller than POOL_SIZE")
  end

  if visitor_state_max_entries < 1_000 do
    raise("VISITOR_STATE_MAX_ENTRIES must be at least 1000")
  end

  config :alplus,
    ingest_pool_size: ingest_pool_size,
    visitor_state_max_entries: visitor_state_max_entries

  config :alplus, Alplus.Repo,
    ssl: database_ssl,
    url: database_url,
    pool_size: total_pool_size - ingest_pool_size,
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # The hostname users type. It feeds every emailed link, every canonical URL
  # and the LiveView origin check, so a silent default poisons all three
  # while the marketing pages keep rendering. Raise by name like the others.
  host = System.fetch_env!("PHX_HOST")
  # Origin-less server clients remain valid. Browser MCP requires an explicit
  # production origin and must never inherit the local development policy.
  mcp_allowed_origins =
    "MCP_ALLOWED_ORIGINS"
    |> System.fetch_env!()
    |> String.split(",", trim: true)

  local_mcp_hosts = ["localhost", "127.0.0.1", "::1"]

  unless Enum.any?(mcp_allowed_origins, fn origin ->
           URI.parse(origin).host not in [nil | local_mcp_hosts]
         end) do
    raise "MCP_ALLOWED_ORIGINS must include a non-local browser origin"
  end

  config :alplus, :mcp_allowed_origins, mcp_allowed_origins

  config :alplus, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :alplus, AlplusWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :alplus,
    token_signing_secret:
      System.get_env("TOKEN_SIGNING_SECRET") ||
        raise("Missing environment variable `TOKEN_SIGNING_SECRET`!")

  stripe_environment =
    System.get_env("STRIPE_ENVIRONMENT") ||
      raise("Missing environment variable `STRIPE_ENVIRONMENT`!")

  if stripe_environment not in ~w(local preview staging production) do
    raise("Invalid `STRIPE_ENVIRONMENT`; expected local, preview, staging, or production")
  end

  stripe_secret_key =
    System.get_env("STRIPE_SECRET_KEY") ||
      raise("Missing environment variable `STRIPE_SECRET_KEY`!")

  stripe_webhook_secret =
    System.get_env("STRIPE_WEBHOOK_SECRET") ||
      raise("Missing environment variable `STRIPE_WEBHOOK_SECRET`!")

  # The Stripe price id of the one plan, $29 a month. The founder creates this
  # immutable price with the Stripe CLI; see docs/STRIPE-PRICING-RUNBOOK.md.
  # A value that is not a Stripe price id stops the boot, so the placeholder in
  # config/deploy.yml can never reach Checkout.
  stripe_price_id =
    case System.get_env("STRIPE_PRICE_POSTDEPLOY_MONTHLY") do
      "price_" <> _ = price_id ->
        price_id

      _ ->
        raise(
          "Environment variable `STRIPE_PRICE_POSTDEPLOY_MONTHLY` must be a Stripe price id (price_...)!"
        )
    end

  config :alplus,
    stripe_environment: stripe_environment,
    stripe_webhook_secret: stripe_webhook_secret,
    stripe_price_id: stripe_price_id,
    stripe_reconciliation_adapter: Alplus.Billing.StripeReconciliationAdapter.Stripe

  config :stripity_stripe, api_key: stripe_secret_key

  config :alplus,
    observe_payload_store: Alplus.Observe.PayloadStore.S3,
    observe_payload_bucket:
      System.get_env("OBSERVE_PAYLOADS_S3_BUCKET") ||
        raise("Missing environment variable `OBSERVE_PAYLOADS_S3_BUCKET`!")

  observe_payload_s3_server_side_encryption =
    case System.get_env("S3_SERVER_SIDE_ENCRYPTION", "AES256") do
      "AES256" ->
        "AES256"

      "none" ->
        nil

      value ->
        raise(
          "Invalid `S3_SERVER_SIDE_ENCRYPTION`; expected AES256 or none, got #{inspect(value)}"
        )
    end

  config :alplus,
    observe_payload_s3_server_side_encryption: observe_payload_s3_server_side_encryption

  # S3 uses hackney, which supports environment credentials, instance roles,
  # and local endpoint credentials. The endpoint settings below also support R2.
  config :ex_aws,
    region:
      System.get_env("AWS_REGION") ||
        raise("Missing environment variable `AWS_REGION`!"),
    http_client: ExAws.Request.Hackney,
    http_opts: [recv_timeout: 5_000]

  # Leave the endpoint unset for regional S3. Set all three endpoint variables
  # for R2, MinIO, or another S3-compatible service.
  case {System.get_env("S3_SCHEME"), System.get_env("S3_HOST"), System.get_env("S3_PORT")} do
    {nil, nil, nil} ->
      :ok

    {scheme, host, port} when is_binary(scheme) and is_binary(host) and is_binary(port) ->
      config :ex_aws, :s3,
        scheme: scheme,
        host: host,
        port: String.to_integer(port)

    _ ->
      raise("Set S3_SCHEME, S3_HOST, and S3_PORT together, or leave all three unset")
  end

  notifications_vault_key =
    System.get_env("NOTIFICATIONS_VAULT_KEY") ||
      raise("Missing environment variable `NOTIFICATIONS_VAULT_KEY`!")

  config :alplus, Alplus.NotificationsVault,
    ciphers: [
      default: {
        Cloak.Ciphers.AES.GCM,
        tag: "AES.GCM.V1", key: Base.decode64!(notifications_vault_key)
      }
    ]

  # Signup gate (ARCHITECTURE.md §10). Defaults to enabled so an unset
  # var doesn't accidentally lock out registration; flip it explicitly
  # to close signups.
  config :alplus,
    signups_enabled?: System.get_env("SIGNUPS_ENABLED", "true") in ~w(true 1)

  # Cloudflare Turnstile (ARCHITECTURE.md §10, §14). Both are required —
  # fail fast rather than silently accepting unverified sign-ups.
  #
  # A testing key is worse than a missing one: `1x...AA` renders a widget
  # stamped "For testing only" and its secret validates every token, so the
  # form works, looks fine, and protects nothing. Production ran that way until
  # 2026-08-20. Refuse to boot on one.
  turnstile_site_key =
    System.get_env("TURNSTILE_SITE_KEY") ||
      raise("Missing environment variable `TURNSTILE_SITE_KEY`!")

  turnstile_secret =
    System.get_env("TURNSTILE_SECRET_KEY") ||
      raise("Missing environment variable `TURNSTILE_SECRET_KEY`!")

  for {name, key} <- [
        {"TURNSTILE_SITE_KEY", turnstile_site_key},
        {"TURNSTILE_SECRET_KEY", turnstile_secret}
      ],
      Alplus.Turnstile.dummy_key?(key) do
    raise """
    #{name} is one of Cloudflare's testing keys.

    Those accept every challenge response, so sign-up would have no bot
    protection at all. Create a real Turnstile widget for this hostname and
    set both keys from it.
    """
  end

  config :alplus,
    turnstile_site_key: turnstile_site_key,
    turnstile_secret: turnstile_secret

  # Search Console / Bing Webmaster Tools verification (optional). Prefer
  # DNS TXT verification, which Cloudflare already manages and which covers
  # the whole domain; these exist for the meta-tag method when a DNS record
  # is not practical. Unset means no tag is rendered, which is correct: an
  # empty verification tag is worse than none.
  config :alplus,
    google_site_verification: System.get_env("GOOGLE_SITE_VERIFICATION"),
    bing_site_verification: System.get_env("BING_SITE_VERIFICATION")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :alplus, AlplusWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :alplus, AlplusWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # Outbound email routes through Cloudflare Email Service over SMTP
  # (ARCHITECTURE.md §10a). Implicit TLS on port 465; the username is the
  # literal "api_token" and the password is the Cloudflare API token. Verify
  # the server certificate against the OS trust store (Cloudflare's SMTP cert
  # chains to a public CA). Fail fast if the token or From address is missing —
  # otherwise verification, reset, invite, and billing email silently never
  # send.
  cloudflare_smtp_host = "smtp.mx.cloudflare.net"

  # Implicit TLS on port 465. gen_smtp passes `sockopts` (NOT `tls_options`)
  # to `:ssl.connect/4` for the initial socket; `tls_options` only applies to
  # a STARTTLS upgrade, which never happens on 465. Since OTP 26 `:ssl.connect`
  # defaults to `verify: :verify_peer`, which needs a CA store, so the
  # verification options must live in `sockopts` or the handshake fails with
  # `{options, incompatible, [verify: verify_peer, cacerts: undefined]}` and
  # every confirmation, reset, invite, and billing email crashes the action.
  # Keep the same options in `tls_options` for defence in depth.
  smtp_tls_options = [
    verify: :verify_peer,
    cacerts: :public_key.cacerts_get(),
    server_name_indication: to_charlist(cloudflare_smtp_host),
    depth: 4,
    customize_hostname_check: [
      match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
    ]
  ]

  config :alplus, Alplus.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: cloudflare_smtp_host,
    port: 465,
    ssl: true,
    auth: :always,
    username: "api_token",
    password:
      System.get_env("CLOUDFLARE_EMAIL_API_TOKEN") ||
        raise("Missing environment variable `CLOUDFLARE_EMAIL_API_TOKEN`!"),
    retries: 1,
    sockopts: smtp_tls_options,
    tls_options: smtp_tls_options

  config :alplus,
    mail_from:
      System.get_env("MAIL_FROM") ||
        raise("Missing environment variable `MAIL_FROM`!")

  # Self-observability (dogfooding). Optional on purpose: with no ALPLUS_KEY
  # the Sentry SDK has no DSN and sends nothing, so a missing key degrades
  # reporting rather than refusing to boot the product.
  #
  # The DSN host is the public ingest host, so this app takes the exact path
  # a customer install takes. ALPLUS_ENDPOINT overrides it for a staging host.
  # The Observe key selects the Source; the server does not read the project
  # number, but the SDK requires one.
  #
  # KAMAL_VERSION is the deployed git sha, which is what Observe attributes an
  # issue's first-seen release to.
  if observe_key = System.get_env("ALPLUS_KEY") do
    ingest = URI.parse(System.get_env("ALPLUS_ENDPOINT") || "https://ingest.postdeploy.dev")

    config :sentry,
      dsn: URI.to_string(%URI{ingest | userinfo: observe_key, path: "/1"}),
      environment_name: System.get_env("ALPLUS_ENVIRONMENT") || "production",
      release: System.get_env("KAMAL_VERSION"),
      before_send: {Alplus.Observe.SelfObservability, :before_send}
  end

  # Dogfooding Measure on our own marketing pages. The token is public by
  # design (ADR 0001 decision 8: it ships inside a served browser snippet), so
  # it lives in `env.clear` rather than Secrets Manager. Unset means the snippet
  # is not rendered at all.
  config :alplus, measure_self_token: System.get_env("MEASURE_SELF_TOKEN")
end
