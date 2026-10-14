defmodule Alplus.Repo.Migrations.AddObserveErrorPayloadOutboxes do
  use Ecto.Migration

  @moduledoc """
  Persists oversized Observe payloads beside their trimmed event rows until an
  Oban worker confirms object storage. The payload is bounded by the 1 MiB
  ingest envelope limit and is removed only after a successful object PUT.
  """

  def up do
    execute("SET lock_timeout = '3s'")

    execute("""
    CREATE TABLE observe_error_payload_outboxes (
      id text PRIMARY KEY,
      event_received_at timestamptz NOT NULL,
      event_id text NOT NULL,
      project_id text NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      payload_s3_key text NOT NULL,
      payload bytea NOT NULL,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT observe_error_payload_outboxes_event_key
        UNIQUE (event_received_at, event_id),
      CONSTRAINT observe_error_payload_outboxes_payload_size_check
        CHECK (octet_length(payload) BETWEEN 1 AND 1048576),
      CONSTRAINT observe_error_payload_outboxes_key_size_check
        CHECK (octet_length(payload_s3_key) BETWEEN 1 AND 1024),
      CONSTRAINT observe_error_payload_outboxes_event_fk
        FOREIGN KEY (event_received_at, event_id)
        REFERENCES error_events (received_at, event_id)
        ON DELETE CASCADE
    )
    """)

    execute("""
    CREATE INDEX observe_error_payload_outboxes_inserted_at_index
      ON observe_error_payload_outboxes (inserted_at)
    """)
  end

  def down do
    execute("DROP TABLE observe_error_payload_outboxes")
  end
end
