defmodule Alplus.Repo.Migrations.AddErrorEventDedupSourceId do
  @moduledoc """
  Expand step for scoping dedup per Source, not just per tenant (issue #46
  follow-up, see the "Observe error-event dedup" section in
  `docs/observe-source-id-phase-b.md`): retries always come from the same
  Source, but two *different* Sources in one project can legitimately reuse
  an `event_id` (confirmed against dev: a staging Source's post was dropped
  as `duplicate` because a production Source had already used that
  `event_id`). Dedup must be scoped to `(org_id, project_id, source_id,
  event_id)`.

  Adds a nullable `source_id` column, mirroring
  `20260816184000_add_error_events_source_id.exs`: `error_event_deduplications`
  is a small, non-partitioned guard table (see
  `20260811131500_add_observe_error_events.exs`), so unlike that migration's
  partitioned `error_events` target, the FK here CAN use the standard `NOT
  VALID` + `VALIDATE CONSTRAINT` split (`database-safety` skill) to avoid a
  full-table `ACCESS EXCLUSIVE` scan while adding the constraint.
  `VALIDATE CONSTRAINT` only takes `SHARE UPDATE EXCLUSIVE` (blocks other
  schema changes, not reads/writes), so it is safe to run in the same
  migration right after the `NOT VALID` add.

  `ON DELETE SET NULL` is an accepted tradeoff, not an oversight: destroying
  an `Alplus.Sources.Source` (`Alplus.Sources.Source`'s `:destroy` action)
  nulls that Source's own dedup rows' `source_id` rather than cascading the
  delete or blocking it. A NULL `source_id` never collides with anything on
  `error_event_deduplications_org_project_source_event_index` (`NULL <>
  NULL` per row), so in isolation this reads as "retry-dedup silently stops
  for that row." In practice it cannot: ingest authenticates against the
  live `sources` row itself, so once a Source is destroyed no future
  request can authenticate as it, and no retry for that Source's events can
  ever reach `claim_event_id/1` again. The only real effect is losing the
  historical Source attribution on that one dedup row after its Source is
  gone -- acceptable for a dedup guard table, not acceptable to trade for
  `RESTRICT` (which would block deleting a Source until every dedup row it
  ever wrote was cleaned up first).
  """

  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    execute("ALTER TABLE error_event_deduplications ADD COLUMN source_id text")

    execute("""
    ALTER TABLE error_event_deduplications
      ADD CONSTRAINT error_event_deduplications_source_id_fkey
      FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE SET NULL
      NOT VALID
    """)

    execute(
      "ALTER TABLE error_event_deduplications VALIDATE CONSTRAINT error_event_deduplications_source_id_fkey"
    )
  end

  def down do
    execute(
      "ALTER TABLE error_event_deduplications DROP CONSTRAINT error_event_deduplications_source_id_fkey"
    )

    execute("ALTER TABLE error_event_deduplications DROP COLUMN source_id")
  end
end
