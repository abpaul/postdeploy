defmodule Alplus.Repo.Migrations.ReconcileStatusDraftWorkflowFailureReasonConstraint do
  use Ecto.Migration

  @constraint "monitor_status_draft_workflow_failure_reason_length_check"

  def up do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = '#{@constraint}'
          AND conrelid = 'monitor_incident_status_draft_workflows'::regclass
      ) THEN
        ALTER TABLE monitor_incident_status_draft_workflows
          ADD CONSTRAINT #{@constraint}
          CHECK (failure_reason IS NULL OR octet_length(failure_reason) <= 2048)
          NOT VALID;
      END IF;
    END $$;
    """)

    execute("""
    ALTER TABLE monitor_incident_status_draft_workflows
      VALIDATE CONSTRAINT #{@constraint}
    """)
  end

  def down do
    execute("""
    ALTER TABLE monitor_incident_status_draft_workflows
      DROP CONSTRAINT IF EXISTS #{@constraint}
    """)
  end
end
