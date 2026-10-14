defmodule Alplus.Repo.Migrations.DurableMonitorIncidentStatusDrafts do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    drop_if_exists index(:status_incident_drafts, [:status_page_id, :monitor_id],
                     name: :status_incident_drafts_page_monitor_identity,
                     concurrently: true
                   )
  end

  def down do
    # Do not restore the retired uniqueness rule. A page can now retain more
    # than one draft for a monitor, one for each persisted Monitor incident.
    # Recreating it would reject a safe rollback after those rows exist.
    :ok
  end
end
