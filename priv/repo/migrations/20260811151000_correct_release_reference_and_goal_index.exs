defmodule Alplus.Repo.Migrations.CorrectReleaseReferenceAndGoalIndex do
  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    execute("""
    ALTER TABLE issues
      ADD CONSTRAINT issues_resolved_release_scope_fkey_v2
        FOREIGN KEY (org_id, project_id, resolved_in_release_id)
        REFERENCES releases (org_id, project_id, id)
        ON DELETE SET NULL (resolved_in_release_id) NOT VALID
    """)

    execute("ALTER TABLE issues VALIDATE CONSTRAINT issues_resolved_release_scope_fkey_v2")
    execute("ALTER TABLE issues DROP CONSTRAINT issues_resolved_release_scope_fkey")

    execute(
      "ALTER TABLE issues RENAME CONSTRAINT issues_resolved_release_scope_fkey_v2 TO issues_resolved_release_scope_fkey"
    )
  end

  def down do
    execute("SET lock_timeout = '3s'")

    execute("""
    ALTER TABLE issues
      ADD CONSTRAINT issues_resolved_release_scope_fkey_v2
        FOREIGN KEY (org_id, project_id, resolved_in_release_id)
        REFERENCES releases (org_id, project_id, id)
        ON DELETE SET NULL NOT VALID
    """)

    execute("ALTER TABLE issues VALIDATE CONSTRAINT issues_resolved_release_scope_fkey_v2")
    execute("ALTER TABLE issues DROP CONSTRAINT issues_resolved_release_scope_fkey")

    execute(
      "ALTER TABLE issues RENAME CONSTRAINT issues_resolved_release_scope_fkey_v2 TO issues_resolved_release_scope_fkey"
    )
  end
end
