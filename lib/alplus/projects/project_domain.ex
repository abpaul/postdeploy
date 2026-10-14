defmodule Alplus.Projects.ProjectDomain do
  @moduledoc "A registered browser origin for one project's Measure ingestion."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Projects,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "project_domains"
    repo Alplus.Repo

    custom_statements do
      statement :project_domain_checks do
        up """
        ALTER TABLE project_domains
          ADD CONSTRAINT project_domains_hostname_check CHECK (
            octet_length(hostname) BETWEEN 1 AND 255 AND
            hostname <> '*' AND
            hostname !~ '[[:space:]/:]'
          )
        """

        down "ALTER TABLE project_domains DROP CONSTRAINT project_domains_hostname_check"
      end
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :list_for_project do
      argument :project_id, :string, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id == ^arg(:project_id))
    end

    read :exists_for_projects do
      argument :project_ids, {:array, :string}, allow_nil?: false
      filter expr(org_id == ^actor(:org_id) and project_id in ^arg(:project_ids))
    end

    create :create do
      accept [:org_id, :project_id, :hostname]
    end

    destroy :destroy do
      primary? true
    end
  end

  policies do
    policy action([:read, :list_for_project]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action(:exists_for_projects) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action_type([:create, :destroy]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       project_id == ^actor(:project_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "pdom"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:project_domain) end
    end

    attribute :org_id, Alplus.Id,
      constraints: [prefix: "organization"],
      allow_nil?: false,
      public?: true

    attribute :project_id, Alplus.Id,
      constraints: [prefix: "project"],
      allow_nil?: false,
      public?: true

    attribute :hostname, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: 255]

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
  end

  identities do
    identity :unique_hostname_per_project, [:project_id, :hostname]
  end
end
