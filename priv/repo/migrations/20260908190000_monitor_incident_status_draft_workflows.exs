defmodule Alplus.Repo.Migrations.MonitorIncidentStatusDraftWorkflows do
  use Ecto.Migration

  def up do
    create table(:monitor_incident_status_draft_workflows, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, references(:organizations, type: :string, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false
      add :monitor_id, references(:monitors, type: :string, on_delete: :delete_all), null: false
      add :incident_id, references(:incidents, type: :string, on_delete: :delete_all), null: false

      add :status_page_id,
          references(:status_pages, type: :string, on_delete: :delete_all),
          null: false

      add :state, :string, null: false, default: "pending"
      add :attempt_count, :integer, null: false, default: 0
      add :failure_reason, :text
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(
             :monitor_incident_status_draft_workflows,
             :monitor_incident_status_draft_workflows_state_check,
             check: "state IN ('pending', 'delivered', 'failed')"
           )

    create constraint(
             :monitor_incident_status_draft_workflows,
             :monitor_incident_status_draft_workflows_failure_reason_length_check,
             check: "failure_reason IS NULL OR octet_length(failure_reason) <= 2048"
           )

    create unique_index(
             :monitor_incident_status_draft_workflows,
             [:org_id, :project_id, :monitor_id, :incident_id, :status_page_id],
             name: :monitor_incident_status_draft_workflows_identity
           )

    create index(:monitor_incident_status_draft_workflows, [:org_id])
    create index(:monitor_incident_status_draft_workflows, [:project_id])
    create index(:monitor_incident_status_draft_workflows, [:monitor_id])
    create index(:monitor_incident_status_draft_workflows, [:incident_id])
    create index(:monitor_incident_status_draft_workflows, [:status_page_id])
  end

  def down do
    drop_if_exists index(:monitor_incident_status_draft_workflows, [:status_page_id])
    drop_if_exists index(:monitor_incident_status_draft_workflows, [:incident_id])
    drop_if_exists index(:monitor_incident_status_draft_workflows, [:monitor_id])
    drop_if_exists index(:monitor_incident_status_draft_workflows, [:project_id])
    drop_if_exists index(:monitor_incident_status_draft_workflows, [:org_id])

    drop_if_exists index(
                     :monitor_incident_status_draft_workflows,
                     [:org_id, :project_id, :monitor_id, :incident_id, :status_page_id],
                     name: :monitor_incident_status_draft_workflows_identity
                   )

    drop table(:monitor_incident_status_draft_workflows)
  end
end
