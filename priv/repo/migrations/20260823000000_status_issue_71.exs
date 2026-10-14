defmodule Alplus.Repo.Migrations.StatusIssue71 do
  use Ecto.Migration

  def up do
    alter table(:status_incidents) do
      add :stage, :string, null: false, default: "investigating"
      add :next_update_at, :utc_datetime_usec
      add :is_private, :boolean, null: false, default: false
      modify :published_at, :utc_datetime_usec, null: true
    end

    create constraint(:status_incidents, :status_incidents_stage_check,
             check: "stage IN ('investigating', 'identified', 'monitoring', 'resolved')"
           )

    create table(:status_incident_services, primary_key: false) do
      add :status_incident_id,
          references(:status_incidents, type: :string, on_delete: :delete_all),
          null: false

      add :status_component_id,
          references(:status_components, type: :string, on_delete: :restrict),
          null: false

      add :org_id, references(:organizations, type: :string, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false
      add :state, :string, null: false, default: "outage"
    end

    create unique_index(:status_incident_services, [:status_incident_id, :status_component_id],
             name: :status_incident_services_identity
           )

    create index(:status_incident_services, [:org_id, :project_id, :status_component_id])

    create constraint(:status_incident_services, :status_incident_services_state_check,
             check: "state IN ('outage', 'degraded', 'maintenance', 'operational')"
           )

    create table(:status_announcements, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, references(:organizations, type: :string, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false

      add :status_page_id,
          references(:status_pages, type: :string, on_delete: :delete_all),
          null: false

      add :title, :string, null: false
      add :body, :text, null: false
      add :published_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec
      add :removed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:status_announcements, [:status_page_id, :published_at])
    create index(:status_announcements, [:org_id, :project_id, :removed_at, :expires_at])

    create constraint(:status_announcements, :status_announcements_title_check,
             check: "octet_length(btrim(title)) BETWEEN 1 AND 200"
           )

    create constraint(:status_announcements, :status_announcements_body_check,
             check: "octet_length(body) BETWEEN 1 AND 32768"
           )

    create constraint(:status_announcements, :status_announcements_window_check,
             check: "expires_at IS NULL OR expires_at > published_at"
           )

    create table(:status_incident_drafts, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, references(:organizations, type: :string, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false

      add :status_page_id,
          references(:status_pages, type: :string, on_delete: :delete_all),
          null: false

      add :monitor_id, references(:monitors, type: :string, on_delete: :delete_all), null: true

      add :status_incident_id,
          references(:status_incidents, type: :string, on_delete: :delete_all),
          null: true

      add :title, :string, null: false, default: "Service disruption"
      add :body, :text, null: false, default: "We are investigating the issue."
      add :suggested_service_ids, {:array, :string}, null: false, default: []
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:status_incident_drafts, :status_incident_drafts_title_check,
             check: "octet_length(btrim(title)) BETWEEN 1 AND 200"
           )

    create constraint(:status_incident_drafts, :status_incident_drafts_body_check,
             check: "octet_length(body) BETWEEN 1 AND 32768"
           )

    create unique_index(:status_incident_drafts, [:status_page_id, :monitor_id],
             name: :status_incident_drafts_page_monitor_identity,
             where: "monitor_id IS NOT NULL"
           )

    create unique_index(:status_incident_drafts, [:status_incident_id],
             name: :status_incident_drafts_incident_identity,
             where: "status_incident_id IS NOT NULL"
           )

    create index(:status_incident_drafts, [:org_id, :project_id, :status_page_id])
  end

  def down do
    drop table(:status_incident_drafts)
    drop table(:status_announcements)
    drop table(:status_incident_services)

    alter table(:status_incidents) do
      remove :stage
      remove :next_update_at
      remove :is_private
      modify :published_at, :utc_datetime_usec, null: false
    end
  end
end
