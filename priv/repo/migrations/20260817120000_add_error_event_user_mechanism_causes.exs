defmodule Alplus.Repo.Migrations.AddErrorEventUserMechanismCauses do
  use Ecto.Migration

  @moduledoc """
  Adds the ingest fields the wire contract already validated but the writer
  dropped: the event's `user` (id/email), its capture `mechanism`
  (handled vs unhandled), and the exception `cause` chain.

  All columns are nullable with no default, so the ADD COLUMN on the
  partitioned parent is metadata-only. CHECK constraints go in NOT VALID
  first, then VALIDATE, to avoid holding a full-table lock; every existing
  row has NULL in these columns, so validation cannot fail.
  """

  def up do
    execute("SET lock_timeout = '3s'")

    execute("ALTER TABLE error_events ADD COLUMN user_id text")
    execute("ALTER TABLE error_events ADD COLUMN user_email text")
    execute("ALTER TABLE error_events ADD COLUMN mechanism text")
    execute("ALTER TABLE error_events ADD COLUMN causes jsonb")

    execute("""
    ALTER TABLE error_events
      ADD CONSTRAINT error_events_user_id_check
      CHECK (user_id IS NULL OR octet_length(user_id) <= 512) NOT VALID
    """)

    execute("""
    ALTER TABLE error_events
      ADD CONSTRAINT error_events_user_email_check
      CHECK (user_email IS NULL OR octet_length(user_email) <= 512) NOT VALID
    """)

    execute("""
    ALTER TABLE error_events
      ADD CONSTRAINT error_events_mechanism_check
      CHECK (mechanism IS NULL OR octet_length(mechanism) <= 64) NOT VALID
    """)

    execute("ALTER TABLE error_events VALIDATE CONSTRAINT error_events_user_id_check")
    execute("ALTER TABLE error_events VALIDATE CONSTRAINT error_events_user_email_check")
    execute("ALTER TABLE error_events VALIDATE CONSTRAINT error_events_mechanism_check")
  end

  def down do
    execute("ALTER TABLE error_events DROP COLUMN user_id")
    execute("ALTER TABLE error_events DROP COLUMN user_email")
    execute("ALTER TABLE error_events DROP COLUMN mechanism")
    execute("ALTER TABLE error_events DROP COLUMN causes")
  end
end
