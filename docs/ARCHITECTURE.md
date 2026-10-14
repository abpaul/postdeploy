# PostDeploy Architecture — Target State

Goal: define where each type of logic and data belongs.
`docs/BUILD.md` defines the build order.
This document wins every conflict.
If a task contradicts this document, stop and report the conflict.

## 1. Monolith rules

1. Build one Phoenix application, one Postgres database, one deployment, one job system.
2. Do not rebuild Cloudflare primitives (Workers, D1, Durable Objects, Queues, KV, Neon, Hyperdrive) in Elixir.
3. Use Ash for the domain. Use OTP for concurrency. Use Oban for durability. Use Postgres for truth.

## 1a. Layers

Ash is ratified as the domain framework (founder decision, 2026-08-10, after
the Phase 2 vertical slice). This section is settled. Do not re-open it.

```text
Phoenix / LiveView          web and runtime framework
        │
        ▼
       Ash                  domain, actions, policies
        │
        ▼
   AshPostgres              normal persistence path
        │
        ▼
 PostgreSQL                 authoritative data
```

Native OTP runs beside Ash, not under it:

```text
OTP
├── monitor scheduling
├── concurrent checks
├── telemetry batching
├── ETS state
└── PubSub
```

Role of each layer:

```text
Phoenix           = web/runtime framework
Ash               = domain/application framework
AshPostgres       = normal persistence path
PostgreSQL        = authoritative data
OTP               = runtime concurrency
Oban              = durable work
R2 (S3 API)       = large/raw storage
Analytics Engine  = recent user analytics
```

Rules:

1. Model durable domain state as Ash resources. Write domain operations as Ash actions.
2. Do not write a Phoenix context that duplicates a resource Ash already owns.
3. Do not force hot paths (ingest, scheduling, batching) through Ash when direct code is clearer.
4. Ash exists to delete code. If an Ash extension lands and the old implementation stays, the migration is incomplete.

## 1b. Ecto

Keep Ecto under AshPostgres. Use direct Ecto only when Ash cannot express a required PostgreSQL feature.

Allowed exceptions: partition management, specialized migrations, bulk maintenance, database administration, rare performance-critical queries.

Document every direct Ecto escape hatch at the call site. Never bypass Ash for normal CRUD or domain actions.

## 2. Topology

```text
            Internet
               │
           Cloudflare  (DNS / CDN / WAF / DDoS / TLS)
               │
     ┌─────────┴──────────────────┐
     ▼                            ▼
OVH Compose               AE ingest Worker (planned adapter)
Phoenix monolith                  │
  │      │       │                ▼
  ▼      ▼       ▼        Cloudflare Analytics Engine
Postgres R2   AE reads
```

- Cloudflare owns DNS, CDN, WAF, DDoS, edge TLS, and outbound email for all hosts. All hosts proxy to Phoenix.
- OVH owns the shared VPS compute. PostDeploy uses isolated Docker Compose networks and PostgreSQL volumes.
- Cloudflare R2 stores raw payloads and release artifacts through the existing S3-compatible adapter.
- AWS EC2, RDS, S3, and ECR remain migration sources and rollback resources until cutover verification completes.
- Phoenix serves everything: marketing site, LiveView console, public API `/v1/*`, MCP `/mcp`, ingest (`/e/*`, `/m`, `/h/*`).
- Production uses the AE unavailable adapter. PostgreSQL rollups remain active.
- The planned Analytics Engine (AE) adapter holds short-term user-facing telemetry. Phoenix reads the AE SQL API directly. Writes pass through one minimal Worker: authenticate, validate shape, write. No business logic.

Data placement:

```text
AE  = recent interactive telemetry (~90 days, platform-fixed)
PostgreSQL = authoritative state and durable aggregates
R2  = raw telemetry, large payloads, exports
```

AE is never authoritative. When AE fails, show "data unavailable". Never show fake zeros. Read Postgres rollups for any window past AE retention.

## 2a. First-party clients and ingest paths

The rewrite ships three first-party client SDKs. They speak one wire contract
to the same public ingest paths — there is no client API layer.

```text
        clients                              public ingest (Phoenix)              domain
  @postdeploy/sdk (sdks/javascript)   ─┐
  postdeploy_sdk  (sdks/elixir)       ─┼─▶  POST /e/errors     ─▶  Observe: fingerprint → issue + event
  postdeploy      (sdks/ruby)         ─┘    POST /e/sessions   ─▶  Observe: crash-free session rollups
                                            POST /m, GET /m.js ─▶  Measure: cookieless rollups
                                            GET|POST /h/:token ─▶  Monitor: heartbeat ping
```

SDK rules: fail safe (never raise into the host), batch off the request path,
retry with jittered backoff honoring `Retry-After`, dedup within a window, and
emit a **byte-identical envelope across all three languages**. The published
host interface is configure once, auto-capture unhandled errors, keep
`capture_exception` / `capture_message` on the facade, and identify via
`set_user` / `set_tag` / `set_context`. Elixir documents `PostDeploy`,
`PostDeploy.Plug`, and `PostDeploy.Test`. Envelope, transport, and stack stay
hidden. The envelope is
a wire contract (§8, §5 rule 4): additive only. A server-validated golden
fixture (`sdks/contract/`) is matched by every SDK and parsed by the real
server parser, so a schema change breaks all three SDKs' tests at once. A
`:test`-only dependency on the published Elixir package drives an SDK-built envelope through the real ingest
route end-to-end (SDK bytes → real Issue/event/session rows).

The product and all three SDKs share one repository. The contract lives beside
them:

```text
sdks/contract/      golden wire fixtures + manifest (the product owns these)
sdks/elixir/        postdeploy_sdk  (Hex)
sdks/javascript/    @postdeploy/sdk (npm)
sdks/ruby/          postdeploy      (RubyGems)
```

Install names are the PostDeploy ones; the original `@alplus/sdk`,
`alplus_sdk` and `alplus-ruby` packages stay published as legacy aliases and
keep sending accepted envelopes (founder decision 2026-09-18).

Each SDK pins the contract version and every fixture digest in its own code
and reads `sdks/contract` from this checkout. Path-filtered CI is the
compatibility gate: any change under `sdks/contract/**` runs the product
suite, which contains the server parser anchor, and all three SDK suites, so
an incompatible fixture change fails before it can merge. Each SDK publishes
independently from its own directory on a namespaced tag — `elixir-v*`,
`js-v*`, `ruby-v*`.

The old Cloudflare/TypeScript stack (`apps/`, `workers/`, ported `packages/*`)
was decommissioned on 2026-08-12; only the published JS SDK survives, now at
`sdks/javascript`. Old-stack history is archived at the git tags
`legacy-master-archive` and `legacy-develop-archive`.

## 3. Domains

One OTP app, `alplus`. An Ash domain owns its resources and their tables. Cross-domain access uses the domain code interface only.

| Domain | Resources |
|---|---|
| `Alplus.Accounts` | users, tokens, verification, password reset (AshAuthentication; PostDeploy owns the whole auth path — never delegate to a managed auth service) |
| `Alplus.Orgs` | organizations, memberships, invitations |
| `Alplus.Projects` | projects (AshArchival, 14-day grace), api_keys, project_domains |
| `Alplus.Monitoring` | monitors + per-type configs, checks, incidents, heartbeat tokens, rollups; the scheduler stays native OTP (§6) |
| `Alplus.Observe` | issues, error_events, releases, release_artifacts, session rollups (crash-free) + release health; `SessionIngest.write/2` and `Artifacts.ingest/4` own ingest workflows; fingerprinting stays plain Elixir |
| `Alplus.Measure` | analytics configuration, custom events, dashboard shares, durable rollups |
| `Alplus.Billing` | stripe_customers, subscriptions, invoices, stripe_webhook_events, usage_periods, plan registry |
| `Alplus.Notifications` | channels, alert_rules, deliveries, adapters (email/Slack/Discord/webhook/Telegram) |
| `Alplus.Audit` | audit_logs |
| `Alplus.Content` | Page, Guide, Integration, Comparison, SeoTemplate |
| `Alplus.Changelog` | Changelog, Entry, Revision, SourceReference, ActivityEvent |
| `Alplus.PublicPages` | one project-owned public identity, publication state, and legacy aliases |
| `Alplus.Mcp` | OAuthClient (`mcp_oauth_clients`), OAuthGrant (`mcp_oauth_grants`), OAuthAuthorizationCode (`mcp_oauth_authorization_codes`), OAuthAccessToken (`mcp_oauth_access_tokens`), OAuthRefreshToken (`mcp_oauth_refresh_tokens`), IdempotencyRecord (`mcp_idempotency_records`); `OAuth.authorization_choices/1`, `resolve_selected_project/3`, and project-scoped grant-label projections |
| `Alplus.Ingest` | no resources — a thin boundary that validates, authenticates, and routes ingest requests |

Shared modules: `Alplus.Id` (prefixed UUIDv7, Crockford base32), `Alplus.Scope`, `Alplus.Repo` (`AshPostgres.Repo`).


`Alplus.Authz` survives only as a thin wrapper over the same Ash policies. Never define a second authorization matrix.

## 3a. MCP boundary

`Alplus.Mcp` exposes organization-qualified Streamable HTTP resources at
`POST /mcp/org/:org_public_token`. The legacy `POST /mcp` resource remains
available for project-pinned grants during the compatibility period.

Support both protocol generations. Use `initialize` for `2025-11-25`, and use
`server/discover` for `2026-07-28`.

Put every product pillar behind an independent adapter. Keep adapters independent.
Do not let one pillar call another through MCP.

Authenticate MCP requests through the OAuth authorization-server and resource-server
flow defined by MCP 2026-07-28. The authorization server discovers or registers the
client, authenticates the user, and binds consent to the organization named by the
exact resource URI. Organization grants cover every current and future project but
carry no implicit project. Each project-scoped execution supplies `project_ref`;
the gateway resolves it inside the grant organization and builds the existing
project-scoped actor. The resource server validates the access token's issuer,
audience/resource, expiry, grant, live membership, role, and scopes on every request.

The HTTP transport carries the issued access token in the standard
`Authorization: Bearer <access-token>` header. Bearer is the access-token transport,
not a manually created credential: users do not mint, copy, or paste MCP tokens.
`Alplus.Mcp.Authorization` owns the resource-server boundary and delegates the
OAuth protocol flow to the authorization components.

Persist only SHA-256 hashes and lookup prefixes for authorization codes, access
tokens, and refresh tokens; return each raw secret only at issuance. Grants are
revocable and organization-bound, with a legacy project-pinned mode. Refresh-token
rotation revokes replayed or superseded tokens. Scope, membership, role, and resolved
project checks remain enforced for every MCP call.

## 4. Tenancy and authorization

Ash policies are the primary authorization mechanism. Every resource denies by default. Every action carries an actor.

`%Scope{user_id, org_id, role, project_id?, environment?}` is the request context. Map it into the Ash actor and tenant on every call. Never hold tenant selection in implicit global state. An API key resolves to a synthetic scope limited to one project. Key scopes never reach org, billing, member, or api-key actions.

Put `org_id NOT NULL` on every tenant table. Keep `org_id` and the database constraints authoritative. Policies add enforcement; they never replace it. Repeat the tenant predicate on every query. Return 404 for a cross-tenant id, never 403.

Use Ash multitenancy only where it maps cleanly onto the existing `org_id` column. Keep project restrictions explicit in policies.

Roles: `owner` (exactly one, DB-enforced), `admin`, `member`. Invariants: atomic ownership transfer, last-owner protection, no self role-change, admins never touch billing or deletion. Express each invariant as a policy plus a database constraint.

Environment is a nullable free-text tag on monitors, issues, events, and API keys
(spec 006). Create no environments table. Derive environment from the authenticated
OAuth access-token scope at ingest, never from the client. Environment is not a
security boundary. Do not use RLS initially.

## 5. PostgreSQL

Primary keys: `prefix_` + UUIDv7 as 26-char lowercase Crockford base32 (`proj_01j2x3…`) via `Alplus.Id`. Exception: the AshAuthentication token resource keys on `jti`, which the library requires to be a plain string. `jti` is a JWT claim, not a domain id. API and heartbeat secrets (`alp_*` keys, `hb_*` tokens), OAuth authorization codes, access tokens, and refresh tokens are random secrets: store SHA-256 hash + 8-char prefix, show each raw value once.

The pre-rewrite live schema (`packages/db/src/schema/*.ts`) was the requirements list, not a template; it has since been removed with the rest of the legacy stack (archived at the git tag `legacy-master-archive`). The domain is re-modeled idiomatically in Ash, preserving constraints, identifiers, tenancy, retention, and product behavior.

Generate migrations with `mix ash.codegen`. Add hand-written migrations only for partitions and other features Ash cannot express.

Modeling rules:

1. Store per-type monitor config in 1:1 child tables (http, heartbeat, tcp, dns). Never store presentation defaults as data.
2. Partition `error_events` monthly. Drop partitions for retention.
3. Make `subscriptions` unique per `(org_id, stripe_environment)`. Derive `organizations.billing_status` and `subscriptions.status` CHECKs from one shared constant (8 Stripe statuses) with a drift test.
4. Add `octet_length` CHECK caps to every free-text/JSON column. Overflow Observe payloads > 256 KB to S3 behind `payload_s3_key`. Cap envelopes at 1 MB.
5. Use `text` + CHECK for enums. Add UNIQUE to 1:1 relations. Enforce `email = lower(btrim(email))`. Never index a secret column.

Migration rules: forward-only, expand/contract, `CREATE INDEX CONCURRENTLY` on live tables, separate migrator and runtime DB roles.

Control plane: users, sessions, organizations, memberships, invitations, projects, changelogs, changelog_entries, changelog_revisions, changelog_source_references, changelog_activity_events, api_keys, project_domains, monitors (+4 config children), goals, alert_rules, notification_channels, notification_deliveries, feature_flags(+overrides), stripe_customers, subscriptions, invoices, stripe_webhook_events, usage_periods, idempotency_keys, mcp_oauth_clients, mcp_oauth_grants, mcp_oauth_authorization_codes, mcp_oauth_access_tokens, mcp_oauth_refresh_tokens, mcp_idempotency_records, audit_logs, Oban tables.

Data plane: issues, error_events (partitioned), releases, release_artifacts, Observe session rollups (crash-free, aggregate-only) + a 24-hour session dedup guard, monitor_checks, incidents, monitor rollups (hourly/daily), Measure rollups (analytics_hours, analytics_days, analytics_dimensions incl. referrer/country/browser, goal_conversions, custom_events).

## 6. OTP

OTP owns runtime concerns. Ash owns durable state. Never replace a runtime process with an Ash abstraction. Persist through Ash actions where practical; use a direct transaction when correctness requires it.

Create a process only for concurrency, serialized access, isolation, or live state. Supervise everything long-lived. Keep business state in Postgres, never in process memory.

- **Monitor scheduler**: one GenServer per active monitor under a DynamicSupervisor, addressed via Registry. State: timer, pass/fail counts, config_version. Rehydrate from Postgres on boot. Schedule `next = interval ± 5% jitter`; switch to `retry_interval` while failing. Run each check in a supervised Task with a hard timeout. Commit check + incident transition in one transaction; enqueue notifications in the same transaction. Reconcile config by version bump. ~150k processes at target scale is normal BEAM load.
- **Batchers**: one supervised process per sink (AE writer, S3 archiver). Flush on size or interval. Buffer loss on crash is acceptable (non-authoritative data).
- **Rate limits**: 60/300/600 req/min by plan. Evaluate a maintained Hex or Ash-compatible limiter before writing ETS sliding windows. Monthly quotas are authoritative in `usage_periods` with an ETS cache in front.
- **Realtime**: Phoenix.PubSub → LiveView. Subscribe only when `connected?/1`.
- **Measure visit state**: ETS, key `{project_id, visitor_hash}`, 30-minute TTL.

## 7. Oban

| Queue | Work |
|---|---|
| `notify` | alert fan-out and delivery; dedup key per `(incident/issue, repeat_index, channel)` in `notification_deliveries` |
| `billing` | Stripe webhook processing, reconciliation, usage rollover |
| `telemetry` | rollup finalization, retention pruning, S3 archival, payload overflow |
| `mailer` | transactional email (§10a) |
| `default` | exports, cleanup |

Cron: hourly rollup finalization; daily 00:10 UTC maintenance (prune retention, SSL/domain expiry scan at 14/7/1 days, ignored-issue expiry, invitation pruning, key-expiry reminders); daily Stripe reconciliation.

Job rules:

0. Use `AshOban` when the job originates from a resource or action (delayed actions, resource-driven notifications, archival cleanup, asynchronous resource processing). Use plain Oban where plain Oban is simpler. Run one job system, never two. Use Oban for any work that must survive a restart.
1. Make every job idempotent — safe at `max_attempts`.
2. Use JSON args with string keys. Pass ids, never structs or payloads.
3. Use idempotency keys or the deliveries dedup table for external effects.
4. Return `{:cancel, reason}` for permanent failures.
5. Set an explicit timeout on every outbound HTTP call.

## 8. Ingestion flows

Shared rules: validate strictly at the edge (400 on malformed). Rate-limit every public write path (429 + `Retry-After`). Quota ladder: 80% warn, 100% notice + continue, 130% drop items silently (still 202, `dropped_reason: "quota"`). A 202 means accepted, not stored — tests assert rows.

Ingest is a hot path. Do not create one Ash action per raw hit or per raw event. Use optimized PostgreSQL writes for high-volume paths, and Ash actions for configuration, issues, incidents, and durable rollups.

Model the issue lifecycle and the incident lifecycle with `AshStateMachine`. Keep the monitor scheduler and its timers outside the state machine. Do not use a state machine for boolean state.

**Observe — `POST /e/errors`**
1. Authenticate the bearer key (`ingest` scope). Validate the envelope (1 MB → 413).
2. Respond 202 with accepted/dropped counts.
3. Process: dedup on the client `err_` UUIDv7 id → fingerprint → issue upsert + event insert in one transaction. Send slow work (S3 overflow > 256 KB, alert fan-out) to Oban.
4. Fingerprint (port verbatim): custom override → exception → message; top 8 in-app frames; no line/col; append `project_id` + `environment`; group per environment. Lifecycle: `open | resolved | ignored` (90 days fixed); regression on post-resolve events.
5. Evaluate alert rules after commit: new-issue, regression, frequency (default 25 events/5 min), quota; 15-min cooldown per (rule, issue). Stream count points to the AE batcher.

**Observe — `POST /e/sessions` (crash-free sessions)**
1. Authenticate the bearer key (`ingest` scope). Validate strictly (400 on malformed), rate-limit, 202. Additive path — the `/e/errors` envelope is unchanged.
2. A session is request-scoped, reported by the SDK Plug/Rack middleware: `healthy` (no error), `errored` (a handled error), `crashed` (an unhandled/fatal error only).
3. Dedup on the client `ses_` id (24-hour guard). Roll up aggregate counts (sessions/errored/crashed) per release + environment. Never store a raw per-session row; the session id is used only for dedup, then discarded (privacy parity with Measure).
4. Crash-free sessions % = `(sessions − crashed) / sessions`, session-weighted, gated behind a minimum-session count — show "not enough data" below it, never a misleading 100%. Surfaced on the Observe releases view (§9). Users-weighted crash-free and browser/JS sessions are deferred.

**Measure — `POST /m`, `GET /m.js`**

`POST /m` accepts pageviews and registered custom events. The server validates
the event name before quota accounting. It discards event properties and stores
only aggregate event counts.
1. Authenticate by `Origin` against `project_domains` (exact or `*.` wildcard; empty list rejects all; absent/`null` Origin rejects).
2. Respond 204 always for accept and reject (anti-enumeration); 400 malformed; 429 limited. Never send `Access-Control-Allow-Origin`.
3. Compute `visitor_hash = HMAC-SHA256(daily_salt, project_id || source_id || ip || user_agent)`. Claim one day-scoped seen row per hash and increment visitors only on the first claim. Keep salts and seen rows for today and yesterday only; deleting a salt cascades to that day's seen rows. Never persist the IP or user-agent. Keep the separate 30-minute visit, bounce, landing-page, and duration state in ETS.
4. Update Postgres rollups: hourly rows; dimensions capped at 1,000 values/dimension/day → `(other)`; goals convert once per visit; stream points to the AE batcher.
5. Serve `m.js` < 2.5 KB gzipped, edge-cached (`max-age=3600, stale-while-revalidate=86400`), DNT honored client-side.

**Monitor — `GET|POST /h/:token` + active checks**
1. The token is the auth. Recognized → 202 (even paused); unrecognized → 404. `?state=start|finish|fail`; omitted = finish.
2. Explicit `state=fail` bypasses the failure threshold and opens an incident immediately. Hung detection: `now - pending_start > 2 × expected_duration`.
3. Run active checks (http, keyword, tcp, dns) from the scheduler (§6).
4. Incident machine: binary up/down; failure threshold default 2 (range 1–5); recovery fixed at 2 passes; acknowledge stops reminders, never closes; repeat reminders counted in checks (`resend_after_failed_checks` 0–100, default 0).
5. Compute uptime time-weighted from incidents, never from check-row counts. Exclude paused time from both sides. Stream latency/status points to the AE batcher.

## 9. Web surfaces

**Marketing** (`postdeploy.dev`): server-rendered controllers + templates, except two stated LiveView routes; every other marketing page stays a controller page. The homepage (`AlplusWeb.HomeLive`) is a LiveView so the four switches on the live project overview change the frame in place instead of reloading the document. The website health check (`AlplusWeb.WebsiteHealthCheckLive`) is a LiveView because the check is one live HTTP request of up to ten seconds: it runs in `start_async/3`, so the visitor's address, the pending state and the verdict stay in one document, and the dead render is the complete, indexable form. Both need the LiveView bundle, and `AlplusWeb.MarketingPayloadTest` asserts that every other marketing path still ships none. The health check's session writes stay in `AlplusWeb.WebsiteHealthCheckController` (the monitor draft and the funnel journey id), because a LiveView owns no session. Pages: home, pricing (numbers from the plan registry), pillar pages, docs/guides, comparisons, legal, the free health check tool. Include meta/OG, JSON-LD (`Organization`, `SoftwareApplication`, `Article`, `FAQPage`), canonical URLs, `sitemap.xml`, `robots.txt`, `llms.txt` (allow AI crawlers). Disallow `/dashboard/` in `robots.txt` and exclude it from the sitemap. Store content as structured data in `Alplus.Content` so programmatic SEO pages can generate later. Do not build the generator now.

**Console** (`postdeploy.dev/dashboard/`): Phoenix LiveView with AshPhoenix. One host serves marketing and console. Mount every authenticated route under `/dashboard/` in a live session. Never add a `console.` subdomain. Use `AshPhoenix.Form` for every create and update form. Load data through Ash actions and code interfaces. Write no hand-rolled CRUD plumbing. No SPA, no client API layer. JS hooks only for browser-only needs. Nav (shipped, two blocks): a per-project block listing every project in the org, each expanding to Monitor, Measure, Observe and one Public destination (collapsing behind a per-project toggle past five projects); then an organization block with Projects, Team, Billing, and Settings. The Public destination has durable Status, Changelog, and Settings sections. Status owns Services, Incidents, Announcements, Maintenance, and History; Changelog owns Entries, Activity, and entry review; Settings owns the shared title, logo, slug, and publication state. The org switcher sits above both, and the account footer links to the account root at `/dashboard`. There is no API Keys screen. Monitor, Measure, Observe, and Public are reachable only under an explicit project path segment, never at org scope. Environment is a read-only filter derived from the tags present (§4). Onboarding is a resumable checklist derived from real rows (no completion flag), and crash-free sessions surface on the Observe releases view. UX rules: no full-page spinners (skeletons + control-scoped feedback); scoped error boundaries with region retry; typed confirmation for destructive actions; cursor pagination; secrets shown once. Layout rules live in `docs/DESIGN-SYSTEM.md`; the binding one is that a bordered container never contains another bordered container.

**Public Measure dashboard** (`/share/:token`): a Phoenix controller renders the
page without a session or LiveView. The database stores only the SHA-256 token
hash and a lookup prefix. A resolved token becomes a source-scoped actor. Ash
policies re-check the share, project, organization, active Source, and plan.
The controller fetches only enabled panels. It applies a per-share request
limit and caches each enabled panel for 30 seconds.

**Public Status and Changelog**: resolve the project-owned Public identity at
`/status/:public_slug`, preserving legacy status aliases. The authenticated
Status workspace includes Services, Incidents, Announcements, Maintenance,
History, and Operational settings; identity settings remain on Public Settings.
Serve the Changelog
at `/status/:public_slug/changelog`, RSS at
`/status/:public_slug/changelog.rss`, and JSON at
`/status/:public_slug/changelog.json`. Serve entries at
`/status/:public_slug/changelog/:entry_slug`. Return 404 for archived entries.
The old `/changelog/:slug` and `/changelog/:slug/entries/:entry_slug` routes
remain permanent compatibility redirects.
Return 410 for permanently deleted entries with a matching tombstone.
Render Markdown through MDEx.

**Public API** (`/v1/*`): bearer `alp_*` keys. Error envelope `{error: {type, code, message, param?, request_id}}` with stable codes. Cursor pagination `{data, has_more, next_cursor}`, limit 1–100 default 25. RFC 3339 UTC timestamps. `X-Request-Id` on every response. `Idempotency-Key` on POST (24 h window). No CORS. Additive changes only; breaking changes require `/v2`.

## 10. Authentication

- Use `AshAuthentication` + `AshAuthenticationPhoenix` with the password strategy and argon2. Require email verification before a useful session.
- Sessions: 30-day absolute, 7-day inactivity. Cookie `__Host-` prefixed, HttpOnly, Secure, SameSite=Lax. Use Phoenix CSRF protection.
- Build these gates around the extension: signup gate (`SIGNUPS_ENABLED`), login lockout (10 attempts/15 min), server-side password strength + HIBP check, Turnstile on signup, password sign-in, password-reset requests, and the public website health check.
  Invitation links use the protected signup/sign-in routes. Ingest and authenticated actions do not require browser challenges.
- Warning: never accept weaker security because an extension lacks a feature. Implement the missing PostDeploy rule as a policy, a change, or a plug.
- Defer GitHub OAuth, Google OAuth, passkeys, and TOTP to post-MVP. Keep the AshAuthentication strategy list open for them.

## 10a. Email

Cloudflare sends all outbound email. AWS SES is out of scope.

- Send through `Swoosh` behind one PostDeploy adapter that calls the Cloudflare email API with `req`. Keep the adapter thin: authenticate, post, map the response, return `{:ok, id}` or an error.
- Switch adapters by config only. Dev and test use the Swoosh mailbox preview and the test adapter. No AWS credentials for email in any environment.
- Send every email from the `mailer` Oban queue. Never send inside a request. Retry on 5xx and 429. Return `{:cancel, reason}` on a rejected address or a permanent 4xx.
- Warning: an email failure must never block signup, an incident transition, or a webhook. Persist the domain effect first, then enqueue the mail.
- Transactional mail only: verification, password reset, invitations, alerts, billing notices, key-expiry reminders. No marketing mail from the app.
- Configure SPF, DKIM, and DMARC on the sending domain in Cloudflare DNS. Keep bounce and complaint handling in scope before production.
- Inbound email is not a product feature. Use Cloudflare Email Routing for founder mailboxes only. The app parses no inbound mail.

## 11. Billing

- Package: one, `postdeploy` ($29 monthly). No annual price. Flat, USD, per organization. `Alplus.Billing.Package` is the single source of truth for name, price, limits, included features, and exclusions. No plan id is stored: `organizations.billing_status` mirrors Stripe, and `trialing` means the trial.
- Every new organization starts on a 14-day no-card trial with the package's limits. Trial is an PostDeploy state, not a Stripe object: it carries no Stripe customer or subscription. The deadline lives in `organizations.trial_ends_at`. At day 15 the organization becomes read-only (ingest refuses with 402), and a daily purge worker removes its project data 30 days after inactivity. The paid plan has one monthly Stripe price (`STRIPE_PRICE_POSTDEPLOY_MONTHLY`, lookup key `postdeploy_monthly_usd`); the webhook refuses any other price. Access resolution (`:trial`, `:subscribed`, or inactive) lives in one decision table: `Alplus.Billing.Access.check/1`.
- Use Stripe Checkout + Customer Portal + Stripe Tax only. No custom card UI. One customer, max one subscription per org per Stripe environment. Trial organizations have no Stripe objects. Checkout runs only for an org with no active or past-due subscription, because Checkout can only create a subscription. A paying org has nothing to change; it manages or cancels its subscription in the Customer Portal.
- Webhook `POST /webhooks/stripe`: verify signature + livemode; process only 7 types (`checkout.session.completed`, `customer.subscription.*` ×3, `invoice.paid`, `invoice.payment_failed`, `invoice.finalized`); 200-ack the rest. Fast-ack, then process in Oban with `stripe_webhook_events` idempotency. Reconcile daily.
- Before enqueueing, the controller normalizes each supported event to an allowlist of billing identifiers, package price, period, status, amount, creation, and livemode fields. It never stores the complete Stripe payload in Oban args.
- Enforce limits at create time (projects, members, monitors, cron jobs, the 60 s interval floor). Meter monthly quotas in `usage_periods` with the 80/100/130 ladder (the 130% ceiling is `Package.event_ceiling/1`).
- Stripe renders each event in the endpoint's pinned API version, so a payload field can move without any change here. It has: on `2026-06-24.dahlia` the subscription billing period lives on `items.data[].current_period_{start,end}`, not on the Subscription object. Treat the event shape as versioned input, not a constant. Operational contract, secret rotation, and end-to-end verification: `docs/runbooks/stripe-billing.md`.

## 12. Failure behavior

- Postgres down → app down. No degraded write mode, no silent fallback.
- AE down → affected panels show "unavailable"; ingest, incidents, billing unaffected; batcher drops after bounded retry.
- S3 down → overflow/archival jobs retry in Oban; the trimmed event row is already stored.
- Cloudflare email down → `mailer` jobs retry; signup, incidents, and billing continue; surface the failure in logs and metrics.
- Node restart → DynamicSupervisor rehydrates schedulers from Postgres; at most one missed interval.
- Redelivery anywhere → harmless: dedup on event ids, ping ids, delivery keys.

## 13. Retention

| Data | Retention | Enforced by |
|---|---|---|
| Observe raw events | 30 d | daily cleanup job |
| Monitor raw checks | 30 d | daily prune |
| Monitor daily rollups | 24 months | daily prune |
| Measure rollups | 730 d | daily prune |
| Incidents | forever | — |
| Audit logs | 90 d | daily prune |
| Idempotency keys | 24 h | daily prune |
| Terminal invitations, Stripe webhook events | 90 d | daily prune |
| Terminal Oban jobs | 7 d | `Oban.Plugins.Pruner` |
| Archived projects | 14-d grace, then hard cascade | `AshArchival` + daily prune job |
| Release artifacts | 60 d | daily cleanup job |
The S3 lifecycle rule expires objects after 120 days as a safety ceiling. The daily cleanup job enforces each package window and queues deletion before deleting its database reference.

Any view past its raw window reads a rollup, never raw replay.

Use `AshArchival` for soft deletion, starting with Projects. Keep permanent deletion in a durable Oban job. Write no second soft-delete mechanism.

## 14. Security

1. Grant ingest keys only the `ingest` scope. API-key scopes: `ingest`, `project:read`, `{observe,measure,monitor}:{read,write}`. Missing scope → 403 on `/v1`.
2. Authenticate MCP requests with OAuth access tokens. Each token is issued for a
   user-approved grant, bound to one exact organization-qualified or legacy resource,
   and limited to explicit scopes. Re-check grant validity, membership, role,
   resource audience, expiry, scopes, and request-local project resolution on every
   call. Cross-organization project references return `not_found`.
3. Hash API keys, heartbeat secrets, authorization codes, access tokens, and refresh
   tokens at rest. Encrypt third-party credentials (Slack, Telegram, webhook secrets,
   other integrations) with `AshCloak` attributes. Keep versioned key rotation. Never
   implement AES by hand. Show raw secrets only at issuance; assert absence in responses
   by test.
4. Never log secrets. Redact path tokens (`/h/<token>`) and any `key|secret|token|password` field.
5. Tarpit invalid ingest credentials (200–500 ms delay). Never put a CAPTCHA on machine routes.
6. Audit every allowed sensitive mutation and every denied sensitive action. Record actor, organization, project where applicable, and request metadata. Persist no raw IP except in the actor's own audit rows.
7. Keep `Alplus.Audit` explicit. Evaluate `AshPaperTrail` for resource change history only. Adopt it only if it records the fields in rule 5, including denials. It never replaces the security audit log.

## 15. Observability of PostDeploy

- Emit structured JSON logs (stable event names, request id) to stdout. Read them with `deploy/ovh/compose.sh logs --tail 100 app`.
- Export `:telemetry` metrics (Phoenix, Ecto, Oban, VM) via `telemetry_metrics`. Alarm on p95 latency, Oban depth/failures, DB pool saturation.
- Serve `/health` (app + DB) for the Compose health check and public readiness checks.

## 16. Local development and production

Local: `docker compose up postgres` + `mix setup && mix phx.server` gives the full product. No AWS credentials needed. S3 → MinIO or local-dir adapter. AE → dev adapter storing points in Postgres behind the same read API. One code path; adapters switch by config.

There is no staging. Progression: local → local release validation (release container + compose) → production. `docs/PRODUCTION-CUTOVER.md` has the runnable local release-validation recipe and the deploy traps; read them before a first deploy.

Production target: one amd64 Phoenix release on the existing Ubuntu OVH VPS, managed with `deploy/ovh/compose.yml`.
Keep KeySend and CrabGate's shared Kamal Proxy unchanged.
Use a dedicated PostgreSQL 18 volume, separate migrator/runtime roles, and the private R2 payload bucket.
Keep Cloudflare Tunnel as the only public path. Preserve existing DNS and HTTPS routing when moving its connector.
Keep secrets in `/etc/postdeploy`, outside the source checkout.
Retain the AWS stack as the migration source and rollback resource until verification completes.
Read `deploy/ovh/README.md` for capacity limits, backups, commands, cutover, and rollback.
Single node, no clustering, no multi-region. Certify capacity with measurements before increasing limits.

The Dockerfile's standalone boot command migrates and seeds before starting the server.
OVH Compose runs these tasks in a gated one-shot migrator service with its own database role.
A failed migration prevents app startup. A failed seed logs and preserves app availability.
Grant the runtime role table and sequence access after migrations.
Gate cutover on `deploy/ovh/verify-candidate.py`, which compares every live indexed path against the private candidate.
Check public routes after starting the tunnel. A green health endpoint alone does not prove content publication.

Next action: open `docs/BUILD.md` §6 and start the lowest incomplete phase.
