defmodule Alplus.Status.StatusPage do
  @moduledoc "The one project-owned Status workspace. Public identity lives in PublicPages."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Status,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "status_pages"
    repo Alplus.Repo

    custom_indexes do
      index [:org_id, :project_id]
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :get_by_slug do
      get? true
      argument :status_slug, :string, allow_nil?: false
      filter expr(project_id == ^actor(:project_id))
    end

    read :read_public do
      get? true

      filter expr(
               id == ^actor(:status_page_id) and org_id == ^actor(:org_id) and
                 project_id == ^actor(:project_id)
             )
    end

    read :public_by_slug do
      get? true
      argument :status_slug, :string, allow_nil?: false
      filter expr(project_id == ^actor(:project_id))
    end

    read :public_for_project do
      get? true
      argument :project_id, :string, allow_nil?: false
      filter expr(project_id == ^arg(:project_id))
    end

    create :create do
      primary? true
      accept [:org_id, :project_id]

      change {Alplus.Audit.Change,
              action: "status_page.create",
              subject_type: "status_page",
              project_id_attribute: :project_id}
    end

    # Used by the atomic first-run setup flow. The caller records the audit
    # event after the surrounding transaction commits, so this action is safe
    # inside that transaction and does not register a nested hook.
    create :create_internal do
      accept [:org_id, :project_id]
    end

    update :update do
      primary? true
      accept []
      require_atomic? false

      change {Alplus.Audit.Change,
              action: "status_page.update",
              subject_type: "status_page",
              project_id_attribute: :project_id}
    end

    update :publish do
      accept []
      require_atomic? false

      change {Alplus.Audit.Change,
              action: "status_page.publish",
              subject_type: "status_page",
              project_id_attribute: :project_id}
    end

    update :unpublish do
      accept []
      require_atomic? false

      change {Alplus.Audit.Change,
              action: "status_page.unpublish",
              subject_type: "status_page",
              project_id_attribute: :project_id}
    end
  end

  policies do
    policy action(:read_public) do
      authorize_if expr(
                     id == ^actor(:status_page_id) and org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id)
                   )
    end

    policy action(:public_by_slug) do
      authorize_if expr(project_id == ^actor(:project_id))
    end

    policy action(:public_for_project) do
      authorize_if expr(project_id == ^actor(:project_id))
    end

    policy action([:read, :get_by_slug]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action_type([:create, :update]) do
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
    attribute :id, Alplus.Id do
      constraints prefix: "sp"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:status_page) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :organization, Alplus.Orgs.Organization,
      source_attribute: :org_id,
      define_attribute?: false,
      allow_nil?: false

    belongs_to :project, Alplus.Projects.Project,
      source_attribute: :project_id,
      define_attribute?: false,
      allow_nil?: false

    has_many :components, Alplus.Status.StatusComponent, destination_attribute: :status_page_id
    has_many :incidents, Alplus.Status.StatusIncident, destination_attribute: :status_page_id

    has_many :scheduled_maintenances, Alplus.Status.ScheduledMaintenance,
      destination_attribute: :status_page_id

    has_one :public_page, Alplus.PublicPages.PublicPage,
      source_attribute: :project_id,
      destination_attribute: :project_id
  end
end
