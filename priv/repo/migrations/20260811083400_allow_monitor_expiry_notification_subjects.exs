defmodule Alplus.Repo.Migrations.AllowMonitorExpiryNotificationSubjects do
  use Ecto.Migration

  # This expands a delivery subject enum. Existing code remains compatible:
  # it writes only issue and incident subjects. The check is added NOT VALID
  # before validation to avoid a long blocking table scan in production.
  def up do
    execute("SET lock_timeout TO '5s'")

    execute("""
    ALTER TABLE notification_deliveries
      DROP CONSTRAINT notification_deliveries_subject_check
    """)

    execute("""
    ALTER TABLE notification_deliveries
      ADD CONSTRAINT notification_deliveries_subject_check CHECK (
        (subject_type IS NULL AND subject_id IS NULL) OR
        (subject_type IN ('issue', 'incident', 'monitor') AND subject_id IS NOT NULL)
      ) NOT VALID
    """)

    execute("""
    ALTER TABLE notification_deliveries
      VALIDATE CONSTRAINT notification_deliveries_subject_check
    """)
  end

  # A rollback preserves existing monitor rows by leaving the old constraint
  # unvalidated. Old code cannot write new monitor subjects after rollback.
  def down do
    execute("SET lock_timeout TO '5s'")

    execute("""
    ALTER TABLE notification_deliveries
      DROP CONSTRAINT notification_deliveries_subject_check
    """)

    execute("""
    ALTER TABLE notification_deliveries
      ADD CONSTRAINT notification_deliveries_subject_check CHECK (
        (subject_type IS NULL AND subject_id IS NULL) OR
        (subject_type IN ('issue', 'incident') AND subject_id IS NOT NULL)
      ) NOT VALID
    """)
  end
end
