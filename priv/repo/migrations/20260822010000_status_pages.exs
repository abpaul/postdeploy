defmodule Alplus.Repo.Migrations.StatusPages do
  use Ecto.Migration

  def change do
    create table(:status_pages, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, references(:organizations, type: :string, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false
      add :status_slug, :string, null: false
      add :title, :string, null: false
      add :logo_url, :string
      add :published_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:status_pages, [:status_slug], name: :status_pages_slug_index)
    create index(:status_pages, [:org_id, :project_id])

    create constraint(:status_pages, :status_pages_slug_check,
             check: "octet_length(status_slug) BETWEEN 1 AND 63"
           )

    create constraint(:status_pages, :status_pages_title_check,
             check: "octet_length(btrim(title)) BETWEEN 1 AND 200"
           )

    create constraint(:status_pages, :status_pages_logo_url_check,
             check: "logo_url IS NULL OR octet_length(logo_url) <= 2048"
           )

    create table(:status_components, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, references(:organizations, type: :string, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false

      add :status_page_id, references(:status_pages, type: :string, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :position, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create index(:status_components, [:status_page_id, :position])
    create index(:status_components, [:org_id, :project_id])

    create constraint(:status_components, :status_components_name_check,
             check: "octet_length(btrim(name)) BETWEEN 1 AND 200"
           )

    create constraint(:status_components, :status_components_position_check,
             check: "position >= 0"
           )

    create table(:status_component_monitors, primary_key: false) do
      add :status_component_id,
          references(:status_components, type: :string, on_delete: :delete_all), null: false

      add :monitor_id, references(:monitors, type: :string, on_delete: :delete_all), null: false
      add :org_id, references(:organizations, type: :string, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false
    end

    create unique_index(:status_component_monitors, [:status_component_id, :monitor_id],
             name: :status_component_monitors_identity
           )

    create index(:status_component_monitors, [:org_id, :project_id, :monitor_id])

    create table(:status_incidents, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, references(:organizations, type: :string, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false

      add :status_page_id, references(:status_pages, type: :string, on_delete: :delete_all),
        null: false

      add :incident_id, references(:incidents, type: :string, on_delete: :nilify_all)
      add :title, :string, null: false
      add :body, :text, null: false
      add :status, :string, null: false, default: "open"
      add :published_at, :utc_datetime_usec, null: false
      add :closed_at, :utc_datetime_usec
      add :closed_by_id, references(:users, type: :string, on_delete: :nilify_all)
      add :recovery_posted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:status_incidents, [:status_page_id, :published_at])
    create index(:status_incidents, [:org_id, :project_id, :status])

    create constraint(:status_incidents, :status_incidents_title_check,
             check: "octet_length(btrim(title)) BETWEEN 1 AND 200"
           )

    create constraint(:status_incidents, :status_incidents_body_check,
             check: "octet_length(body) BETWEEN 1 AND 32768"
           )

    create constraint(:status_incidents, :status_incidents_status_check,
             check: "status IN ('open', 'closed')"
           )

    create table(:status_incident_updates, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, references(:organizations, type: :string, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false

      add :status_incident_id,
          references(:status_incidents, type: :string, on_delete: :delete_all), null: false

      add :body, :text, null: false
      add :kind, :string, null: false, default: "note"
      add :actor_id, references(:users, type: :string, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create index(:status_incident_updates, [:status_incident_id, :inserted_at])
    create index(:status_incident_updates, [:org_id, :project_id])

    create constraint(:status_incident_updates, :status_incident_updates_body_check,
             check: "octet_length(body) BETWEEN 1 AND 32768"
           )

    create table(:status_scheduled_maintenances, primary_key: false) do
      add :id, :string, primary_key: true
      add :org_id, references(:organizations, type: :string, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false

      add :status_page_id, references(:status_pages, type: :string, on_delete: :delete_all),
        null: false

      add :title, :string, null: false
      add :description, :text
      add :starts_at, :utc_datetime_usec, null: false
      add :ends_at, :utc_datetime_usec, null: false
      add :status, :string, null: false, default: "scheduled"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:status_scheduled_maintenances, [:status_page_id, :starts_at])
    create index(:status_scheduled_maintenances, [:org_id, :project_id, :status, :starts_at])

    create constraint(:status_scheduled_maintenances, :status_maintenance_title_check,
             check: "octet_length(btrim(title)) BETWEEN 1 AND 200"
           )

    create constraint(:status_scheduled_maintenances, :status_maintenance_description_check,
             check: "description IS NULL OR octet_length(description) <= 32768"
           )

    create constraint(:status_scheduled_maintenances, :status_maintenance_status_check,
             check: "status IN ('scheduled', 'active', 'completed', 'cancelled')"
           )

    create constraint(:status_scheduled_maintenances, :status_maintenance_window_check,
             check: "starts_at < ends_at"
           )

    create table(:status_maintenance_monitors, primary_key: false) do
      add :maintenance_id,
          references(:status_scheduled_maintenances, type: :string, on_delete: :delete_all),
          null: false

      add :monitor_id, references(:monitors, type: :string, on_delete: :delete_all), null: false
      add :org_id, references(:organizations, type: :string, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false
    end

    create unique_index(:status_maintenance_monitors, [:maintenance_id, :monitor_id],
             name: :status_maintenance_monitors_identity
           )

    create index(:status_maintenance_monitors, [:org_id, :project_id, :monitor_id])
  end
end
