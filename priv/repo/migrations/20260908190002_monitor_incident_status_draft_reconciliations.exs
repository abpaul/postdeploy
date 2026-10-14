defmodule Alplus.Repo.Migrations.MonitorIncidentStatusDraftReconciliations do
  use Ecto.Migration

  def up do
    create table(:monitor_incident_status_draft_reconciliations, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, references(:organizations, type: :string, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false
      add :monitor_id, references(:monitors, type: :string, on_delete: :delete_all), null: false
      add :incident_id, references(:incidents, type: :string, on_delete: :delete_all), null: false
      add :state, :string, null: false, default: "pending"
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(
             :monitor_incident_status_draft_reconciliations,
             :monitor_incident_status_draft_reconciliations_state_check,
             check: "state IN ('pending', 'reconciled')"
           )

    create unique_index(:monitor_incident_status_draft_reconciliations, [:incident_id])

    create index(:monitor_incident_status_draft_reconciliations, [:inserted_at],
             where: "state = 'pending'",
             name: :monitor_incident_status_draft_reconciliations_pending_index
           )

    create index(:monitor_incident_status_draft_reconciliations, [:org_id])
    create index(:monitor_incident_status_draft_reconciliations, [:project_id])
    create index(:monitor_incident_status_draft_reconciliations, [:monitor_id])
  end

  def down do
    drop table(:monitor_incident_status_draft_reconciliations)
  end
end
