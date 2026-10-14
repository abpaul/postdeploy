defmodule AlplusWeb.Router do
  use AlplusWeb, :router

  use AshAuthentication.Phoenix.Router

  import Phoenix.LiveDashboard.Router, only: [live_dashboard: 2]

  alias AshAuthentication.Plug.Helpers, as: AuthHelpers

  # Sobelow's Config.CSP/Config.Headers checks only recognize a literal
  # `plug :put_secure_browser_headers, %{...}` call with a static map. This
  # pipeline's CSP needs a per-request script-src nonce (see
  # `put_content_security_policy/2` below), which cannot be a compile-time
  # literal, so it calls `Phoenix.Controller.put_secure_browser_headers/2`
  # from a custom plug instead. Both headers are genuinely present; verify
  # with `curl -I` against any browser-pipeline route.
  # sobelow_skip ["Config.CSP", "Config.Headers"]
  pipeline :browser do
    # Adds the request to any error this request reports to our own Observe.
    # In this pipeline rather than the endpoint, so the ingest routes this app
    # serves, including the reports it sends itself, carry no request context.
    plug Sentry.PlugContext
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AlplusWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_content_security_policy
    plug :load_from_session
    plug :enforce_session_inactivity_timeout
    plug :identify_to_observe
    plug :enforce_login_lockout
    plug AlplusWeb.Plugs.AuthTurnstile
  end

  # Same-origin WebMCP calls use the signed-in browser session and CSRF
  # protection, but negotiate JSON rather than the HTML browser pipeline.
  pipeline :webmcp do
    plug Sentry.PlugContext
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :load_from_session
    plug :enforce_session_inactivity_timeout
    plug :identify_to_observe
  end

  pipeline :blog_data do
    plug :accepts, ["json", "rss", "xml"]

    plug :put_secure_browser_headers, %{
      "content-security-policy" => "default-src 'none'; frame-ancestors 'none'"
    }
  end

  # Public shares carry a bearer in the path. Keep this route stateless and
  # redact the path before request completion or error telemetry can capture it.
  # sobelow_skip ["Config.Headers"]
  pipeline :public_share do
    plug :accepts, ["html"]
    plug :put_root_layout, html: {AlplusWeb.Layouts, :root}
    plug AlplusWeb.Plugs.RedactShareToken
    plug :put_content_security_policy
  end

  # sobelow_skip ["Config.Headers"]
  pipeline :public_status do
    plug :accepts, ["html"]
    plug :put_root_layout, html: {AlplusWeb.Layouts, :root}
    plug :put_content_security_policy
  end

  # sobelow_skip ["Config.Headers"]
  pipeline :public_changelog do
    plug :accepts, ["html", "rss", "json"]
    plug :put_root_layout, html: {AlplusWeb.Layouts, :root}
    plug :put_content_security_policy
  end

  # This pipeline is intentionally sessionless and omits X-Frame-Options.
  # The embed has no cookies, CSRF token, or authenticated action. Its CSP
  # exception cannot apply to any session-bearing route.
  # sobelow_skip ["Config.Headers"]
  pipeline :public_status_embed do
    plug :accepts, ["html", "json"]
    plug :put_root_layout, html: {AlplusWeb.Layouts, :root}
    plug :put_embed_security_headers
  end

  # Public marketing pages only. `AcquisitionAttribution` records the first
  # public page of a session so an organic signup can be credited to the
  # page that earned it. Never applied to `/dashboard/*`: an authenticated
  # console request is not a landing page.
  pipeline :marketing do
    # Collapse URL variants before anything renders, so one page is never
    # served from two URLs (PRD §5).
    plug AlplusWeb.Plugs.CanonicalPath
    plug AlplusWeb.Plugs.AcquisitionAttribution
  end

  pipeline :mcp do
    plug AlplusWeb.Plugs.McpAuth
    plug AlplusWeb.Plugs.McpScopeGate
  end

  # OAuth discovery is public and must not initialize a browser session or
  # require MCP bearer authentication.
  pipeline :mcp_discovery do
    plug :accepts, ["json"]
  end

  pipeline :public_json do
    plug :accepts, ["json"]
  end

  # OAuth token and revocation endpoints are sessionless JSON: no cookie
  # session, CSRF, or MCP bearer. Clients authenticate token exchanges with
  # the code+PKCE or refresh-token grant.
  pipeline :oauth_token do
    plug :accepts, ["json"]
  end

  # This pipeline serves third-party cron pings (healthchecks.io-style):
  # `HeartbeatController.ping` only ever sends an empty-body status code, so
  # there is no HTML/session content for CSRF or secure browser headers to
  # protect, and the token in the URL (not a cookie) is the auth boundary.
  # sobelow_skip ["Config.Headers"]
  pipeline :heartbeat do
    plug AlplusWeb.Plugs.UseIngestRepo
    plug AlplusWeb.Plugs.IngestAdmission, {:global, :heartbeat}
    plug AlplusWeb.Plugs.IngestFault
    plug AlplusWeb.Plugs.HeartbeatRateLimit
    plug :accepts, ["html", "json"]
  end

  pipeline :measure do
    plug :accepts, ["json", "text"]
    plug AlplusWeb.Plugs.RedactMeasurePeer
  end

  # Measure ingest (`POST /m`): the shared preamble's token step. The site
  # token travels in the payload, so raw-body capture and token resolution
  # run before rate limiting; envelope parsing stays in the controller.
  #
  # `AlplusWeb.Plugs.ParseBody` skips `Plug.Parsers` on every ingest path, so
  # each pipeline below fetches the query params itself. Here they also carry
  # a query-string site token.
  #
  # Warning: `:accepts` runs LAST on every ingest pipeline. It raises
  # `Phoenix.NotAcceptableError` (406), and a request that fails the
  # credential must answer the published 401 or tarpit first. Putting
  # content negotiation ahead of the credential let `Accept: text/html` turn
  # a missing bearer into a 406 and let an unknown Measure token skip its
  # tarpit.
  pipeline :measure_ingest do
    plug AlplusWeb.Plugs.UseIngestRepo
    plug :fetch_query_params
    plug AlplusWeb.Plugs.RedactMeasurePeer
    plug AlplusWeb.Plugs.IngestRawBody, max_bytes: 1_048_576
    plug AlplusWeb.Plugs.IngestMeasureSource
    # Global admission runs after the token resolves, as on the error
    # pipeline: an unknown token sits in its tarpit without holding one of
    # the sixteen global Measure slots for the whole of that delay.
    plug AlplusWeb.Plugs.IngestAdmission, {:global, :measure}
    plug AlplusWeb.Plugs.IngestFault
    plug AlplusWeb.Plugs.IngestAdmission, {:tenant, :measure}
    plug AlplusWeb.Plugs.IngestRateLimit, :measure
    plug :accepts, ["json", "text"]
  end

  # Observe error ingest: authenticate before scarce-resource admission. An
  # invalid bearer therefore cannot occupy a global or per-Source lease.
  # The shared preamble then applies admission, rate limiting, content
  # negotiation, raw-body capture, and the 1 MiB envelope cap.
  #
  # Errors and sessions keep SEPARATE pipelines because they publish
  # separate rate-limit budgets (issue #12): one pipeline per bucket.
  pipeline :error_ingest do
    plug AlplusWeb.Plugs.UseIngestRepo
    plug AlplusWeb.Plugs.IngestAuth
    plug AlplusWeb.Plugs.IngestAdmission, {:global, :errors}
    plug AlplusWeb.Plugs.IngestFault
    plug :fetch_query_params
    plug AlplusWeb.Plugs.IngestAdmission, {:tenant, :errors}
    plug AlplusWeb.Plugs.IngestRateLimit, :errors
    plug :accepts, ["json"]
    plug AlplusWeb.Plugs.IngestRawBody, max_bytes: 1_048_576
  end

  # Sentry SDK ingest shares the error budget with `/e/errors`. The query
  # parameters come first because a Sentry SDK may send its key there. There
  # is no `:accepts`: the SDKs post `application/x-sentry-envelope` and the
  # response is always JSON.
  pipeline :sentry_ingest do
    plug AlplusWeb.Plugs.UseIngestRepo
    plug :fetch_query_params
    plug AlplusWeb.Plugs.IngestAuth, {:observe, :sentry}
    plug AlplusWeb.Plugs.IngestAdmission, {:global, :errors}
    plug AlplusWeb.Plugs.IngestFault
    plug AlplusWeb.Plugs.IngestAdmission, {:tenant, :errors}
    plug AlplusWeb.Plugs.IngestRateLimit, :errors
    plug AlplusWeb.Plugs.IngestRawBody, max_bytes: 1_048_576
  end

  pipeline :session_ingest do
    plug AlplusWeb.Plugs.UseIngestRepo
    plug AlplusWeb.Plugs.IngestAuth
    plug AlplusWeb.Plugs.IngestAdmission, {:global, :sessions}
    plug AlplusWeb.Plugs.IngestFault
    plug :fetch_query_params
    plug AlplusWeb.Plugs.IngestAdmission, {:tenant, :sessions}
    plug AlplusWeb.Plugs.IngestRateLimit, :sessions
    plug :accepts, ["json"]
    plug AlplusWeb.Plugs.IngestRawBody, max_bytes: 1_048_576
  end

  # Product analytics ingest (ADR 0007). Its own pipeline, so its budget is
  # independent of Observe and Measure, and its own Source type, so an
  # analytics write key reaches no other route. CORS runs first and answers
  # the browser preflight before authentication: a preflight carries no
  # `Authorization` header, so authenticating it would refuse every browser
  # client. The body cap holds 100 events with room for properties.
  pipeline :product_event_ingest do
    plug AlplusWeb.Plugs.UseIngestRepo
    plug AlplusWeb.Plugs.AnalyticsIngestCors
    plug AlplusWeb.Plugs.IngestAuth, :analytics
    plug AlplusWeb.Plugs.IngestAdmission, {:global, :product_events}
    plug AlplusWeb.Plugs.IngestFault
    plug :fetch_query_params
    plug AlplusWeb.Plugs.IngestAdmission, {:tenant, :product_events}
    plug AlplusWeb.Plugs.IngestRateLimit, :product_events
    plug :accepts, ["json"]
    plug AlplusWeb.Plugs.IngestRawBody, max_bytes: 262_144
  end

  # Source-map artifact upload: same bearer credential and preamble shape
  # as `/e/errors`, but a much larger body budget for multi-megabyte maps.
  pipeline :artifact_ingest do
    plug AlplusWeb.Plugs.UseIngestRepo
    plug AlplusWeb.Plugs.IngestAuth
    plug AlplusWeb.Plugs.IngestAdmission, {:global, :artifacts}
    plug AlplusWeb.Plugs.IngestFault
    plug :fetch_query_params
    plug AlplusWeb.Plugs.IngestAdmission, {:tenant, :artifacts}
    plug AlplusWeb.Plugs.IngestRateLimit, :artifacts
    plug :accepts, ["json"]
    plug AlplusWeb.Plugs.IngestRawBody, max_bytes: 20 * 1024 * 1024
  end

  # The endpoint body reader preserves exact wire bytes before Plug.Parsers
  # decodes them. Keep this public pipeline free of auth and JSON assumptions:
  # Stripe's signature covers the raw payload, not a reconstructed map.
  pipeline :stripe_webhook do
  end

  # Keep the health check outside browser authentication and CSRF handling.
  # The endpoint checks both the Phoenix process and its database dependency.
  scope "/", AlplusWeb do
    get "/health", HealthController, :show
  end

  scope "/", AlplusWeb do
    pipe_through :heartbeat

    get "/h/:token", HeartbeatController, :ping_get
    post "/h/:token", HeartbeatController, :ping

    # Exit-code form: `@alplus/sdk`'s `exitCode` option and the documented
    # `curl ".../h/$TOKEN/$?"` crontab one-liner both ping this shape.
    get "/h/:token/:exit_code", HeartbeatController, :ping_get
    post "/h/:token/:exit_code", HeartbeatController, :ping
  end

  scope "/", AlplusWeb do
    pipe_through :measure_ingest

    post "/m", MeasureController, :ingest
  end

  scope "/", AlplusWeb do
    pipe_through :measure

    get "/m.js", MeasureScriptController, :show
  end

  scope "/", AlplusWeb do
    pipe_through :public_share

    get "/share/:token", MeasureShareController, :show
  end

  scope "/", AlplusWeb do
    pipe_through :public_changelog

    # The project identity owns all canonical Changelog paths. Keep the fixed
    # feed routes before the entry route so a suffix is never treated as an
    # entry slug.
    get "/status/:status_slug/changelog.rss", ChangelogController, :project_rss
    get "/status/:status_slug/changelog.json", ChangelogController, :project_json
    get "/status/:status_slug/changelog/:entry_slug", ChangelogController, :project_entry
    get "/status/:status_slug/changelog", ChangelogController, :project
  end

  scope "/", AlplusWeb do
    pipe_through :public_status

    get "/status/:status_slug", StatusController, :show
    get "/status/:status_slug/history", StatusController, :history
    get "/status/:status_slug/feed.xml", StatusController, :feed
  end

  scope "/", AlplusWeb do
    pipe_through :public_changelog

    # First-party feed URLs are fixed paths and must precede the legacy
    # one-segment route below.
    get "/changelog.rss", ChangelogController, :marketing_rss
    get "/changelog.json", ChangelogController, :marketing_json
  end

  scope "/", AlplusWeb do
    pipe_through :public_changelog

    # Legacy HTML addresses redirect permanently. Feeds keep their old shape
    # and links so standard consumers can continue polling them.
    get "/changelog/:slug/entries/:entry_slug", ChangelogController, :entry
    # Plug does not allow a dot directly after a dynamic segment. The
    # controller keeps this one-segment route explicit and dispatches its
    # `.rss` and `.json` suffixes without a glob.
    get "/changelog/:segment", ChangelogController, :legacy_segment
  end

  scope "/", AlplusWeb do
    pipe_through :public_status_embed

    get "/status/:status_slug/embed", StatusController, :embed
    get "/status/:status_slug/embed.json", StatusController, :embed_json
  end

  scope "/", AlplusWeb do
    pipe_through :error_ingest

    post "/e/errors", ErrorIngestController, :ingest
  end

  scope "/", AlplusWeb do
    pipe_through :sentry_ingest

    post "/api/:project_id/envelope", SentryIngestController, :ingest
  end

  scope "/", AlplusWeb do
    pipe_through :session_ingest

    post "/e/sessions", SessionIngestController, :ingest
  end

  scope "/", AlplusWeb do
    pipe_through :artifact_ingest

    post "/e/artifacts", ArtifactUploadController, :create
  end

  # Product analytics ingest (ADR 0007). Declare the longer path first: a
  # router matches in declaration order, so `/v1/events` declared above
  # would swallow nothing, but keeping the pair adjacent and ordered makes
  # the intent obvious. `options` answers the browser preflight.
  scope "/", AlplusWeb do
    pipe_through :product_event_ingest

    post "/v1/events/batch", ProductEventIngestController, :batch
    options "/v1/events/batch", ProductEventIngestController, :batch
    post "/v1/events", ProductEventIngestController, :create
    options "/v1/events", ProductEventIngestController, :create
  end

  scope "/", AlplusWeb do
    pipe_through :mcp_discovery

    get "/.well-known/oauth-protected-resource",
        McpDiscoveryController,
        :protected_resource

    get "/.well-known/oauth-protected-resource/mcp",
        McpDiscoveryController,
        :protected_resource

    get "/.well-known/oauth-protected-resource/mcp/org/:org_token",
        McpDiscoveryController,
        :protected_resource

    get "/.well-known/oauth-authorization-server",
        McpDiscoveryController,
        :authorization_server
  end

  scope "/", AlplusWeb do
    pipe_through :public_json

    get "/product-facts.json", ProductFactsController, :index
  end

  scope "/", AlplusWeb do
    pipe_through :browser

    get "/oauth/authorize", OAuthAuthorizationController, :new
    post "/oauth/authorize", OAuthAuthorizationController, :create

    get "/activate", OAuthActivationController, :new
    post "/activate", OAuthActivationController, :create
  end

  scope "/", AlplusWeb do
    pipe_through :oauth_token

    post "/oauth/token", OAuthTokenController, :create
    post "/oauth/revoke", OAuthRevocationController, :create
    post "/oauth/register", OAuthRegistrationController, :create
    post "/oauth/device_authorization", OAuthDeviceController, :create
  end

  scope "/", alias: false do
    pipe_through :mcp
    # Dispatch charges once because it resolves each tool's cost weight.

    forward "/mcp", AlplusWeb.Plugs.McpHttp,
      handler: Alplus.Mcp.Server,
      handler_opts: {AlplusWeb.Plugs.McpAuth, :handler_opts, []},
      server_info: %{name: "Alplus", version: "1.0.0"},
      protocol_mode: :prefer_modern,
      path: "/mcp"
  end

  scope "/", AlplusWeb do
    pipe_through :webmcp
    get "/dashboard/webmcp/catalog", WebMcpController, :catalog
    post "/dashboard/webmcp/call", WebMcpController, :execute
  end

  # The analytics export is a streamed file download, so it is a controller
  # rather than a LiveView. It runs on the browser pipeline: the signed-in
  # session is the credential, and an ingest write key cannot reach it.
  scope "/", AlplusWeb do
    pipe_through :browser

    get "/dashboard/orgs/:org_token/projects/:project_token/analytics/export",
        AnalyticsExportController,
        :show
  end

  scope "/", AlplusWeb do
    pipe_through :stripe_webhook

    post "/webhooks/stripe", StripeWebhookController, :create
  end

  # Stashes the invitation accept page's path as the session `return_to`
  # for a signed-out visitor, so `AlplusWeb.AuthController.do_success/3`
  # (already reading `return_to` after sign-in/confirmation) sends them
  # back here to finish accepting. Keeps the token out of any query
  # string across that round trip — it travels only in the path, both in
  # the emailed link and in this stashed value.
  pipeline :stash_invitation_return_to do
    plug :put_invitation_return_to
  end

  scope "/", AlplusWeb do
    pipe_through [:browser, :stash_invitation_return_to]

    live "/invitations/:token", InvitationAcceptLive, :show
  end

  scope "/", AlplusWeb do
    pipe_through :browser

    # `AlplusWeb.ConnectGate` gates every project-scoped page in this
    # session behind an agent connection (it no-ops without a
    # `project_token`, and exempts the Connect page itself). Declared
    # here, once, rather than per view: a new project route is gated by
    # default. The macro prepends its own hook, so `current_user` is
    # already assigned when the gate runs.
    ash_authentication_live_session :authenticated_routes,
      on_mount: [{AlplusWeb.ConnectGate, :default}] do
      # in each liveview, add one of the following at the top of the module:
      #
      # If an authenticated user must be present:
      # on_mount {AlplusWeb.LiveUserAuth, :live_user_required}
      #
      # If an authenticated user *may* be present:
      # on_mount {AlplusWeb.LiveUserAuth, :live_user_optional}
      #
      # If an authenticated user must *not* be present:
      # on_mount {AlplusWeb.LiveUserAuth, :live_no_user}

      # PostDeploy-owned registration page (ARCHITECTURE.md §10): renders Turnstile
      # itself, which the stock AshAuthenticationPhoenix register page
      # cannot. `register_path` is intentionally left unset on
      # `sign_in_route` below so it does not also claim this path.
      live "/register", RegisterLive, :new

      # Every authenticated route lives under `/dashboard/` (ARCHITECTURE.md
      # §9). Org AND project are both path segments (`:org_token`,
      # `:project_token` below) — ARCHITECTURE.md §9 still describes
      # project as a query param; that text predates this route shape and
      # is stale. Path segments are the shipped, canonical contract: they
      # make org → project → product deep-linkable and bookmarkable, which
      # a `?project_id=` query param is not (it silently drops when a link
      # is copied from a page that ignores it). Environment alone stays a
      # query param/tag filter — it is not a distinct resource
      # (ARCHITECTURE.md §4). See the DECISION note in issue #29 for the
      # founder sign-off this still needs before ARCHITECTURE.md §9 itself
      # is edited to match.
      live "/dashboard", DashboardLive, :index
      live "/dashboard/account", AccountLive, :show
      # The operator's own account. Org-less on purpose: a display name does
      # not belong to a tenant, so this route carries no `:org_token` and
      # never builds an org scope.
      live "/dashboard/orgs/new", OrgCreateLive, :new
      live "/dashboard/orgs/:org_token/projects", ProjectsLive, :index
      live "/dashboard/orgs/:org_token/projects/:project_token", ProjectLive, :show

      live "/dashboard/orgs/:org_token/projects/:project_token/connect",
           AgentConnectionLive,
           :show

      live "/dashboard/orgs/:org_token/projects/:project_token/observe", ObserveLive, :index

      # Status pages are a Monitor sub-feature. The old top-level `/status`
      # management URL redirects into the Monitor hierarchy; the public
      # `/status/:status_slug` routes above are unchanged.
      live "/dashboard/orgs/:org_token/projects/:project_token/status",
           StatusPagesLive,
           :legacy_redirect

      live "/dashboard/orgs/:org_token/projects/:project_token/observe/new",
           RetiredRouteRedirectLive,
           :observe_new

      live "/dashboard/orgs/:org_token/projects/:project_token/observe/issues/:issue_id",
           ObserveIssueLive,
           :show

      live "/dashboard/orgs/:org_token/projects/:project_token/observe/:source_id",
           ObserveDetailLive,
           :show

      # Longer analytics paths first: `*/analytics` must not swallow the
      # screens under it.
      live "/dashboard/orgs/:org_token/projects/:project_token/analytics/events/:event_name",
           AnalyticsEventLive,
           :show

      live "/dashboard/orgs/:org_token/projects/:project_token/analytics/events",
           AnalyticsEventsLive,
           :index

      live "/dashboard/orgs/:org_token/projects/:project_token/analytics/funnels",
           AnalyticsFunnelsLive,
           :index

      live "/dashboard/orgs/:org_token/projects/:project_token/analytics/retention",
           AnalyticsRetentionLive,
           :index

      live "/dashboard/orgs/:org_token/projects/:project_token/analytics/live",
           AnalyticsLiveEventsLive,
           :index

      live "/dashboard/orgs/:org_token/projects/:project_token/analytics",
           AnalyticsLive,
           :index

      live "/dashboard/orgs/:org_token/projects/:project_token/measure", MeasureLive, :index

      live "/dashboard/orgs/:org_token/projects/:project_token/measure/seo",
           MeasureSeoLive,
           :index

      live "/dashboard/orgs/:org_token/projects/:project_token/measure/:source_id",
           MeasureDetailLive,
           :show

      # One project-owned Public destination. Status, Changelog, and Settings
      # are durable sections below this route.
      live "/dashboard/orgs/:org_token/projects/:project_token/public",
           PublicPageRedirectLive,
           :index

      live "/dashboard/orgs/:org_token/projects/:project_token/public/status",
           StatusPagesLive,
           :public

      live "/dashboard/orgs/:org_token/projects/:project_token/public/status/services",
           StatusWorkspaceLive,
           :services

      live "/dashboard/orgs/:org_token/projects/:project_token/public/status/services/new",
           RetiredRouteRedirectLive,
           :status_service_new

      live "/dashboard/orgs/:org_token/projects/:project_token/public/status/services/:service_id",
           StatusWorkspaceLive,
           :service_show

      live "/dashboard/orgs/:org_token/projects/:project_token/public/status/incidents",
           StatusWorkspaceLive,
           :incidents

      live "/dashboard/orgs/:org_token/projects/:project_token/public/status/incidents/new",
           RetiredRouteRedirectLive,
           :status_incident_new

      live "/dashboard/orgs/:org_token/projects/:project_token/public/status/incidents/:incident_id",
           StatusWorkspaceLive,
           :incident_show

      live "/dashboard/orgs/:org_token/projects/:project_token/public/status/settings",
           StatusWorkspaceLive,
           :settings

      live "/dashboard/orgs/:org_token/projects/:project_token/public/status/announcements",
           StatusWorkspaceLive,
           :announcements

      live "/dashboard/orgs/:org_token/projects/:project_token/public/status/history",
           StatusWorkspaceLive,
           :history

      live "/dashboard/orgs/:org_token/projects/:project_token/public/status/maintenance",
           StatusWorkspaceLive,
           :maintenance

      live "/dashboard/orgs/:org_token/projects/:project_token/public/status/maintenance/new",
           RetiredRouteRedirectLive,
           :status_maintenance_new

      live "/dashboard/orgs/:org_token/projects/:project_token/public/changelog",
           ChangelogEntriesLive,
           :redirect

      live "/dashboard/orgs/:org_token/projects/:project_token/public/changelog/entries",
           ChangelogEntriesLive,
           :index

      live "/dashboard/orgs/:org_token/projects/:project_token/public/changelog/entries/:entry_handle",
           ChangelogEntryLive,
           :show

      live "/dashboard/orgs/:org_token/projects/:project_token/public/changelog/activity",
           ChangelogActivityLive,
           :index

      live "/dashboard/orgs/:org_token/projects/:project_token/public/settings",
           PublicPageSettingsLive,
           :index

      live "/dashboard/orgs/:org_token/projects/:project_token/monitor", MonitorLive, :index

      live "/dashboard/orgs/:org_token/projects/:project_token/monitor/new",
           RetiredRouteRedirectLive,
           :monitor_new

      live "/dashboard/orgs/:org_token/projects/:project_token/monitor/status-pages",
           PublicPageLegacyRedirectLive,
           :status_collection

      # Status is one project workspace. Keep the collection route above as a
      # compatibility alias while new links enter through this route.
      live "/dashboard/orgs/:org_token/projects/:project_token/monitor/status",
           PublicPageLegacyRedirectLive,
           :status_collection

      live "/dashboard/orgs/:org_token/projects/:project_token/monitor/status-pages/new",
           PublicPageLegacyRedirectLive,
           :status_new

      # The bare page URL is the workspace default and renders Services: an
      # operator opens a status page to check what customers see, and services
      # are that answer. `/services` stays as the durable named route.
      live "/dashboard/orgs/:org_token/projects/:project_token/monitor/status-pages/:page_id",
           PublicPageLegacyRedirectLive,
           :status_page

      live "/dashboard/orgs/:org_token/projects/:project_token/monitor/status-pages/:page_id/services",
           PublicPageLegacyRedirectLive,
           :status_services

      live "/dashboard/orgs/:org_token/projects/:project_token/monitor/status-pages/:page_id/services/new",
           PublicPageLegacyRedirectLive,
           :status_service_new

      live "/dashboard/orgs/:org_token/projects/:project_token/monitor/status-pages/:page_id/services/:service_id",
           PublicPageLegacyRedirectLive,
           :status_service

      live "/dashboard/orgs/:org_token/projects/:project_token/monitor/status-pages/:page_id/incidents",
           PublicPageLegacyRedirectLive,
           :status_incidents

      live "/dashboard/orgs/:org_token/projects/:project_token/monitor/status-pages/:page_id/incidents/new",
           PublicPageLegacyRedirectLive,
           :status_incident_new

      live "/dashboard/orgs/:org_token/projects/:project_token/monitor/status-pages/:page_id/incidents/:incident_id",
           PublicPageLegacyRedirectLive,
           :status_incident

      live "/dashboard/orgs/:org_token/projects/:project_token/monitor/status-pages/:page_id/settings",
           PublicPageLegacyRedirectLive,
           :status_settings

      live "/dashboard/orgs/:org_token/projects/:project_token/monitor/status-pages/:page_id/announcements",
           PublicPageLegacyRedirectLive,
           :status_announcements

      live "/dashboard/orgs/:org_token/projects/:project_token/monitor/status-pages/:page_id/history",
           PublicPageLegacyRedirectLive,
           :status_history

      live "/dashboard/orgs/:org_token/projects/:project_token/monitor/status-pages/:page_id/maintenance",
           PublicPageLegacyRedirectLive,
           :status_maintenance

      live "/dashboard/orgs/:org_token/projects/:project_token/monitor/status-pages/:page_id/maintenance/new",
           PublicPageLegacyRedirectLive,
           :status_maintenance_new

      live "/dashboard/orgs/:org_token/projects/:project_token/monitor/:monitor_id",
           MonitorDetailLive,
           :show

      live "/dashboard/orgs/:org_token/projects/:project_token/monitor/:monitor_id/edit",
           RetiredRouteRedirectLive,
           :monitor_edit

      # Changelog is agent-written: entries arrive over MCP, humans review
      # them here. The bare product URL redirects to the Entries tab.
      live "/dashboard/orgs/:org_token/projects/:project_token/changelog",
           PublicPageLegacyRedirectLive,
           :changelog

      live "/dashboard/orgs/:org_token/projects/:project_token/changelog/entries",
           PublicPageLegacyRedirectLive,
           :changelog_entries

      live "/dashboard/orgs/:org_token/projects/:project_token/changelog/entries/:entry_handle",
           PublicPageLegacyRedirectLive,
           :changelog_entry

      live "/dashboard/orgs/:org_token/projects/:project_token/changelog/settings",
           PublicPageLegacyRedirectLive,
           :changelog_settings

      live "/dashboard/orgs/:org_token/projects/:project_token/changelog/activity",
           PublicPageLegacyRedirectLive,
           :changelog_activity

      # Compatibility routes are intentionally redirect-only. They never
      # render a pillar without an explicit project scope.
      live "/dashboard/orgs/:org_token/observe", ProjectRouteLive, :observe
      live "/dashboard/orgs/:org_token/measure", ProjectRouteLive, :measure
      live "/dashboard/orgs/:org_token/monitor", ProjectRouteLive, :monitor
      live "/dashboard/orgs/:org_token/team", TeamLive, :index
      live "/dashboard/orgs/:org_token/billing", BillingLive, :index
      live "/dashboard/orgs/:org_token/settings/notifications", NotificationSettingsLive, :index
      live "/dashboard/orgs/:org_token/settings", SettingsLive, :index
    end
  end

  scope "/blog", AlplusWeb do
    pipe_through :blog_data
    get "/feed.xml", BlogController, :feed
    get "/posts.json", BlogController, :posts_json
    get "/posts/:slug", BlogController, :post_json
  end

  scope "/", AlplusWeb do
    pipe_through [:browser, :marketing]
    get "/changelog", ChangelogController, :marketing
    get "/blog", BlogController, :index
    get "/blog/:slug", BlogController, :show

    # The one marketing route that is a LiveView (ARCHITECTURE.md §9). The
    # homepage's four overview switches change one frame in place instead of
    # reloading the document; every other marketing page below stays a
    # server-rendered controller page. Deliberately outside any
    # `live_session`: this page must mount for a visitor with no session and
    # no user at all, and `AlplusWeb.LiveUserAuth`'s `:current_user` hook
    # assigns `@current_user` (or `nil`) from whatever session there is.
    live "/", HomeLive, :home

    get "/pricing", PageController, :pricing
    get "/free-uptime-monitoring", PageController, :free_uptime_monitoring
    get "/free-cron-job-monitoring", PageController, :free_cron_job_monitoring

    # The monitoring cluster and the high-intent guides are `Content.Guide`
    # rows rendered by the same template, so they need no per-page action.
    # Both segments are fixed prefixes, which keeps these from swallowing
    # unrelated top-level paths.
    get "/monitoring", PageController, :monitoring_hub
    get "/error-tracking", PageController, :error_tracking_hub
    get "/analytics", PageController, :analytics_hub
    get "/monitoring/:slug", PageController, :monitoring_page
    get "/guides", PageController, :guides_index
    get "/guides/:slug", PageController, :guide
    get "/privacy", PageController, :privacy
    get "/about", PageController, :about
    get "/terms", PageController, :terms
    get "/alternatives", PageController, :alternatives_index
    get "/alternatives/:slug", PageController, :alternatives_show

    # The Help Center. Leaf pages are `Content.Guide` rows under `/docs/`,
    # so the sitemap, canonical path and SEO audit cover them with no extra
    # wiring. Explicit segments, never `*path` (AGENTS.md).
    get "/docs", PageController, :docs_index
    get "/docs/search", PageController, :search
    get "/docs/:section", PageController, :doc
    get "/docs/:section/:topic", PageController, :doc

    # The second marketing LiveView (ARCHITECTURE.md §9). The check is a live
    # HTTP request of up to ten seconds, so it runs over the socket and keeps
    # the visitor's address, pending state and verdict in one document. The
    # dead render is the complete, indexable form. The handoff actions below
    # stay controller actions, because only they can write the session.
    live "/tools/website-health-check", WebsiteHealthCheckLive, :new
    post "/tools/website-health-check/monitor", WebsiteHealthCheckController, :monitor
    get "/tools/website-health-check/continue", WebsiteHealthCheckController, :continue
    post "/tools/website-health-check/continue", WebsiteHealthCheckController, :confirm
  end

  scope "/", AlplusWeb do
    pipe_through :browser

    get "/sitemap.xml", SitemapController, :index
    get "/llms.txt", LlmsController, :index

    auth_routes AuthController, Alplus.Accounts.User, path: "/auth"
    sign_out_route AuthController

    # Auto-sign-in after `/register` (onboarding overhaul, decision "land
    # in-app"): `RegisterLive` cannot itself write the session cookie (it
    # runs over the LiveView socket, not a plug `conn`), so it renders a
    # same-origin, CSRF-protected `<form method="post">` carrying the
    # register action's own sign-in JWT in the POST body (never a query
    # string, so it never lands in a log or a `Referer` header) and
    # auto-submits it. This controller action is the only thing that reads
    # that body and turns it into a real session, exactly like
    # `AuthController.do_success/3` already does for sign-in.
    post "/register/complete", AuthController, :complete_registration

    # Remove these if you'd like to use your own authentication views
    #
    # `register_path` is left unset on purpose: `/register` is our own
    # `AlplusWeb.RegisterLive` (added above), which collects the Turnstile
    # token the stock register live view has no way to ask for.
    sign_in_route reset_path: "/reset",
                  auth_routes_prefix: "/auth",
                  layout: {AlplusWeb.Layouts, :auth_live},
                  on_mount: [
                    {AlplusWeb.LiveUserAuth, :live_no_user},
                    {AlplusWeb.AuthPageTitle, :sign_in}
                  ],
                  overrides: [
                    AlplusWeb.AuthOverrides.SignInBanner,
                    AlplusWeb.AuthOverrides,
                    Elixir.AshAuthentication.Phoenix.Overrides.Default
                  ]

    # Remove this if you do not want to use the reset password feature
    reset_route auth_routes_prefix: "/auth",
                layout: {AlplusWeb.Layouts, :auth_live},
                on_mount: [{AlplusWeb.AuthPageTitle, :reset}],
                overrides: [
                  AlplusWeb.AuthOverrides.ResetBanner,
                  AlplusWeb.AuthOverrides,
                  Elixir.AshAuthentication.Phoenix.Overrides.Default
                ]

    # Remove this if you do not use the confirmation strategy
    confirm_route Alplus.Accounts.User, :confirm_new_user,
      auth_routes_prefix: "/auth",
      layout: {AlplusWeb.Layouts, :auth_live},
      on_mount: [{AlplusWeb.AuthPageTitle, :confirm_new_user}],
      overrides: [
        AlplusWeb.AuthOverrides.ConfirmNewUserBanner,
        AlplusWeb.AuthOverrides,
        Elixir.AshAuthentication.Phoenix.Overrides.Default
      ]

    # Profile email-change re-verification (Alplus.Accounts.User's
    # `:update_profile`, ARCHITECTURE.md §10): a second confirmation
    # add-on with its own `confirmed_at_field` (`email_confirmed_at`), so
    # requesting an email change never nils the login-gating
    # `confirmed_at` that `AlplusWeb.LiveUserAuth` checks on every
    # `/dashboard/*` mount.
    confirm_route Alplus.Accounts.User, :confirm_email_change,
      auth_routes_prefix: "/auth",
      layout: {AlplusWeb.Layouts, :auth_live},
      as: :auth_email_change,
      on_mount: [{AlplusWeb.AuthPageTitle, :confirm_email_change}],
      overrides: [
        AlplusWeb.AuthOverrides.ConfirmEmailChangeBanner,
        AlplusWeb.AuthOverrides,
        Elixir.AshAuthentication.Phoenix.Overrides.Default
      ]

    # No magic-link route. PostDeploy authenticates with email and password only
    # (ARCHITECTURE.md §10). The strategy is not defined on the User
    # resource, so this route would fail at request time.
  end

  pipeline :admin do
    plug AlplusWeb.Plugs.RequireFounder
  end

  scope "/admin", AlplusWeb do
    pipe_through [:browser, :admin]

    ash_authentication_live_session :founder_admin,
      on_mount: [{AlplusWeb.Plugs.RequireFounder, :live}] do
      live "/", Admin.HomeLive, :index
    end

    live_dashboard "/system",
      metrics: AlplusWeb.Telemetry,
      live_session_name: :founder_system,
      on_mount: [
        AshAuthentication.Phoenix.LiveSession,
        {AlplusWeb.Plugs.RequireFounder, :live}
      ]
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:alplus, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AlplusWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Drops the session once it's been idle past the 7-day inactivity
  # window (Alplus.Accounts.SessionActivity), even though the underlying
  # token hasn't hit its 30-day absolute expiry yet. Runs after
  # `load_from_session`, so `current_user` is set only when we decide to
  # keep the session.
  defp enforce_session_inactivity_timeout(conn, _opts) do
    now = System.system_time(:second)
    last_seen_at = get_session(conn, :last_seen_at)

    cond do
      is_nil(conn.assigns[:current_user]) ->
        conn

      Alplus.Accounts.SessionActivity.expired?(last_seen_at, now) ->
        conn
        |> AuthHelpers.revoke_session_tokens(:alplus)
        |> configure_session(drop: true)
        |> assign(:current_user, nil)

      true ->
        put_session(conn, :last_seen_at, now)
    end
  end

  # Dogfooding: names the signed-in user on any error this request reports to
  # our own Observe. Runs after the inactivity timeout, so a session we just
  # dropped is not attributed.
  defp identify_to_observe(conn, _opts) do
    case conn.assigns[:current_user] do
      %{id: id, email: email} ->
        Logger.metadata(user_id: id)
        Sentry.Context.set_user_context(%{id: id, email: to_string(email)})

      _ ->
        :ok
    end

    conn
  end

  # Locks a sign-in identity (by email and by IP) after too many failed
  # password attempts (ARCHITECTURE.md §10, §6). Scoped to the password
  # sign-in POST specifically — other auth routes (register, reset) have
  # their own gates (signup gate, HIBP/strength validations).
  defp enforce_login_lockout(conn, _opts) do
    if conn.method == "POST" and List.last(conn.path_info) == "sign_in" do
      ip = remote_ip_string(conn)

      email =
        case Map.get(conn.params, "user") do
          user when is_map(user) -> Map.get(user, "email")
          _ -> nil
        end

      keys =
        [{:ip, ip}] ++
          if(is_binary(email), do: [{:email, String.downcase(email)}], else: [])

      if Enum.any?(keys, &Alplus.Accounts.LoginLockout.locked?/1) do
        conn
        |> Phoenix.Controller.put_flash(
          :error,
          "Too many failed sign-in attempts. Try again in 15 minutes."
        )
        |> Phoenix.Controller.redirect(to: "/sign-in")
        |> halt()
      else
        conn
      end
    else
      conn
    end
  end

  # `script-src` uses a per-request nonce (read by `root.html.heex` as
  # `@csp_nonce`) so the theme-toggle inline script keeps running under a
  # strict policy. `style-src` keeps `unsafe-inline` because LiveView and a
  # few components (see console_components.ex, measure_live.ex,
  # billing_live.ex) set dynamic `style=` attributes that a nonce can't
  # reach; inline style injection is a lower-severity risk than script
  # injection, which this policy still blocks.
  defp put_content_security_policy(conn, _opts) do
    nonce = 16 |> :crypto.strong_rand_bytes() |> Base.encode64()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_secure_browser_headers(%{"content-security-policy" => content_security_policy(nonce)})
  end

  defp put_embed_security_headers(conn, _opts) do
    conn
    |> put_secure_browser_headers(%{})
    |> delete_resp_header("x-frame-options")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; style-src 'unsafe-inline'; img-src https: data:; frame-ancestors *"
    )
  end

  # Cloudflare Turnstile (`/register`) loads its widget script from
  # `challenges.cloudflare.com` and renders the challenge in an iframe from the
  # same host, so `script-src` and `frame-src` must allow it — otherwise the
  # widget never loads and `register_with_password` rejects every submit for a
  # missing token (ARCHITECTURE.md §10, §14).
  @turnstile_host "https://challenges.cloudflare.com"

  defp content_security_policy(nonce) do
    [
      "default-src 'self'",
      "script-src 'self' 'nonce-#{nonce}' #{@turnstile_host}",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' https: data:",
      "font-src 'self' data:",
      "connect-src 'self'",
      "frame-src #{@turnstile_host}",
      "base-uri 'self'",
      "form-action 'self'",
      "frame-ancestors 'none'",
      "object-src 'none'"
    ]
    |> Enum.join("; ")
  end

  defp put_invitation_return_to(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      put_session(conn, :return_to, conn.request_path)
    end
  end

  @doc false
  def remote_ip_string(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
