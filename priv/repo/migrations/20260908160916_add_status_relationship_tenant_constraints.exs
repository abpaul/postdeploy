defmodule Alplus.Repo.Migrations.AddStatusRelationshipTenantConstraints do
  use Ecto.Migration

  def up do
    execute("SET lock_timeout = '3s'")

    execute """
    ALTER TABLE status_component_monitors
      ADD CONSTRAINT status_component_monitors_component_tenant_fkey
      FOREIGN KEY (status_component_id, org_id, project_id)
      REFERENCES status_components (id, org_id, project_id)
      ON DELETE CASCADE NOT VALID
    """

    execute """
    ALTER TABLE status_component_monitors
      ADD CONSTRAINT status_component_monitors_monitor_tenant_fkey
      FOREIGN KEY (monitor_id, org_id, project_id)
      REFERENCES monitors (id, org_id, project_id)
      ON DELETE CASCADE NOT VALID
    """

    execute """
    ALTER TABLE status_maintenance_monitors
      ADD CONSTRAINT status_maintenance_monitors_maintenance_tenant_fkey
      FOREIGN KEY (maintenance_id, org_id, project_id)
      REFERENCES status_scheduled_maintenances (id, org_id, project_id)
      ON DELETE CASCADE NOT VALID
    """

    execute """
    ALTER TABLE status_maintenance_monitors
      ADD CONSTRAINT status_maintenance_monitors_monitor_tenant_fkey
      FOREIGN KEY (monitor_id, org_id, project_id)
      REFERENCES monitors (id, org_id, project_id)
      ON DELETE CASCADE NOT VALID
    """

    validate_constraints()
  end

  def down do
    execute("SET lock_timeout = '3s'")

    execute """
    ALTER TABLE status_maintenance_monitors
      DROP CONSTRAINT status_maintenance_monitors_monitor_tenant_fkey
    """

    execute """
    ALTER TABLE status_maintenance_monitors
      DROP CONSTRAINT status_maintenance_monitors_maintenance_tenant_fkey
    """

    execute """
    ALTER TABLE status_component_monitors
      DROP CONSTRAINT status_component_monitors_monitor_tenant_fkey
    """

    execute """
    ALTER TABLE status_component_monitors
      DROP CONSTRAINT status_component_monitors_component_tenant_fkey
    """
  end

  defp validate_constraints do
    for {table, constraint} <- [
          {:status_component_monitors, :status_component_monitors_component_tenant_fkey},
          {:status_component_monitors, :status_component_monitors_monitor_tenant_fkey},
          {:status_maintenance_monitors, :status_maintenance_monitors_maintenance_tenant_fkey},
          {:status_maintenance_monitors, :status_maintenance_monitors_monitor_tenant_fkey}
        ] do
      execute("ALTER TABLE #{table} VALIDATE CONSTRAINT #{constraint}")
    end
  end
end
