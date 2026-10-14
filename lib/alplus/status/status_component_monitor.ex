defmodule Alplus.Status.StatusComponentMonitor do
  @moduledoc "A project-scoped Monitor link for one customer-facing Status service."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Status,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "status_component_monitors"
    repo Alplus.Repo

    identity_index_names component_monitor: "status_component_monitors_identity"

    references do
      reference :status_component,
        name: "status_component_monitors_component_tenant_fkey",
        on_delete: :delete,
        match_with: [org_id: :org_id, project_id: :project_id]

      reference :monitor,
        name: "status_component_monitors_monitor_tenant_fkey",
        on_delete: :delete,
        match_with: [org_id: :org_id, project_id: :project_id]

      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :for_monitor do
      argument :monitor_id, :string, allow_nil?: false

      filter expr(
               monitor_id == ^arg(:monitor_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id)
             )
    end

    read :for_component do
      argument :status_component_id, :string, allow_nil?: false

      filter expr(
               status_component_id == ^arg(:status_component_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id)
             )
    end

    create :link do
      primary? true
      accept [:status_component_id, :monitor_id, :org_id, :project_id]
      upsert? true
      upsert_identity :component_monitor
      upsert_fields []

      change {Alplus.Status.Changes.RelationshipInScope,
              resource: Alplus.Status.StatusComponent, attribute: :status_component_id}

      change {Alplus.Status.Changes.RelationshipInScope,
              resource: Alplus.Monitoring.Monitor, attribute: :monitor_id}
    end

    destroy :unlink do
      primary? true
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action_type([:create, :destroy]) do
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
    attribute :status_component_id, Alplus.Id,
      constraints: [prefix: "scomp"],
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
  end

  relationships do
    belongs_to :status_component, Alplus.Status.StatusComponent,
      source_attribute: :status_component_id,
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
    identity :component_monitor, [:status_component_id, :monitor_id]
  end
end
