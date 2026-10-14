defmodule Alplus.Mcp.OAuthAuthorizationCode do
  @moduledoc """
  Short-lived MCP OAuth authorization code. The raw `mcoac_*` secret is
  returned once in action metadata; only the hash and prefix are persisted.
  Codes expire after 60 seconds and are single-use.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Mcp,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "mcp_oauth_authorization_codes"
    repo Alplus.Repo

    references do
      reference :grant, on_delete: :delete
      reference :oauth_client, on_delete: :delete
    end

    custom_statements do
      statement :code_hash_format do
        up "ALTER TABLE mcp_oauth_authorization_codes ADD CONSTRAINT mcp_oauth_authorization_codes_code_hash_check CHECK (code_hash ~ '^[0-9a-f]{64}$')"

        down "ALTER TABLE mcp_oauth_authorization_codes DROP CONSTRAINT mcp_oauth_authorization_codes_code_hash_check"
      end
    end
  end

  actions do
    defaults [:read]

    read :get_by_prefix do
      get? true
      argument :prefix, :string, allow_nil?: false
      filter expr(code_prefix == ^arg(:prefix))
    end

    create :issue do
      primary? true
      accept [:grant_id, :oauth_client_id, :redirect_uri, :resource, :scopes, :code_challenge]
      change Alplus.Mcp.OAuthAuthorizationCode.Changes.Issue
      metadata :code, :string, allow_nil?: false
    end

    update :consume do
      accept []
      require_atomic? false
      filter expr(is_nil(consumed_at))
      validate negate(present(:consumed_at))
      change set_attribute(:consumed_at, &DateTime.utc_now/0)
    end
  end

  policies do
    # Token, code, and client actions are system-only and called with
    # `authorize?: false`. Actor-facing access is denied.
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "mcoac"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate("mcoac") end
    end

    attribute :grant_id, Alplus.Id do
      constraints prefix: "mcogr"
      allow_nil? false
      public? true
    end

    attribute :oauth_client_id, Alplus.Id do
      constraints prefix: "mcocl"
      allow_nil? false
      public? true
    end

    attribute :code_hash, :string do
      allow_nil? false
      writable? false
      public? false
      sensitive? true
    end

    attribute :code_prefix, :string do
      allow_nil? false
      writable? false
      public? false
      sensitive? true
      constraints min_length: 8, max_length: 8
    end

    attribute :redirect_uri, :string do
      allow_nil? false
      public? true
    end

    attribute :resource, :string do
      allow_nil? false
      public? true
    end

    attribute :scopes, {:array, :string} do
      allow_nil? false
      public? true
    end

    attribute :code_challenge, :string do
      allow_nil? false
      public? true
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      public? true
    end

    attribute :consumed_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :grant, Alplus.Mcp.OAuthGrant do
      source_attribute :grant_id
      define_attribute? false
      allow_nil? false
    end

    belongs_to :oauth_client, Alplus.Mcp.OAuthClient do
      source_attribute :oauth_client_id
      define_attribute? false
      allow_nil? false
    end
  end

  identities do
    identity :unique_code_prefix, [:code_prefix]
  end
end
