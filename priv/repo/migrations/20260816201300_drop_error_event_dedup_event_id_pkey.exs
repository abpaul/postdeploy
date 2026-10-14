defmodule Alplus.Repo.Migrations.DropErrorEventDedupEventIdPkey do
  @moduledoc """
  Contract step for `error_event_deduplications` (issue #46 follow-up, see
  "Observe error-event dedup: per-source scoping" in
  `docs/observe-source-id-phase-b.md`): drops the original PRIMARY KEY on
  `event_id` ALONE (`20260811131500_add_observe_error_events.exs`).

  That PK is now redundant -- `error_event_deduplications_org_project_source_event_index`
  (`20260816202100_add_error_event_dedup_source_index.exs`) already enforces
  the correct uniqueness -- and it actively BLOCKS the fix this release
  ships: it is an unconditional unique constraint, not just an `ON
  CONFLICT` arbiter, so two different Sources reusing one `event_id` still
  raise an unhandled `unique_violation` on it even though
  `Alplus.Observe.EventWriter.claim_event_id/1`'s composite arbiter finds
  no conflict.

  No replacement PRIMARY KEY is added: `error_event_deduplications` has no
  Ecto schema or Ash resource (`docs/DIRECT-ECTO-ESCAPE-HATCHES.md`, a
  hand-written-SQL guard table for the partitioned `error_events` table),
  so nothing requires a PK, and the composite unique index already gives
  every row a stable identity for `ON CONFLICT`.

  Ships in the same release as the arbiter switch. Accepted, single-release
  cutover risk: production's currently-deployed container, still running
  `ON CONFLICT (event_id)`, has no matching arbiter for the few seconds to
  minutes between this migration running (on boot, before the new
  container serves traffic) and the old container being drained during the
  Kamal health-check window -- an ingest request hitting the OLD container
  in that window gets an unhandled `unique_violation` (500), not silent
  data loss. See `docs/observe-source-id-phase-b.md` for the full
  reasoning and why an intermediate two-phase drop was rejected here.

  `DROP CONSTRAINT` on this small (row count checked, not the multi-million
  row scale the `database-safety` skill's lock-avoidance steps target)
  non-partitioned table takes a brief `ACCESS EXCLUSIVE` lock; `lock_timeout`
  bounds the wait rather than queuing behind other writers indefinitely.
  """

  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    execute(
      "ALTER TABLE error_event_deduplications DROP CONSTRAINT error_event_deduplications_pkey"
    )
  end

  def down do
    execute("SET lock_timeout = '3s'")

    execute(
      "ALTER TABLE error_event_deduplications ADD CONSTRAINT error_event_deduplications_pkey PRIMARY KEY (event_id)"
    )
  end
end
