defmodule Alplus.Mcp.OAuthGrant do
  @moduledoc """
  User consent binding an MCP OAuth client to one organization and resource.
  Legacy grants keep one pinned project. Organization grants have no stored
  project and resolve a live project for each project-scoped request.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Mcp,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "mcp_oauth_grants"
    repo Alplus.Repo

    identity_wheres_to_sql active_connection: "revoked_at IS NULL"

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :user, on_delete: :delete
      reference :oauth_client, on_delete: :delete
    end

    custom_statements do
      statement :field_caps do
        up """
        ALTER TABLE mcp_oauth_grants
          ADD CONSTRAINT mcp_oauth_grants_issuer_size_check CHECK (octet_length(issuer) <= 2048),
          ADD CONSTRAINT mcp_oauth_grants_resource_size_check CHECK (octet_length(resource) <= 2048),
          ADD CONSTRAINT mcp_oauth_grants_scopes_size_check CHECK (octet_length(scopes::text) <= 4096)
        """

        down """
        ALTER TABLE mcp_oauth_grants
          DROP CONSTRAINT mcp_oauth_grants_issuer_size_check,
          DROP CONSTRAINT mcp_oauth_grants_resource_size_check,
          DROP CONSTRAINT mcp_oauth_grants_scopes_size_check
        """
      end
    end
  end

  actions do
    defaults [:read]

    read :list do
      filter expr(is_nil(revoked_at))

      prepare build(
                load: [:oauth_client, :user, :organization, :project],
                sort: [last_used_at: :desc, inserted_at: :desc]
              )
    end

    # Activity pages need historical labels, but never grant credentials or
    # scopes. The project and id filters remain part of the action itself.
    read :list_labels do
      argument :project_id, :string, allow_nil?: false
      argument :grant_ids, {:array, :string}, allow_nil?: false

      filter expr(
               org_id == ^actor(:org_id) and
                 (project_id == ^arg(:project_id) or scope_mode == "organization") and
                 id in ^arg(:grant_ids)
             )

      prepare build(load: [:oauth_client], select: [:id, :project_id, :scope_mode])
    end

    create :authorize do
      primary? true

      accept [
        :org_id,
        :project_id,
        :scope_mode,
        :user_id,
        :oauth_client_id,
        :issuer,
        :resource,
        :scopes
      ]

      upsert? true
      upsert_identity :active_connection
      upsert_fields [:scopes]

      change {Alplus.Audit.Change,
              action: "mcp.oauth_grant.authorize",
              subject_type: "mcp_oauth_grant",
              org_id_attribute: :org_id,
              project_id_attribute: :project_id}
    end

    update :revoke do
      accept []
      require_atomic? false
      change set_attribute(:revoked_at, &DateTime.utc_now/0)

      change {Alplus.Audit.Change,
              action: "mcp.oauth_grant.revoke",
              subject_type: "mcp_oauth_grant",
              org_id_attribute: :org_id,
              project_id_attribute: :project_id}
    end

    update :touch do
      accept []
      require_atomic? false
      change set_attribute(:last_used_at, &DateTime.utc_now/0)
    end
  end

  policies do
    policy action([:read, :list, :get]) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end

    policy action(:list_labels) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       (project_id == ^actor(:project_id) or scope_mode == "organization") and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action(:authorize) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       user_id == ^actor(:user_id) and
                       (scope_mode == "organization" or
                          exists(project, org_id == ^actor(:org_id))) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end

    policy action(:revoke) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       (scope_mode == "organization" or
                          exists(project, org_id == ^actor(:org_id))) and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:user_id) and role in ["owner", "admin"]
                       )
                   )
    end

    # Token usage stamps last_used_at with `authorize?: false`.
    policy action(:touch) do
      forbid_if always()
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "mcogr"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:mcp_oauth_grant) end
    end

    attribute :org_id, Alplus.Id do
      constraints prefix: "organization"
      allow_nil? false
      public? true
    end

    attribute :project_id, Alplus.Id do
      constraints prefix: "project"
      allow_nil? true
      public? true
    end

    attribute :scope_mode, :string do
      allow_nil? false
      public? true
      default "project"
      constraints match: ~r/\A(project|organization)\z/
    end

    attribute :user_id, Alplus.Id do
      constraints prefix: "user"
      allow_nil? false
      public? true
    end

    attribute :oauth_client_id, Alplus.Id do
      constraints prefix: "mcocl"
      allow_nil? false
      public? true
    end

    attribute :issuer, :string do
      allow_nil? false
      public? true
      constraints max_length: 2048
    end

    attribute :resource, :string do
      allow_nil? false
      public? true
      constraints max_length: 2048
    end

    attribute :scopes, {:array, :string} do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 16, items: [max_length: 64]
    end

    attribute :last_used_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :revoked_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :organization, Alplus.Orgs.Organization do
      source_attribute :org_id
      define_attribute? false
      allow_nil? false
    end

    belongs_to :project, Alplus.Projects.Project do
      source_attribute :project_id
      define_attribute? false
      allow_nil? true
    end

    belongs_to :user, Alplus.Accounts.User do
      source_attribute :user_id
      define_attribute? false
      allow_nil? false
    end

    belongs_to :oauth_client, Alplus.Mcp.OAuthClient do
      source_attribute :oauth_client_id
      define_attribute? false
      allow_nil? false
    end

    has_many :authorization_codes, Alplus.Mcp.OAuthAuthorizationCode do
      destination_attribute :grant_id
    end

    has_many :access_tokens, Alplus.Mcp.OAuthAccessToken do
      destination_attribute :grant_id
    end
  end

  identities do
    identity :active_connection,
             [:org_id, :project_id, :scope_mode, :user_id, :oauth_client_id, :resource],
             where: expr(is_nil(revoked_at)),
             eager_check?: true,
             nils_distinct?: false
  end
end
