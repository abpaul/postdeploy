# PostDeploy Build Guide

Goal: tell implementation agents what to build next, and in what order.
Read `docs/ARCHITECTURE.md` first. It defines where logic and data belong and wins every conflict.
Complete each phase's "Done when" before starting the next phase.

## 1. Product

PostDeploy is the toolkit for operating software after it reaches production.

Its current tools cover uptime, cron monitoring, errors, cookieless analytics, and agent-first changelogs. Its product boundary also includes logs, incidents, status pages, and future operational tools.

Build elsewhere. Deploy anywhere. Run it with PostDeploy.

- **Observe** — error tracking: grouping, triage, releases, alerts. Replaces Sentry.
- **Measure** — cookieless web analytics: pageviews, visitors, goals. No raw hits, no identifiers. Replaces Fathom/Plausible.
- **Monitor** — uptime + cron: http/keyword/tcp/dns checks, heartbeats, incidents, notifications. Replaces UptimeRobot. Most complete in the old code; port it most faithfully.
- **Public** — one project-owned page with Status, Changelog, and shared Settings. Status exposes customer-facing services, incidents, announcements, maintenance, and history; Changelog provides agent-first release updates with review and publication.
- **Changelog**: agent-first release updates with Markdown drafts, review, publication, archive, restore, and permanent deletion.

Core flow: sign up → verify → create org → create project → integrate (snippet / SDK key / monitor) → see data → invite team → subscribe. Target: first value under 5 minutes.

Package: one, `postdeploy`, at $29 a month, billed monthly, after a 14-day
trial with no card. Per organization, flat, USD. There is no annual price and
no plan ladder (founder decision, 2026-09-16). `Alplus.Billing.Package`
(`lib/alplus/billing/package.ex`) is the single source of truth for the
name, price, limits, included features, and exclusions. An organization is
either in its trial or subscribed; no plan id is stored. The trial grants
the package's limits; day 15 makes the organization read-only until it
subscribes, and a daily purge removes its project data 30 days later. Limits:

| Limit | postdeploy (and trial) |
|---|---|
| projects / members | 10 / 5 |
| monitors / cron jobs | 100 / 200 |
| min check interval | 60 s |
| analytics / error events per month | 500k / 50k |
| raw retention / Measure rollups | 30 d / 730 d |
| API rate limit / audit retention | 300/min / 90 d |

Observe release artifacts are retained for 60 days.

## 2. Rules

1. Build locally first. Touch AWS only in the last phase. There is no staging.
2. Keep one application. Never add a second service or internal API.
3. Model the domain in Ash. Write no Phoenix context that duplicates an Ash resource.
4. Prefer: mature Ash extension > mature Hex library > small conventional implementation > custom abstraction.
5. Apply the tenancy rules in ARCHITECTURE.md §4 to every data path.
6. Ship tests in the same change. Assert effects (rows), not acknowledgements. Let failures surface — no silent fallbacks.

Warning: an Ash extension that leaves the old implementation in place doubles the code. Delete the replaced module in the same change.

Recover behavior from the old TypeScript; reimplement idiomatically. Never port its structure.

## 3. Dependencies

The founder ratifies each row at first use. Propose alternatives with justification. Do not upgrade unrelated dependencies in a feature.

| Need | Library |
|---|---|
| Web / runtime | `phoenix`, `phoenix_live_view` |
| Domain / persistence | `ash`, `ash_postgres`, `ash_phoenix`, `ecto_sql`, `postgrex` |
| Auth | `ash_authentication`, `ash_authentication_phoenix`, `argon2_elixir` |
| Jobs | `oban`, `ash_oban` |
| Archival / lifecycle / secrets | `ash_archival`, `ash_state_machine`, `ash_cloak` |
| HTTP / JSON | `req`, `jason` |
| Agent protocol | `ex_mcp` Streamable HTTP |
| Changelog | `mdex` sanitized rendering, `yaml_elixir` front matter |
| Email | `swoosh` + a thin Cloudflare Email adapter over `req` (dev: mailbox preview) |
| Stripe / S3 | `stripity_stripe`, `ex_aws` + `ex_aws_s3` |
| Metrics | `telemetry_metrics` |
| Testing | `mox`, `bypass` |

Evaluate before first use, then decide in one line: `ash_paper_trail` for resource change history (ARCHITECTURE.md §14 rule 6), and an Ash-compatible rate limiter before writing ETS logic.

Add a dependency only when it removes meaningful custom code. Add nothing for behavior that Elixir, OTP, Phoenix, Ash, or Ecto already handles clearly.

Exception: write the cursor-pagination module internally (~100 lines). The cursor shape is a wire contract.

## 4. Tests

The suite runs in seconds on every change. No browser E2E (no Playwright/Cypress/Wallaby). A few LiveView/controller tests through the real plug pipeline are enough at the framework level.

Test against real Postgres via the Ecto sandbox. Build every fixture through an Ash action, never through raw inserts, so policies and validations stay in the path. Mock only externals (Stripe, chat apps, webhooks, S3, AE Worker). Never mock our own domains. Derive fixture data from the source of truth (plan registry, action list). Use fixed clocks; no sleeps.

Cover, in this order: resource actions, policies, validations, tenancy, state transitions, jobs, domain rules. Test every policy failure explicitly. Test cross-tenant access explicitly.

Release-blocking, security:

1. Authorization matrix — table-driven over every (action, role) cell against the real policies, exhaustiveness-checked.
2. Tenant isolation — two real accounts through the real pipeline; cross-org id → 404. Verify the test fails with the scope predicate removed.
3. Secret non-exposure — secrets absent from every response after creation.
4. Auth edges — unverified sessions useless; lockout counting correct.

Release-blocking, correctness:

1. Job idempotency — every worker run twice with the same args changes nothing extra.
2. Migration chain — replays from zero in CI.
3. Async lifecycle in memory — ping → check row → incident → notification job → adapter mock.
4. Quota boundaries — behavior at 100% and 130%.

## 5. Migration map — where old truth lives

| Recover | From |
|---|---|
| Plan limits | `packages/core/src/billing/plans.ts` (canonical) |
| Authz matrix (19 actions) → Ash policies | `packages/core/src/authz/can.ts` |
| Schema requirements (constraints, not structure) | `packages/db/src/schema/*.ts` |
| Id prefixes | `packages/core/src/id/id.ts` |
| Fingerprinting + Measure rules | `workers/app/src/domains/ingest` |
| Incident machine | `workers/app/src/durable-objects/incident-state.ts` |
| API shapes | `packages/schemas` |
| SDK wire contract | `packages/sdk` (published npm package) |
| UI flows / marketing / tokens | `apps/console/src`, `workers/www`, `packages/tokens` |

Keep these external contracts working unchanged: `POST /e/errors` envelope, `POST /m` + `m.js`, `GET|POST /h/:token`, `alp_*` key format, `/v1/*` envelope and pagination. Everything internal may change.

Do not port the old data layer mechanically. Treat the old schema and tests as product requirements. Re-model each domain in Ash. Preserve constraints, billing rules, tenancy, authorization, retention, identifiers, security gates, and product behavior. Delete each old repository abstraction once Ash replaces it.

## 6. Phases

### Phase 1 — Phoenix and Ash foundation

1. Generate the Phoenix app at the repository root with `igniter` (keep Swoosh; no gettext); point it at compose Postgres; add CI (compile warnings-as-errors, format, credo, test).
2. Install `ash`, `ash_postgres`, `ash_phoenix` through `mix igniter.install`; verify `mix ash.codegen` round-trips.
3. Build `Alplus.Id` as an Ash type with the ported prefix registry + property tests against old-format samples.
4. Define `Alplus.Scope` and its mapping to the Ash actor and tenant.
5. Add test infrastructure: sandbox, Ash-action fixtures, actor/scope helpers.

Done when: `mix setup` boots the app; a throwaway resource persists through AshPostgres; the suite runs in seconds.

### Phase 2 — Ash vertical slice

Build one bounded slice before committing to the full rewrite:

```text
User → Organization → Membership → Project
```

1. Add `ash_authentication` + `ash_authentication_phoenix`: email/password, verification, reset, session policy, signup gate, login lockout, HIBP, Turnstile. Send mail through the Swoosh mailbox preview locally; wire the Cloudflare adapter at Phase 11 (ARCHITECTURE.md §10a).
2. Model `Accounts`, `Orgs`, `Projects` as Ash resources with AshPostgres persistence.
3. Write the policies: org isolation, project isolation, owner-only actions, admin restrictions, cross-tenant 404.
4. Add `ash_archival` on Projects with the 14-day grace period.
5. Ship one LiveView (project list + create) through `AshPhoenix.Form`, plus unit tests for actions, policies, and tenancy.

Done when: register → verify → create org → create project → archive project works in the browser; policy-failure and cross-tenant tests pass; the suite runs in seconds.

### Phase 3 — Domain framework decision: RATIFIED 2026-08-10

Ash is the domain framework for PostDeploy. The founder ratified it after the Phase 2
slice, without a plain-Ecto comparison build. Do not re-open this. Do not
propose Phoenix contexts as an alternative.

Done: no work remains in this phase.

### Phase 4 — Marketing

1. Port `workers/www` content into `Alplus.Content` Ash resources (Page, Guide, Integration, Comparison, SeoTemplate) + server-rendered pages (home, pricing from the registry, pillar pages, legal).
2. Add SEO plumbing: meta/OG helpers, JSON-LD, canonicals, `sitemap.xml`, `robots.txt`, `llms.txt`.
3. Keep the content model ready for programmatic SEO. Do not build the generator yet.

Done when: `postdeploy.dev` pages render server-side with correct metadata; Lighthouse SEO parity or better; pricing numbers come from the registry.

### Phase 5 — Product shell

1. Build the LiveView shell under `/dashboard/` (nav per ARCHITECTURE.md §9; project/environment as query params). Each project has one Public destination with durable `/public/status`, `/public/changelog`, and `/public/settings` routes.
2. Add empty states per pillar (one line + one sentence + one action).
3. Build Team management and API key management (create/rotate-with-grace/revoke) as Ash actions under policy.
4. Add audit-log writes + settings view.
5. Port the UI kit from `packages/tokens` values (skeletons, scoped error boundaries, no full-page spinners).

Done when: each role sees role-correct UI across all pillar empty states; every mutation writes an audit row; secret-non-exposure tests pass.

### Phase 6 — Monitor

1. Add resources: monitors + 4 config children, checks, incidents, heartbeat tokens.
2. Build the scheduler and check executors in native OTP (ARCHITECTURE.md §6) with hard timeouts. Persist through Ash actions.
3. Port the incident machine behavior with `ash_state_machine` (ARCHITECTURE.md §8) + heartbeat ingest `/h/:token`.
4. Add SSL/domain expiry scan (14/7/1), time-weighted uptime, rollups, retention, plan enforcement.
5. Build notifications (channels CRUD with `ash_cloak` attributes; email/Slack/Discord; webhook/Telegram plan-gated) and Monitor LiveViews with PubSub updates.

Done when: the async lifecycle test passes; a paused monitor's ping returns 202 and writes no check row; interval floors and counts enforce per plan; the scheduler survives kill + restart via Postgres rehydration.

### Phase 7 — Measure

1. Build `POST /m` with the origin allowlist and 204-always behavior (ARCHITECTURE.md §8). Keep the hot path on optimized PostgreSQL writes, not per-hit Ash actions.
2. Implement visitor hash + derived daily salt + ETS visit state (30-min TTL, one conversion per visit).
3. Model analytics configuration, goals, custom-event definitions, and durable rollups as Ash resources. Write rollups (dimension cap 1,000/day → `(other)`; goals ≤ 50/project; event names `[a-z0-9_-]{1,64}`, props discarded).
4. Ship `m.js` (< 2.5 KB gzip, SPA navigation, bfcache, pre-load queue) and the AE batcher + dev adapter + the AE Worker.
5. Build dashboards (AE for recent windows, Postgres rollups beyond) + quota metering + retention.

Done when: a local page with the snippet produces dashboard data; tests prove no raw hit/IP/UA is persisted; rejection is wire-identical to acceptance; 130% quota drops with a visible counter.

### Phase 8 — Observe

1. Build `POST /e/errors` (envelope validation, 1 MB/413, `ingest` scope, tarpit).
2. Port the fingerprint pipeline verbatim as plain Elixir, with golden-master fixtures from the old implementation.
3. Add issue upsert + partitioned events + client-id dedup + 256 KB S3 overflow. Model issues, releases, and artifacts as Ash resources; write the partitioned event path directly.
4. Implement the lifecycle with `ash_state_machine` (open/resolved/ignored-90d, regression, `resolved_in_release`), releases + artifacts (display-time symbolication), alert rules with cooldowns.
5. Build Observe LiveViews, AE trend points, quota + retention.

Done when: the unmodified `@alplus/sdk` 0.3.0 captures an error end-to-end locally; same stack twice → one issue, two events; regression reopens; quotas and retention follow the plan.

### Phase 9 — Billing

1. Port the plan registry with a drift test.
2. Integrate Checkout + Portal + Tax; build the webhook endpoint per ARCHITECTURE.md §11.
3. Add the subscription mirror, shared-constant status CHECKs, daily reconciliation.
4. Build billing LiveViews; wire enforcement across all pillars; add usage-period rollover.

Done when: test-mode monthly Checkout moves a trial to the paid plan via webhook; replayed webhooks are no-ops; every registry limit has an enforcing test.

### Phase 10 — Hardening

1. Complete every §4 test category.
2. Run a security + tenancy review: audit every policy, list every direct Ecto escape hatch and justify it, add adversarial two-tenant tests per pillar.
3. Load-check locally (~1k monitors: scheduler drift, ingest p95) against the 50k-org envelope.
4. Run production-like locally: release container + compose Postgres + MinIO, env-var config, migrations as release task, fail fast on missing env.

Done when: the release container boots the full product locally with documented env vars only; the §7 checklist passes from a fresh clone.

### Phase 11 — Production

1. Provision AWS with OpenTofu (`deploy/tofu`): EC2 ARM64 host, RDS, S3 + lifecycle, ECR, IAM. Deploy with Kamal (`config/deploy.yml`); secrets via `.kamal/secrets`.
2. Cut Cloudflare over: DNS to ALB, WAF/rate rules, cache rules for `m.js`/static; deploy the AE Worker; enable Cloudflare email sending with SPF, DKIM, and DMARC records (ARCHITECTURE.md §10a).
3. Smoke-verify by effect: row written, incident opened, email delivered; verify rollback via previous image.
4. Hand the founder a decommission plan for the old stack. Do not delete old production from this repo.

Done when: postdeploy.dev serves from Phoenix in production and a Stripe test-mode transaction completes against production infra.

## 7. Done when (whole rewrite)

From a fresh clone: install deps → compose Postgres → `mix ash.setup` (with seeds) → `mix phx.server` → browse marketing → authenticate → create org/project → exercise all three pillars → run the full suite green in seconds. Production runs the same code with config-switched adapters. Every §5 external contract still works. Every registry number is enforced and tested.

## 8. Non-goals

Rewrite excludes: microservices, Kubernetes, D1, Neon, Hyperdrive, Cloudflare Queues, Worker backends (except the AE adapter), a separate SPA, staging, browser E2E, multi-region, BEAM clustering, Kafka/OpenSearch/Timestream, custom queues, speculative scale work.

Product excludes (ratified): SSO/SAML, multi-org accounts, custom roles, APM/tracing, session replay/heatmaps, dashboard customization, seat billing, GraphQL/streaming, mobile apps, localization, white-label, compliance certs. Funnels shipped with product analytics (ADR 0007); identity merging, feature flags, an experiment engine, autocapture and attribution stay excluded.

Roadmap after the rewrite (not scope creep): status badges, outbound webhooks (contract already specified), OAuth/passkeys/TOTP, the Rails gem (`alplus-ruby`/`alplus-rails`).

## 9. Decisions (ratified 2026-08-10; do not re-open)

1. Every organization starts a 14-day no-card trial with the paid plan's entitlements. Store the deadline in `trial_ends_at`; do not add a `trial_used` field. The one paid plan has one monthly price (superseded 2026-09-16: monthly and annual prices for three plans).
2. Measure rollup retention follows the registry number: 730 days.
3. ICMP checks are excluded.
4. The console lives at `postdeploy.dev/dashboard/`. One host serves marketing and console. Do not use a `console.` subdomain.
5. Public page consolidation (ratified 2026-08-25): each project owns one `public_pages` identity and one Status workspace. Status, Changelog, and Settings are sections of the project Public destination. The shared identity owns title, logo, slug, and publication. Legacy public aliases remain readable; obsolete authenticated management routes redirect to the unified workspace. Status-page count billing is removed.

Raise a new question here only when the answer changes what an agent builds.

Next action: finish Phase 11 step 2 on `postdeploy.dev`.

The cutover completed on 2026-08-20. Deploy current `master`, then run
`scripts/verify-cutover.sh` and `scripts/acceptance-smoke.sh
https://postdeploy.dev`. Read `docs/PRODUCTION-CUTOVER.md` for the deploy
checks and rollback procedure.

Still undeployed after that: Cloudflare WAF/rate rules, `m.js` cache rules,
and the AE Worker (`config/runtime.exs` pins `analytics_engine_adapter` to
`Alplus.Measure.AnalyticsEngine.UnavailableAdapter` in production). Cloudflare
email is live.
