# 7. Product analytics stores raw events in Postgres

Status: Accepted (2026-09-20)

## Context

PostDeploy answers operational questions: is the site up, did the cron job
run, are errors happening. It could not answer product questions: are people
finishing onboarding, where do they stop, do they come back, did the last
release change behaviour.

Measure already exists and does not answer them. Measure is cookieless web
analytics: it stores aggregates and deliberately keeps no identifier, so no
query it can run knows that the person who did A later did B. Funnels,
retention, and activation all need exactly that.

The incoming feature request assumed the pre-rewrite Cloudflare stack
(Workers, D1, Queues, Durable Objects, Analytics Engine). That stack was
decommissioned on 2026-08-12. The live architecture is one Phoenix
application, one Postgres database, one Oban job system (ARCHITECTURE.md §1).

## Decision

### The model

One object: an event. `event` is required. `distinct_id`, `timestamp`, and
`properties` are optional. The server adds the project, the source, the
server-trusted environment, an id, and the arrival time. Properties are
schemaless and flat; nothing has to be registered before it is sent.

`distinct_id` is whatever the customer's application sends. PostDeploy never
derives it from an IP address, never fingerprints, never merges two of them,
and never joins one project's events to another's. An event that carries no
`distinct_id` is counted under one shared `unknown` identifier, which makes
the omission visible as a user count of 1 rather than hiding it.

### Storage: raw events, no aggregate tables

`product_events` is one plain Postgres table. Every V1 question is answered
from it at read time.

We considered the usual raw-then-hourly-then-daily rollup ladder and rejected
it for V1. A daily aggregate can answer "how many `meal_logged` events last
week". It cannot answer any of the questions this feature exists for: a
funnel, retention, activation, and a unique-user count all need each person's
own sequence of events. A rollup would therefore be a second write path
serving only the top-line trend, and the trend is the cheapest query of the
set.

The raw window is the analysis window:
`Package.limit(:product_event_retention_days)`, 90 days. The console states
it beside every range control, because a number that cannot be asked for is
worse than a number that is absent.

Bounds that make this safe: `Package.limit(:product_events_per_month)` is
100,000 events with the standard 130% grace ceiling, so one organization at
the ceiling holds roughly 390,000 rows across the 90-day window.

`scripts/benchmark-analytics-queries.exs` measured the reads against a local
PostgreSQL, eight events per person, spread over the full 90 days:

| Rows | Totals, 30d | Event list, 30d | Funnel, 4 steps, 90d | Retention, 90d | Size |
| --- | --- | --- | --- | --- | --- |
| 100,000 | 30 ms | 84 ms | 147 ms | 62 ms | 50 MB |
| 1,000,000 | 340 ms | 855 ms | 2,120 ms | 1,233 ms | 514 MB |

Narrowing a read to one application costs nothing measurable: the same
four-step funnel runs in 150 ms against one application's events, because
the predicate rides the same index.

At the package ceiling, roughly 390,000 rows, the funnel lands near 800 ms
and every other read stays under 400 ms. That is the supported scale.

The table is not partitioned, unlike `error_events`. Retention deletes in
bounded batches by `occurred_at`, which the primary read index already
covers. **The architecture needs to change past roughly 500,000 rows in one
project**: at one million the funnel crosses two seconds, which is past what
a dashboard should make somebody wait for. The two answers, in order of
preference, are a precomputed per-person step table maintained at ingest,
and monthly partitioning as `error_events` already uses. Partitioning also
forces deduplication into a side table, because PostgreSQL cannot enforce a
global unique index across partitions.

### Indexes

Three, matched to the three reads:

| Index | Read |
| --- | --- |
| `(project_id, occurred_at DESC)` | live feed, overall trend |
| `(project_id, event_name, occurred_at DESC)` | event explorer, event detail, funnels |
| `(project_id, distinct_id, occurred_at)` | retention |

Plus a partial unique index on `(project_id, client_event_id)` for
deduplication.

No index is created per property, and none is created on `properties` at
all. A `jsonb_path_ops` GIN index answers containment (`@>`), not the key
extraction (`->>`) that filters and breakdowns use, and the benchmark
confirmed the planner ignored it at one million rows while dropping it left
the filtered query unchanged. Rewriting filters as `@>` would make the index
usable but would compare JSON types rather than text, so a filter would stop
agreeing with the breakdown that produced its value.

A breakdown groups by `properties ->> $key` and caps the result, so a
high-cardinality property costs one scan of the already-narrowed range, not
a schema change.

### Ingest

`POST /v1/events` and `POST /v1/events/batch`, on their own pipeline with
their own rate-limit and admission budgets. The endpoint authenticates,
validates, rate-limits, writes, and answers. It computes no funnel, no
retention, and no aggregate.

Delivery is at-least-once. An optional client `id` deduplicates a retry.
There is no exactly-once machinery.

This is the only PostDeploy path that answers a cross-origin request. A
browser client sends `Authorization` and `Content-Type: application/json`,
which makes the request preflighted; without CORS every web client would
fail. The grant is `*` origin, two request headers, no credentials. The write
key is the boundary, not the origin.

### Credentials

A new `Alplus.Sources.Source` type, `:analytics`, minting a `pda_*` secret.
It is published inside the customer's mobile and browser applications, so it
authorizes `POST /v1/events` for one project and nothing else: no analytics
read, no project configuration, no other pillar. `AlplusWeb.Plugs.IngestAuth`
takes the accepted Source type from the pipeline, so an Observe key on the
analytics route fails exactly like an unknown key, and the reverse holds.

A project may hold several active analytics Sources, like Measure and unlike
Observe: one project ships an iOS app, an Android app, and a web app, and
each needs a key it can rotate without stopping the others.

### One project, several applications

The applications of one product belong in one project, and the event pool is
shared. That is the point: the same `distinct_id` signing up on the web and
acting in the mobile app is ONE person in a funnel, which is exactly what
separate projects, or separate vendors, cannot tell you.

The application is a real dimension, not a naming convention. Every event
carries the `source_id` of the key that wrote it, and every read takes an
optional `source_id`: totals, the event list, trends, breakdowns, funnels,
retention, the live feed, and the export. Omitting it reads every
application together.

The console offers an "App" picker on every analytics screen, and draws none
for a project with one application. MCP reads take the same choice as an
optional `source_handle`.

A per-application cohort counts only that application's own returns, so
"iOS day-1 retention" does not silently count a return that happened on
Android.

### Console and MCP

The console is read-only, as it is everywhere else (PRODUCT.md). Analytics is
configured through MCP: creating the write key, saving funnels, setting the
activation definition, and deleting analytics data are all `analytics.*`
tools. Destructive tools carry `destructiveHint`, and `analytics.delete_data`
additionally requires the project handle to be typed a second time.

The `analytics.*` tools share the existing `analytics:read` and
`analytics:write` OAuth scopes with Measure and SEO. All three answer "how is
this product doing", so one consent decision covers them and the
authorization screen stays readable.

### Definitions

These are the product, so they are fixed and stated:

- **Event count** is the number of matching rows.
- **Unique users** is `count(DISTINCT distinct_id)`.
- **Funnel conversion** starts at each person's first step-one event inside
  the range. Each later step must occur strictly after the previous step's
  matched event, and within the funnel's window measured from the step-one
  event. Repeating a step does not count twice. The default window is
  168 hours, because onboarding in a subscription product spans sessions.
- **Retention** is exact-period, never rolling: a person counts at offset N
  only if they did the return event during that exact day or week. The
  denominator at offset N leaves out cohort members whose offset-N period has
  not finished.
- **Activation** is a two-step funnel from a starting event to an activation
  event, so it shares the funnel definition and the funnel code.
- Every stored and displayed time is UTC.

### Cost

Ingest is a Phoenix request and one multi-row insert on an existing node and
an existing RDS instance. There is no per-event vendor charge, no queue to
pay for, and no second database.

The measured cost is about 520 bytes per event including indexes. Per
organization per month, against the $29 package:

| Events a month | Rows in the 90-day window | Storage |
| --- | --- | --- |
| 10,000 | 30,000 | ~16 MB |
| 100,000 | 300,000 | ~155 MB |
| 130,000 (the grace ceiling) | 390,000 | ~200 MB |

Past the ceiling the meter drops events, so an organization cannot grow its
own storage without a plan change. Ten million events a month is therefore
not a state this package can reach; it is the number that would justify the
architecture change above.

The marginal cost of the feature is Postgres storage and the CPU of the
analytic queries, both bounded by the quota the customer already pays for.

## Consequences

- Funnels move from the "not offered" list to shipped. `PRODUCT.md`,
  `docs/BUILD.md`, and `AlplusWeb.Marketing.ProductFacts` all change, and the
  facts contract goes to 4.0.0.
- "Analytics events" now names two different meters, so the billing labels
  become "Web analytics events" (Measure) and "Product analytics events"
  (this feature).
- `Alplus.Billing.EventMeter` gains a batch form. It cannot stay a single
  `INSERT ... ON CONFLICT DO UPDATE`, because `RETURNING` never sees the
  pre-update row and a batch needs to know how many of its events were taken.
  It is now a row-locked update inside a transaction, which keeps the
  ceiling decision atomic.
- Funnels and retention cannot look further back than the raw retention
  window. That is a real limit and the console states it rather than
  silently truncating.
- No identity merging, no session replay, no feature flags, no experiment
  engine, no autocapture. The event model leaves room for each; none is
  built.

### Known limits of V1

Each of these is a deliberate stopping point, not an oversight:

- A retried event that carries an `id` PostDeploy already stored writes
  nothing, but still counts once against the monthly allowance. The meter
  runs before the insert so the ceiling stays atomic, and refunding the
  difference would need a second write on the hot path.
- A funnel breakdown draws the twenty values with the most people entering
  and says so. It has no `(other)` bucket, because the rows of a funnel are
  per-step user counts and those do not sum across buckets into anything a
  reader should act on.
- `analytics.update_funnel` cannot clear `filters` or `breakdown_property`;
  an omitted argument keeps the saved value. Replace the funnel to clear one.
- The export route runs on the browser pipeline and so skips `ConnectGate`,
  which every analytics LiveView passes through. It is still membership- and
  project-scoped, so an unconnected project exports only its own (empty)
  data.
- Retention offers daily and weekly cohorts. Monthly needs a calendar-aware
  denominator and is not built.
