# Observe `source_id` Phase B (not yet scheduled)

Phase A (this deploy, issue #46 follow-up) added a nullable `source_id`
column to `issues`, `releases`, `error_events`, and
`observe_session_rollups`, backfilled it, and scoped every READ by
`source_id`. It deliberately left the ingest writers' `ON CONFLICT`
targets, and the DB unique indexes those targets depend on, on the old
`environment`-keyed columns. See the Phase A note in
`Alplus.Observe.Issue`, `Alplus.Observe.Release`, and
`Alplus.Observe.SessionRollup` moduledocs for why: a same-release swap of
the unique index AND the `ON CONFLICT` target breaks live ingest during a
Kamal cutover, because the old container (still running against the new
schema during the health-check window) would either violate a
newly-sole-surviving `source_id` unique index it never wrote through, or
find no matching arbiter index for its still-`environment`-keyed `ON
CONFLICT` clause. Both 500 on ingest.

Do **not** deploy Phase B until:

1. Phase A has been live for at least one full deploy cycle (so no
   in-flight old container can still hit the writers below).
2. `mix observe.backfill_source_ids` and the session-rollup backfill
   (`Alplus.Observe.SourceIdBackfill.Runner`, which also covers session rollups, invoked the same
   way) have both run to completion against production and their
   `unattributed` counts have been reviewed.

## Migration (expand step already done; this is Phase B's contract step)

Run as its own release, in this order inside one migration file per table
(each `CREATE UNIQUE INDEX CONCURRENTLY` outside the migration's DDL
transaction, each in its own migration per the `database-safety` skill):

```elixir
# 1. issues
def up do
  execute("SET lock_timeout = '3s'")

  create index(:issues, [:org_id, :project_id, :source_id, :fingerprint],
           unique: true,
           name: "issues_fingerprint_per_source_index",
           concurrently: true
         )

  drop_if_exists index(:issues, [:org_id, :project_id, :environment, :fingerprint],
                   name: "issues_fingerprint_per_environment_index"
                 )
end
```

Mirror this for `releases` (`releases_version_per_source_index` on
`(org_id, project_id, source_id, version)`, dropping
`releases_org_id_project_id_environment_version_index`) and for
`observe_session_rollups` (see below).

Update `Alplus.Observe.Issue`, `Alplus.Observe.Release`, and
`Alplus.Observe.SessionRollup`'s `custom_indexes` to match (source_id-keyed
unique, drop the environment-keyed unique, keep or drop the now-redundant
non-unique `source_id` read index at the same time), then run
`mix ash_postgres.generate_migrations` and diff its output against the
hand-written migration above -- they must agree, or the next codegen run
will try to "fix" the schema back.

## `Alplus.Observe.EventWriter` diff

```diff
- ON CONFLICT (org_id, project_id, environment, fingerprint) DO UPDATE
+ ON CONFLICT (org_id, project_id, source_id, fingerprint) DO UPDATE
```

removes `source_id = EXCLUDED.source_id` from the `SET` list (no longer
needed -- it is now the conflict target), and `previous_issue_status/2`'s
`SELECT ... FOR UPDATE` predicate moves from `environment = $3` to
`source_id = $3`, matching the new conflict target.

## `Alplus.Observe.SessionRollupWriter` diff

Same shape:

```diff
- ON CONFLICT (org_id, project_id, environment, release, window_start) DO UPDATE
+ ON CONFLICT (org_id, project_id, source_id, release, window_start) DO UPDATE
```

drop the environment-keyed unique index
(`observe_session_rollups_scope_window_index`), add the source_id-keyed
one, and update `Alplus.Observe.SessionRollup`'s `custom_indexes` and
`list_for_release` read action to match (it already reads by `source_id`
as of Phase A finding 2, so only the index/constraint moves).

## Observe error-event dedup: per-source scoping (issue #46 follow-up)

Until this deploy, `error_event_deduplications` had a PRIMARY KEY on
`event_id` ALONE (`20260811131500_add_observe_error_events.exs`), so
`Alplus.Observe.EventWriter.claim_event_id/1`'s
`ON CONFLICT (event_id) DO NOTHING` deduplicated globally: across every
org/project (a second org posting an `event_id` a first org already used
was silently dropped as `duplicate` -- a cross-tenant suppression bug), AND
across every Source within one project (retries always come from the same
Source, but two *different* Sources legitimately reuse an `event_id` --
confirmed against dev, an "elixir app" staging Source's post was dropped as
`duplicate` because a "rails app" production Source in the same project had
already used that `event_id`). Both are the same class of bug: the arbiter
was too coarse. The fix goes directly from `(event_id)` to
`(org_id, project_id, source_id, event_id)` in one hop -- same Source + same
`event_id` still dedups (retry protection); different org, project, or
Source + same `event_id` are all accepted independently, each creating its
own issue/event.

An intermediate `(org_id, project_id, event_id)`-only step was considered
and rejected: it would have required its own unique index kept around for
Kamal cutover safety exactly like the old PK below, but checked against
`git log`, that intermediate arbiter never shipped to production (production
has only ever run `ON CONFLICT (event_id)`), so there was no old-container
arbiter for it to protect -- it would have been a pure liability, an
unconditional unique constraint that itself blocks two different Sources in
one project from both being accepted, i.e. the exact bug this fix targets.

The old `event_id`-only PRIMARY KEY is real cutover-safety debt, but it
cannot be *deferred*: it is an unconditional unique constraint on every
`INSERT`, not just an `ON CONFLICT` arbiter, so leaving it in place blocks
the exact bug this release fixes -- two different Sources in one project
reusing an `event_id` still raise an unhandled `unique_violation` on the
old PK even though the new composite arbiter finds no conflict for them.
Deferring the drop would ship a release that still crashes on the reported
scenario. The drop ships in THIS release
(`20260816201300_drop_error_event_dedup_event_id_pkey.exs`); the accepted
tradeoff is a brief, single-release Kamal cutover window, not a
multi-release deferral -- see "Residual risk" below.

**This deploy (shipped):**

- `20260816202000_add_error_event_dedup_source_id.exs` -- adds a nullable
  `source_id text` column to `error_event_deduplications`, with a
  `REFERENCES sources(id) ON DELETE SET NULL` foreign key added `NOT VALID`
  then `VALIDATE CONSTRAINT`ed in the same migration. Unlike
  `error_events.source_id` (`20260816184000_add_error_events_source_id.exs`,
  partitioned, so `NOT VALID` is unsupported by Postgres on that table),
  `error_event_deduplications` is a plain non-partitioned table, so the
  standard two-step split applies and avoids a full-table `ACCESS EXCLUSIVE`
  scan. Metadata-only column add; no rewrite. `ON DELETE SET NULL` is an
  accepted, documented tradeoff -- see the migration's own moduledoc for why
  it does not create the retry-dedup gap it looks like it would.
- `Alplus.Observe.DedupSourceIdBackfill` / `mix observe.backfill_dedup_source_ids`
  -- batched, resumable backfill, keyset-paginated over the full
  `(event_id, org_id, project_id)` tuple (never `OFFSET`), because this
  table now allows several rows to share one `event_id` (that is the whole
  point of the fix) -- a plain `event_id > $cursor` boundary landing inside
  such a group would silently skip the rest of it; the 3-column cursor
  keeps a strict total order so no row is skipped or double-applied. See
  `Alplus.Observe.DedupSourceIdBackfill`'s moduledoc and
  `test/alplus/observe/dedup_source_id_backfill_test.exs` (a regression
  test that fails against an `event_id`-only cursor). Unlike
  `Alplus.Observe.SourceIdBackfill` (which reconstructs a Source from
  lifecycle-window timing because the target tables predate `source_id`),
  this is an exact join: `error_events` already carries the correct
  `source_id` for the same `event_id`, written by the same ingest
  transaction. A dedup row with no matching `error_events` row (partition
  pruned by retention, or older than `error_events` itself) is left
  `source_id IS NULL` and logged as `unmatched` rather than guessed at.
  (`Alplus.Observe.SourceIdBackfill.Runner`'s own cursors -- a table's real
  single-column PK for `issues`/`releases`/`observe_session_rollups`, and
  `error_events`'s real composite PK `(received_at, event_id)` -- were
  checked against the same bug and are safe; that table's rows are unique
  on those columns by construction.)
- `20260816202100_add_error_event_dedup_source_index.exs` --
  `CREATE UNIQUE INDEX CONCURRENTLY` on
  `(org_id, project_id, source_id, event_id)`. A row with `source_id IS
  NULL` never collides with another `NULL` row on this index (Postgres
  treats `NULL <> NULL` per row in a unique index), so an unbackfilled or
  unmatched row degrades to "dedup disabled across Sources for that one
  legacy `event_id`," never a blocked insert.
- `20260816201300_drop_error_event_dedup_event_id_pkey.exs` -- drops the
  original `event_id`-only PRIMARY KEY. No replacement PK is added:
  `error_event_deduplications` has no Ecto schema or Ash resource, so
  nothing requires one, and the composite unique index above already gives
  every row a stable arbiter.
- `Alplus.Observe.EventWriter.claim_event_id/1` -- `ON CONFLICT` arbiter
  switched to `(org_id, project_id, source_id, event_id)` NOW, in this same
  release, writing `source_id` in the `INSERT`.

**Residual risk (honest version, single release, not "negligible"):**

The old PK drop and the arbiter switch ship in the SAME release, which is
NOT the usual two-release expand/contract pattern this repo otherwise
follows (see the `source_id` migrations earlier in this doc, and the
`database-safety` skill) -- that pattern was rejected here because
deferring the drop would ship a release that still 500s on the exact bug
being fixed (see above). The real cost: during this release's Kamal
cutover, for the seconds-to-low-minutes the health check takes to drain
the OLD container, any ingest request still landing on that old container
runs `ON CONFLICT (event_id)` against a table whose PK no longer exists.
That `ON CONFLICT` clause has no arbiter to match, so Postgres raises an
error and that request 500s -- for EVERY ingest request hitting the old
container in that window, not just colliding ones, until the load balancer
finishes draining it to the new container. This is a deliberate,
accepted, brief availability cost for this one deploy, bounded by the
health-check window, not an ongoing risk and not something later releases
need to remember to clean up.

### Dev/test: fresh schema, not hand-doctored

An earlier version of this section hand-migrated `alplus_dev` and
`alplus_test` (dropping the PK and pre-registering `schema_migrations` row
`20260816201300` for a migration file that did not exist yet) because the
drop was, at the time, planned as a deferred follow-up release. That
framing changed: the drop ships now, as the committed migration file above,
using that same reserved version number. Concretely:

- `alplus_dev` already had `schema_migrations` row `20260816201300` (from
  the earlier hand bookkeeping) and its PK already dropped by hand. Adding
  the real migration file at that exact version means `mix ecto.migrate`
  on dev matches it to the existing row and treats it as already applied
  -- confirmed: `mix ecto.migrate` on dev after adding the file printed
  `Migrations already up`, a true no-op, and `mix ecto.migrations` shows no
  `FILE NOT FOUND` rows. Warning: dev holds the founder's live test data
  (the "rails app" / "elixir app" sources and their issues) and was
  deliberately never dropped or recreated.
- `alplus_test` is ephemeral, so it was rebuilt from the committed
  migration files alone: `MIX_ENV=test mix ecto.drop && MIX_ENV=test mix
  ecto.setup`, then `mix test`. This is the integrity check that the
  schema the test suite exercises is exactly what a fresh production
  deploy would produce from these migration files -- not an artifact of
  hand-doctoring. See the verification output in this change's report.
- The rejected intermediate `(org_id, project_id, event_id)` unique index
  (`20260816201200_add_error_event_dedup_org_project_index.exs`, see the
  rejected-approach paragraph above) never appears in the committed
  migration set at all, so it needs no bookkeeping on either database --
  it was applied and then fully reversed (index dropped, its
  `schema_migrations` row deleted) on both `alplus_dev` and `alplus_test`
  before this file set was finalized.

Both databases now carry exactly one unique arbiter on
`error_event_deduplications` (the composite index) and no PK, matching
what the committed migrations alone produce.

## Why not do this now

ADR 0001 (`docs/adr/0001-unified-telemetry-sources.md`) guarantees one
active Observe Source per environment, so for the steady state,
environment-scoped dedup and source-scoped dedup are the same dedup. The
only case they diverge is a brief window after a key rotation or Source
replacement, where an old and new Source both still receive traffic for
the same environment -- Phase A accepts that rare, brief cross-Source
collision (two Sources' events land on one issue row) in exchange for a
deploy that cannot 500 live ingest during cutover. Phase B removes that
edge case once it is safe to change the arbiter index and the `ON
CONFLICT` target together.
