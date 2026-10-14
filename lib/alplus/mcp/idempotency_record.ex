defmodule Alplus.Mcp.IdempotencyRecord do
  @moduledoc "Seven-day organization-, project-, and grant-scoped mutation result cache."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Mcp,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "mcp_idempotency_records"
    repo Alplus.Repo

    references do
      reference :organization, on_delete: :delete
      reference :project, on_delete: :delete
    end

    custom_statements do
      statement :result_size_check do
        up "ALTER TABLE mcp_idempotency_records ADD CONSTRAINT mcp_idempotency_records_result_size_check CHECK (octet_length(result::text) <= 1048576)"

        down "ALTER TABLE mcp_idempotency_records DROP CONSTRAINT mcp_idempotency_records_result_size_check"
      end

      statement :field_caps do
        up """
        ALTER TABLE mcp_idempotency_records
          ADD CONSTRAINT mcp_idempotency_records_tool_size_check CHECK (octet_length(tool) <= 128),
          ADD CONSTRAINT mcp_idempotency_records_key_size_check CHECK (octet_length(idempotency_key) <= 256),
          ADD CONSTRAINT mcp_idempotency_records_hash_size_check CHECK (octet_length(request_hash) <= 64)
        """

        down """
        ALTER TABLE mcp_idempotency_records
          DROP CONSTRAINT mcp_idempotency_records_tool_size_check,
          DROP CONSTRAINT mcp_idempotency_records_key_size_check,
          DROP CONSTRAINT mcp_idempotency_records_hash_size_check
        """
      end
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :org_id,
        :project_id,
        :grant_id,
        :tool,
        :idempotency_key,
        :request_hash,
        :result,
        :inserted_at
      ]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end

    policy action_type(:create) do
      authorize_if expr(
                     org_id == ^actor(:org_id) and
                       exists(organization.memberships, user_id == ^actor(:user_id))
                   )
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "midm"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:mcp_idempotency_record) end
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

    # OAuth grant identity. Nil for browser-session actors.
    attribute :grant_id, Alplus.Id do
      constraints prefix: "mcogr"
      allow_nil? true
      public? true
    end

    attribute :tool, :string do
      allow_nil? false
      public? true
      constraints max_length: 120
    end

    attribute :idempotency_key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200
    end

    attribute :request_hash, :string do
      allow_nil? false
      public? false
      sensitive? true
      constraints min_length: 64, max_length: 64
    end

    attribute :result, :map do
      allow_nil? false
      public? false
      sensitive? true
    end

    attribute :inserted_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      default &DateTime.utc_now/0
    end
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
  end

  identities do
    identity :unique_org_project_tool_key,
             [:org_id, :project_id, :tool, :idempotency_key, :grant_id],
             nils_distinct?: false
  end
end
