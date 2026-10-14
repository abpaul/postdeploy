defmodule Alplus.Repo.Migrations.AddHeartbeatPingDeduplications do
  @moduledoc """
  Adds the monitor-scoped, short-lived idempotency guard for heartbeat pings.

  The heartbeat writer claims a `(monitor_id, ping_id)` row in the same
  transaction as the runtime transition. The optional `ping_id` therefore
  makes retries and concurrent deliveries no-ops without changing legacy
  requests that omit it.
  """

  use Ecto.Migration

  def up do
    create table(:heartbeat_ping_deduplications, primary_key: false) do
      add :monitor_id,
          references(:monitors,
            column: :id,
            name: "heartbeat_ping_deduplications_monitor_id_fkey",
            type: :text,
            prefix: "public",
            on_delete: :delete_all
          ),
          primary_key: true,
          null: false

      add :ping_id, :text, primary_key: true, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    execute("""
    ALTER TABLE heartbeat_ping_deduplications
      ADD CONSTRAINT heartbeat_ping_deduplications_ping_id_check
      CHECK (octet_length(ping_id) BETWEEN 1 AND 128),
      ADD CONSTRAINT heartbeat_ping_deduplications_expires_at_check
      CHECK (expires_at > '1970-01-01'::timestamptz)
    """)

    create index(:heartbeat_ping_deduplications, [:expires_at],
             name: :heartbeat_ping_deduplications_expires_at_index
           )
  end

  def down do
    drop_if_exists index(:heartbeat_ping_deduplications, [:expires_at],
                     name: :heartbeat_ping_deduplications_expires_at_index
                   )

    execute("""
    ALTER TABLE heartbeat_ping_deduplications
      DROP CONSTRAINT IF EXISTS heartbeat_ping_deduplications_expires_at_check,
      DROP CONSTRAINT IF EXISTS heartbeat_ping_deduplications_ping_id_check
    """)

    drop table(:heartbeat_ping_deduplications)
  end
end
