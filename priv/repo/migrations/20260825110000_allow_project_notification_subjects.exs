defmodule Alplus.Repo.Migrations.AllowProjectNotificationSubjects do
  use Ecto.Migration

  # Observe quota alerts use the project as their durable subject. Keep the
  # constraint change narrow and validate it separately so the table is not
  # held under a long validation lock during deploy.
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
        (subject_type IN ('issue', 'incident', 'monitor', 'project') AND subject_id IS NOT NULL)
      ) NOT VALID
    """)

    execute("""
    ALTER TABLE notification_deliveries
      VALIDATE CONSTRAINT notification_deliveries_subject_check
    """)
  end

  # Preserve monitor and project rows on rollback. The old application can no
  # longer create them, but existing immutable history remains readable.
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
        (subject_type IN ('issue', 'incident', 'monitor') AND subject_id IS NOT NULL)
      ) NOT VALID
    """)
  end
end
