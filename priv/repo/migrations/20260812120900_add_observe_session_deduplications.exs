defmodule Alplus.Repo.Migrations.AddObserveSessionDeduplications do
  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    # A small, short-lived (24h, `Alplus.Observe.Retention.prune_session_dedup/1`)
    # guard table for `POST /e/sessions` retry dedup, mirroring
    # `error_event_deduplications`. Not an Ash resource: only
    # `Alplus.Observe.SessionRollupWriter`'s direct-SQL writer touches it
    # (ARCHITECTURE.md §8 "optimized PostgreSQL writes for high-volume
    # paths"), and no raw session data is stored past the claim itself
    # (issue #12, ARCHITECTURE.md decision #4).
    execute("""
    CREATE TABLE observe_session_deduplications (
      session_id text PRIMARY KEY,
      org_id text NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      project_id text NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      received_at timestamptz NOT NULL,
      CONSTRAINT observe_session_deduplications_session_id_check CHECK (octet_length(session_id) BETWEEN 4 AND 64)
    )
    """)

    execute(
      "CREATE INDEX observe_session_deduplications_received_at_index ON observe_session_deduplications (received_at)"
    )
  end

  def down do
    execute("DROP TABLE observe_session_deduplications")
  end
end
