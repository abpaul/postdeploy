defmodule Alplus.Repo.Migrations.AddErrorEventDedupSourceIndex do
  @moduledoc """
  Second expand step for scoping dedup per Source (issue #46 follow-up, see
  `docs/observe-source-id-phase-b.md`): adds the composite
  `(org_id, project_id, source_id, event_id)` unique index the corrected
  `ON CONFLICT` arbiter needs.

  Purely additive relative to the original `event_id`-only PRIMARY KEY
  (`20260811131500_add_observe_error_events.exs`): that PK is left in place
  so production's live code, still running `ON CONFLICT (event_id)`, keeps
  matching its arbiter during this release's Kamal cutover. Both arbiters
  coexist during the cutover window; `docs/observe-source-id-phase-b.md`
  documents the deferred later-release drop of that now-redundant PK.

  An intermediate `(org_id, project_id, event_id)` unique index was
  considered and deliberately NOT added: it never shipped to production
  (confirmed via `git log` -- production's `ON CONFLICT` target has always
  been `(event_id)` alone), so it has no old-container arbiter to protect,
  and as an unconditional unique constraint it would itself block two
  different Sources in one project from both being accepted -- the exact
  bug this migration set fixes.

  Run this before `Alplus.Observe.EventWriter.claim_event_id/1`'s arbiter
  switches to the composite key, so the index exists once ingest starts
  writing to it. Must also run after the backfill
  (`mix observe.backfill_dedup_source_ids`) populates `source_id` on
  existing rows -- a row still NULL is fine (`NULL <> NULL` per row, so
  multiple NULLs never collide on a unique index), but the backfill should
  run first so as few rows as possible fall back to unattributed dedup.

  `CREATE UNIQUE INDEX CONCURRENTLY` cannot run inside a transaction, and it
  also cannot proceed while the migrator holds its lock transaction open --
  both guards below are required, matching
  `20260816184100_add_error_events_source_id_index.exs`.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("SET lock_timeout = '0'")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS error_event_deduplications_org_project_source_event_index
      ON error_event_deduplications (org_id, project_id, source_id, event_id)
    """)
  end

  def down do
    execute("SET lock_timeout = '0'")

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS error_event_deduplications_org_project_source_event_index"
    )
  end
end
