defmodule Alplus.Mcp.Confirmation do
  @moduledoc "Durable approval record for destructive MCP actions."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Mcp,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  postgres do
    table "mcp_confirmations"
    repo Alplus.Repo

    custom_indexes do
      index [:org_id, :project_id, :status, :expires_at]
    end

    custom_statements do
      statement :confirmation_constraints do
        up """
        ALTER TABLE mcp_confirmations
          ADD CONSTRAINT mcp_confirmations_status_check CHECK (status IN ('pending', 'approved', 'rejected', 'expired', 'failed')),
          ADD CONSTRAINT mcp_confirmations_action_check CHECK (octet_length(btrim(action)) BETWEEN 1 AND 200),
          ADD CONSTRAINT mcp_confirmations_idempotency_key_check CHECK (octet_length(btrim(idempotency_key)) BETWEEN 1 AND 256),
          ADD CONSTRAINT mcp_confirmations_error_check CHECK (error IS NULL OR octet_length(error) <= 2048),
          ADD CONSTRAINT mcp_confirmations_expiry_check CHECK (expires_at > requested_at),
          ADD CONSTRAINT mcp_confirmations_terminal_timestamps_check CHECK (
            (status = 'pending' AND approved_at IS NULL AND rejected_at IS NULL AND execution_started_at IS NULL AND execution_finished_at IS NULL)
            OR status <> 'pending'
          )
        """

        down """
        ALTER TABLE mcp_confirmations
          DROP CONSTRAINT mcp_confirmations_terminal_timestamps_check,
          DROP CONSTRAINT mcp_confirmations_expiry_check,
          DROP CONSTRAINT mcp_confirmations_error_check,
          DROP CONSTRAINT mcp_confirmations_idempotency_key_check,
          DROP CONSTRAINT mcp_confirmations_action_check,
          DROP CONSTRAINT mcp_confirmations_status_check
        """
      end
    end

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
      reference :user, on_delete: :delete
      reference :oauth_grant, on_delete: :nilify
    end
  end

  cloak do
    vault(Alplus.NotificationsVault)
    attributes([:arguments, :result])
  end

  actions do
    defaults [:read]

    read :list_for_project do
      argument :project_id, :string, allow_nil?: false

      filter expr(
               org_id == ^actor(:org_id) and project_id == ^arg(:project_id) and
                 exists(organization.memberships, user_id == ^actor(:user_id))
             )

      prepare build(sort: [requested_at: :desc])
    end

    create :request do
      primary? true

      accept [
        :org_id,
        :project_id,
        :grant_id,
        :user_id,
        :principal_source,
        :scopes,
        :action,
        :arguments,
        :idempotency_key,
        :requested_at,
        :expires_at,
        :correlation_id
      ]
    end

    update :transition do
      accept [
        :status,
        :approved_at,
        :rejected_at,
        :execution_started_at,
        :execution_finished_at,
        :arguments,
        :result,
        :error
      ]

      require_atomic? false
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action(:request) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and project_id == ^actor(:project_id) and
                       user_id == ^actor(:user_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action(:transition) do
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
      constraints prefix: "mconf"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:mcp_confirmation) end
    end

    attribute :org_id, Alplus.Id do
      constraints prefix: "organization"
      allow_nil? false
      public? true
    end

    attribute :project_id, Alplus.Id do
      constraints prefix: "project"
      allow_nil? false
      public? true
    end

    attribute :grant_id, Alplus.Id do
      constraints prefix: "mcogr"
      allow_nil? true
      public? false
    end

    attribute :user_id, Alplus.Id do
      constraints prefix: "user"
      allow_nil? false
      public? false
    end

    attribute :principal_source, :string do
      allow_nil? false
      default "oauth"
      public? false
    end

    attribute :scopes, {:array, :string} do
      allow_nil? false
      default []
      public? false
    end

    attribute :action, :string do
      allow_nil? false
      public? true
      constraints max_length: 200
    end

    attribute :idempotency_key, :string do
      allow_nil? false
      public? false
      sensitive? true
      constraints min_length: 1, max_length: 256
    end

    attribute :arguments, :map do
      allow_nil? false
      public? false
      sensitive? true
    end

    attribute :status, :string do
      allow_nil? false
      default "pending"
      public? true
    end

    attribute :requested_at, :utc_datetime_usec do
      allow_nil? false
      default &DateTime.utc_now/0
      public? true
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :approved_at, :utc_datetime_usec, allow_nil?: true, public?: false
    attribute :rejected_at, :utc_datetime_usec, allow_nil?: true, public?: false
    attribute :execution_started_at, :utc_datetime_usec, allow_nil?: true, public?: false
    attribute :execution_finished_at, :utc_datetime_usec, allow_nil?: true, public?: false

    attribute :result, :map do
      allow_nil? true
      public? false
      sensitive? true
    end

    attribute :error, :string do
      allow_nil? true
      public? false
      sensitive? true
      constraints max_length: 2048
    end

    attribute :correlation_id, :string do
      allow_nil? false
      public? false
      constraints max_length: 120
    end

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

    belongs_to :user, Alplus.Accounts.User,
      source_attribute: :user_id,
      define_attribute?: false,
      allow_nil?: false

    belongs_to :oauth_grant, Alplus.Mcp.OAuthGrant,
      source_attribute: :grant_id,
      define_attribute?: false,
      allow_nil?: true
  end

  identities do
    identity :principal_action_key,
             [:org_id, :project_id, :grant_id, :user_id, :action, :idempotency_key],
             nils_distinct?: false
  end
end
