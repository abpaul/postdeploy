defmodule Alplus.Repo.Migrations.AutomationAuditIdentity do
  use Ecto.Migration

  def up do
    alter table(:audit_logs) do
      modify :actor_id, :string, null: true
    end

    execute """
    ALTER TABLE audit_logs
      DROP CONSTRAINT IF EXISTS audit_logs_actor_identity_check,
      DROP CONSTRAINT audit_logs_actor_kind_check,
      ADD CONSTRAINT audit_logs_actor_kind_check CHECK (actor_kind IN ('user', 'agent', 'system')),
      ADD CONSTRAINT audit_logs_actor_identity_check CHECK (
        (actor_kind = 'system' AND actor_id IS NULL) OR
        (actor_kind IN ('user', 'agent') AND actor_id IS NOT NULL)
      ),
      DROP CONSTRAINT audit_logs_transport_check,
      ADD CONSTRAINT audit_logs_transport_check CHECK (transport IN ('session', 'remote_mcp', 'webmcp', 'automation'))
    """
  end

  def down do
    # Preserve system audit rows. Restoring the old non-null actor contract
    # would reject a safe rollback after automated drafts exist.
    :ok
  end
end
