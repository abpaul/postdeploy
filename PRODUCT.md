# Product

<!-- impeccable:product-schema 1 -->

Durable product truth for PostDeploy. This file records users, jobs, and constraints
only. It carries no visual decisions and no numbers that live elsewhere.

Authoritative sources this file points at — read values there, never copy them:

- **Positioning, voice, competitors, banned words:** `.agents/product-marketing.md`
- **Package, price, entitlement limits:** `lib/alplus/billing/package.ex`
- **Public claims contract:** `lib/alplus_web/marketing/product_facts.ex`
- **Public URL inventory:** `docs/SITE-ARCHITECTURE.md`
- **Domain terms:** `CONTEXT.md`
- **Visual system:** `docs/DESIGN-SYSTEM.md`

## Platform

web

## Users

**Primary: the solo developer or indie founder.** One person runs their own
small set of production sites and jobs. They have no ops team, no on-call
rotation, and no budget for three separate observability vendors. They want to
learn about a failure before a user reports it.

Secondary, same product, upper end: a small team of 2 to 10, and an agency that
runs many client projects. Team surfaces exist and are complete (roles,
invitations, ownership transfer), but the single-operator path wins a design
conflict.

Three further audiences use PostDeploy surfaces:

- Unauthenticated visitors evaluating PostDeploy on the public site.
- Machine callers: cron schedulers pinging heartbeats, the `/m.js` beacon in an
  end user's browser, SDKs posting error and session envelopes, Stripe webhooks.
- A public visitor can read a published project status page and changelog.
  A public Measure dashboard viewer can open a tokenized, read-only share page.

## Product Purpose

Give one operator one login, one bill, and one dashboard for four pillars:

- **Monitor** — uptime and cron monitoring, with incidents and alerting.
- **Measure** — cookieless, privacy-first web analytics.
- **Observe** — error and session tracking with release health.
- **Analytics** — product analytics: events, funnels, activation and
  retention, from anonymous identifiers the customer's own application
  supplies (`docs/adr/0007-product-analytics.md`).

Success means the operator learns about a real failure before a user reports it,
and cancels two other subscriptions to get there.

## Positioning

Four tools that normally require four vendors, in one product, at one flat
price per organization, with no seat billing and no per-event surprise.

The mechanism a neighbouring product cannot truthfully copy: the pillars
share the Organization and Project scope, so a monitor, a beacon, an error
issue, and a product event describe the same deployed thing without any
cross-vendor wiring.

Qualitative positioning language, the competitor set, and the banned-word list
live in `.agents/product-marketing.md`. Do not restate them here.

## Operating Context

- **Console:** `/dashboard/orgs/:org_token/projects/:project_token/{monitor,measure,observe,analytics}`,
  plus `/team`, `/billing`, `/settings`. Phoenix LiveView.
- **Public site:** server-rendered controller pages, except two LiveView
  routes that need live state: the homepage and the website health check
  (ARCHITECTURE.md §9). Copy comes from the `Alplus.Content` domain, not from
  templates.
- **Public Measure shares:** `/share/:token` is server-rendered and read-only.
  Owners choose panels and can rotate the bearer token.
- **Ingest, unauthenticated by design:** `/h/:token` heartbeats (token in path),
  `POST /m` and `/m.js` analytics (origin allowlist), `/e/errors`,
  `/e/sessions`, `/e/artifacts` (SDK), `POST /v1/events` and
  `POST /v1/events/batch` (write-only `pda_` key, the one CORS path),
  `POST /webhooks/stripe` (signature).
- **Host:** `postdeploy.dev` serves this codebase (cut over 2026-08-20, recorded in
  `docs/PRODUCTION-CUTOVER.md` §9). Canonical URLs resolve, so public pages are
  indexable. A host move must also repoint third-party callbacks that name a
  hostname — see `docs/runbooks/stripe-billing.md` §1.
- **Session:** email and password only. No magic link, no OAuth, no passkeys,
  no TOTP. Cloudflare Turnstile guards registration. Public Measure shares use
  a hashed bearer token, a fixed per-share limit, and a short cache.

## Capabilities and Constraints

**Confirmed hierarchy.** Organization is the tenant root. Organization then
Project is fixed, and both are required URL path segments. A project is
created by a person in the console or by a connected agent through
`projects.create` (founder decision 2026-09-20); an organization, a
membership, and a plan change stay human-only. Environment is a
filter tag, not a resource. Roles are `owner` (unique per org, enforced by a
partial index), `admin`, and `member`. `Alplus.Scope` carries the role as a
cache only; Ash policies re-check the live `memberships` row on every call. A
cross-tenant id returns 404, never 403.

**Billing.** A local read-only mirror of Stripe. The product has a 14-day
trial and one package, PostDeploy, at $29 a month, billed monthly. The
trial has the same limits as the package. The name, price, limits, included
features, and exclusions live in `Alplus.Billing.Package`.

**Not offered at any price** (`ProductFacts` and `docs/BUILD.md` §8): SSO and
SAML, multi-org accounts, custom roles, APM and tracing, session replay,
heatmaps, goal conversions, logs, dashboard customization, seat
billing, GraphQL, mobile apps, localization, white-label, compliance
certifications, ICMP and UDP checks, browser checks, multi-region checks, and
on-call with SMS or voice. Product analytics ships funnels, activation and
retention; it does not ship identity merging, feature flags, an experiment
engine, autocapture, or attribution.

**Unbuilt, and never mentioned on a public surface until shipped:** custom
status domains and outbound webhooks. `Alplus.Id` reserves prefixes for them;
no resource or route exists.

**Error integration (founder decision 2026-10-12).** Error tracking uses the
Sentry envelope format. Every new public installation line, doc page, and code
sample tells the reader to set the DSN of a Sentry client to their Observe key,
`https://<obs_key>@ingest.postdeploy.dev/1`, and to run the client in server
code. The published `@postdeploy/sdk`, `postdeploy_sdk`, and `postdeploy`
packages, and their original `@alplus/sdk`, `alplus_sdk`, and `alplus-ruby`
aliases, still send accepted envelopes. They are legacy reference for readers
already installed, never install copy. Do not describe any published name as
unavailable.

## Brand Commitments

- The name is **PostDeploy**, always written as that word in prose, SEO text, and
  accessible names, never as a stylised glyph.
- `logo/1` in the design system is the only way to draw the mark. It draws
  the mark as inline SVG.
- Third-party trademarks: infrastructure attributions (AWS, Elixir, Ash) may
  render the vendor's own official mark (founder decision 2026-08-20; assets
  in `priv/static/images/vendors/`). The AWS attribution uses the plain
  Amazon Web Services mark (founder decision 2026-08-20), not the "Powered
  by AWS" partner badge. Competitor names still appear as text only, never
  as a logo.
- Never render a middot or a dash as a separator in user-facing text.
- Voice and the banned-word list are set in `.agents/product-marketing.md`.
- One person operates PostDeploy, and the trust page says so plainly.

## Evidence on Hand

Real, and usable:

- Product screenshots: `priv/static/images/product/{monitor,observe,measure}.webp`.
- Social card: `priv/static/images/og-default.{svg,png}`.
- Published JavaScript SDK: `@postdeploy/sdk` 0.5.0 on npm, kept for existing
  installs, with the legacy `@alplus/sdk` alias still resolving. Both
  registry records name `Alplus-Tech/sdk-js` as their source repository.
- Published Elixir SDK: `postdeploy_sdk` 0.2.0 on Hex, kept for existing
  installs, with the legacy `alplus_sdk` alias still resolving. Both registry
  records name `Alplus-Tech/sdk-elixir` as their source repository.
- Published Ruby SDK: `postdeploy` 0.2.0 on RubyGems, kept for existing
  installs, with the legacy `alplus-ruby` alias still resolving. Both name
  `Alplus-Tech/sdk-ruby` as their source repository.
- Compliance disclosure in `lib/alplus/content/trust_seeds.ex`: PostDeploy holds no
  SOC 2 report, no ISO certification, and has commissioned no external
  penetration test.

Absent, and never to be fabricated:

- No customers, testimonials, logos, star ratings, or "trusted by" strip.
- No usage numbers, traffic data, conversion data, or ranking data.
- No benchmarks against a competitor.
- Internal engineering metrics (test counts, quality scores) are internal. They
  never appear on a public page.

## Product Principles

1. **One operator, one screen.** A person with no ops team must reach the answer
   without configuring a pipeline first.
2. **Failure reaches the user before their customer does.** Alerting and
   incident clarity outrank any dashboard feature.
3. **Say only what is shipped.** An unbuilt feature does not appear in copy, and
   an unpublished SDK does not get a page.
4. **Privacy is a product feature, not a policy page.** No cookies, no raw IP,
   no persistent visitor id. A product-analytics identifier is whatever the
   customer's application sends, never derived and never merged.
5. **A tenant boundary is absolute.** Every query is scoped by organization and
   project, and a foreign id is invisible, not forbidden.

## Accessibility & Inclusion

**WCAG 2.2 AA is the binding target.**

Enforced today: `mix alplus.seo.audit` checks five WCAG 2.2 A/AA conditions on
every public route in CI (main landmark, heading order, discernible link text,
`html lang`, labelled navs). The design system mandates a global
`:focus-visible` ring, one `h1` per page, label and error wiring on every field,
dialog focus and Escape handling, honored reduced-motion, and status conveyed by
colour and icon and text together.

Not yet verified, and not to be claimed as done: no axe pass, no contrast audit,
and no keyboard navigation pass. These need a browser and a person.
