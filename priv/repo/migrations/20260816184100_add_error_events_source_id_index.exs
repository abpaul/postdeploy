defmodule Alplus.Repo.Migrations.AddErrorEventsSourceIdIndex do
  @moduledoc """
  Second expand step for `error_events.source_id` (issue #46 follow-up): the
  index the Dashboard trend query and `EventWriter` dedup/scan paths need,
  built `CONCURRENTLY` on the live `error_events_default` partition so a
  larger table (unlike this repo's current single row) never blocks
  concurrent ingest writes.

  `CREATE INDEX CONCURRENTLY` cannot run inside a transaction, and it also
  cannot proceed while the migrator holds its lock transaction open — both
  guards below are required, matching
  `20260811151100_add_goals_project_lookup_index.exs`.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("SET lock_timeout = '0'")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS error_events_default_source_received_at_index
      ON error_events_default (source_id, received_at DESC)
    """)
  end

  def down do
    execute("SET lock_timeout = '0'")

    execute("DROP INDEX CONCURRENTLY IF EXISTS error_events_default_source_received_at_index")
  end
end
