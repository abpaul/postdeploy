defmodule Alplus.Repo.Migrations.AddErrorEventsSourceId do
  @moduledoc """
  Expand step (issue #46 follow-up): a nullable `source_id` on the
  partitioned `error_events` table, so ingest can attribute each row to the
  Source that authenticated it instead of a bare `environment` string.

  `error_events` has no Ash resource (`docs/DIRECT-ECTO-ESCAPE-HATCHES.md`),
  so this is a hand-written migration, not `ash_postgres.generate_migrations`
  output.

  Adding a nullable column with no default is metadata-only on Postgres 11+
  (no table rewrite), and a `CREATE INDEX ... ON error_events` on a
  partitioned parent with only the default partition currently attached
  cascades to that one partition — this repo's `error_events` table today
  has exactly one partition (`error_events_default`, see
  `20260811131500_add_observe_error_events.exs`), so there is nothing to
  batch here yet.

  Postgres does not support an `ADD CONSTRAINT ... NOT VALID` foreign key on
  a partitioned table as the referencing side ("This feature is not yet
  supported on partitioned tables", confirmed against this repo's Postgres
  by running it), so the usual NOT VALID/VALIDATE split (`docs/adr` database
  safety skill) is unavailable here — the existing `org_id`/`project_id`/
  `issue_id` FKs on this same table were added the same validating way, at
  table-creation time. This validates inline; on a large future
  `error_events` this step should be re-checked against Postgres's current
  partitioned-FK support before running it against a populated table.
  """

  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    execute("ALTER TABLE error_events ADD COLUMN source_id text")

    execute("""
    ALTER TABLE error_events
      ADD CONSTRAINT error_events_source_id_fkey
      FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE SET NULL
    """)
  end

  def down do
    execute("ALTER TABLE error_events DROP CONSTRAINT error_events_source_id_fkey")
    execute("ALTER TABLE error_events DROP COLUMN source_id")
  end
end
