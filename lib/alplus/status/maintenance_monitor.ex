defmodule Alplus.Status.MaintenanceMonitor do
  @moduledoc "A project-scoped Monitor link for one scheduled maintenance window."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Status,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "status_maintenance_monitors"
    repo Alplus.Repo

    identity_index_names maintenance_monitor: "status_maintenance_monitors_identity"

    references do
      reference :maintenance,
        name: "status_maintenance_monitors_maintenance_tenant_fkey",
        on_delete: :delete,
        match_with: [org_id: :org_id, project_id: :project_id]

      reference :monitor,
        name: "status_maintenance_monitors_monitor_tenant_fkey",
        on_delete: :delete,
        match_with: [org_id: :org_id, project_id: :project_id]

      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :link do
      primary? true
      accept [:maintenance_id, :monitor_id, :org_id, :project_id]
      upsert? true
      upsert_identity :maintenance_monitor
      upsert_fields []

      change {Alplus.Status.Changes.RelationshipInScope,
              resource: Alplus.Status.ScheduledMaintenance, attribute: :maintenance_id}

      change {Alplus.Status.Changes.RelationshipInScope,
              resource: Alplus.Monitoring.Monitor, attribute: :monitor_id}
    end

    destroy :unlink do
      primary? true
    end
  end

  policies do
    policy action(:read) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action([:link, :unlink]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end
  end

  attributes do
    attribute :maintenance_id, Alplus.Id,
      constraints: [prefix: "mw"],
      primary_key?: true,
      allow_nil?: false,
      public?: true

    attribute :monitor_id, Alplus.Id,
      constraints: [prefix: "mon"],
      primary_key?: true,
      allow_nil?: false,
      public?: true

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    attribute :paused_by_maintenance, :boolean, allow_nil?: false, default: false, public?: true
  end

  relationships do
    belongs_to :maintenance, Alplus.Status.ScheduledMaintenance,
      source_attribute: :maintenance_id,
      define_attribute?: false,
      allow_nil?: false

    belongs_to :monitor, Alplus.Monitoring.Monitor,
      source_attribute: :monitor_id,
      define_attribute?: false,
      allow_nil?: false

    belongs_to :organization, Alplus.Orgs.Organization,
      source_attribute: :org_id,
      define_attribute?: false,
      allow_nil?: false

    belongs_to :project, Alplus.Projects.Project,
      source_attribute: :project_id,
      define_attribute?: false,
      allow_nil?: false
  end

  identities do
    identity :maintenance_monitor, [:maintenance_id, :monitor_id]
  end
end
