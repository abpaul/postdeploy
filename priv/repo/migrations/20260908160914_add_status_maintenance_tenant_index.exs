defmodule Alplus.Repo.Migrations.AddStatusMaintenanceTenantIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("SET lock_timeout = '0'")
    drop_invalid_index!("status_maintenances_tenant_identity")

    execute """
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS status_maintenances_tenant_identity
      ON status_scheduled_maintenances (id, org_id, project_id)
    """
  end

  def down do
    execute("SET lock_timeout = '0'")
    execute("DROP INDEX CONCURRENTLY IF EXISTS status_maintenances_tenant_identity")
  end

  defp drop_invalid_index!(index_name) do
    invalid? =
      repo().query!(
        """
        SELECT NOT index_row.indisvalid
        FROM pg_index AS index_row
        INNER JOIN pg_class AS index_class ON index_class.oid = index_row.indexrelid
        INNER JOIN pg_namespace AS index_schema ON index_schema.oid = index_class.relnamespace
        WHERE index_schema.nspname = current_schema() AND index_class.relname = $1
        """,
        [index_name]
      ).rows == [[true]]

    if invalid? do
      execute("DROP INDEX CONCURRENTLY #{index_name}")
    end
  end
end
