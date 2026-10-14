defmodule Alplus.Repo.Migrations.AddObserveErrorEvents do
  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    # Client ids must deduplicate across every event partition. PostgreSQL
    # cannot enforce a global unique index on a range-partitioned table, so a
    # small non-partitioned guard table is written in the same transaction.
    execute("""
    CREATE TABLE error_event_deduplications (
      event_id text PRIMARY KEY,
      org_id text NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      project_id text NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      received_at timestamptz NOT NULL
    )
    """)

    execute("""
    CREATE TABLE error_events (
      received_at timestamptz NOT NULL,
      event_id text NOT NULL,
      issue_id text NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
      org_id text NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      project_id text NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      environment text NOT NULL,
      occurred_at timestamptz NOT NULL,
      level text NOT NULL,
      message text,
      exception_type text,
      exception_value text,
      frames jsonb,
      context jsonb,
      tags jsonb,
      breadcrumbs jsonb,
      release text,
      sdk_name text NOT NULL,
      sdk_version text NOT NULL,
      payload_s3_key text,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (received_at, event_id),
      CONSTRAINT error_events_level_check CHECK (level IN ('fatal', 'error', 'warning', 'info')),
      CONSTRAINT error_events_environment_check CHECK (octet_length(environment) BETWEEN 1 AND 64),
      CONSTRAINT error_events_event_id_check CHECK (octet_length(event_id) BETWEEN 4 AND 64),
      CONSTRAINT error_events_message_check CHECK (message IS NULL OR octet_length(message) <= 4096),
      CONSTRAINT error_events_exception_type_check CHECK (exception_type IS NULL OR octet_length(exception_type) <= 256),
      CONSTRAINT error_events_exception_value_check CHECK (exception_value IS NULL OR octet_length(exception_value) <= 4096),
      CONSTRAINT error_events_release_check CHECK (release IS NULL OR octet_length(release) <= 256),
      CONSTRAINT error_events_sdk_name_check CHECK (octet_length(sdk_name) BETWEEN 1 AND 128),
      CONSTRAINT error_events_sdk_version_check CHECK (octet_length(sdk_version) BETWEEN 1 AND 64),
      CONSTRAINT error_events_payload_s3_key_check CHECK (payload_s3_key IS NULL OR octet_length(payload_s3_key) <= 1024)
    ) PARTITION BY RANGE (received_at)
    """)

    # The default partition preserves availability when a future monthly
    # partition has not yet been created. Retention work will attach/drop
    # bounded monthly partitions without changing the ingest contract.
    execute("CREATE TABLE error_events_default PARTITION OF error_events DEFAULT")

    execute(
      "CREATE INDEX error_events_default_issue_received_at_index ON error_events_default (issue_id, received_at DESC)"
    )

    execute(
      "CREATE INDEX error_events_default_project_received_at_index ON error_events_default (org_id, project_id, received_at DESC)"
    )
  end

  def down do
    execute("DROP TABLE error_events")
    execute("DROP TABLE error_event_deduplications")
  end
end
