defmodule Alplus.Mcp.OAuthAccessToken do
  @moduledoc """
  Short-lived MCP OAuth access token. The raw `mcoat_*` secret is returned
  once in action metadata; only the hash and prefix are persisted.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Mcp,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "mcp_oauth_access_tokens"
    repo Alplus.Repo

    references do
      reference :grant, on_delete: :delete
    end

    custom_statements do
      statement :token_hash_format do
        up "ALTER TABLE mcp_oauth_access_tokens ADD CONSTRAINT mcp_oauth_access_tokens_token_hash_check CHECK (token_hash ~ '^[0-9a-f]{64}$')"

        down "ALTER TABLE mcp_oauth_access_tokens DROP CONSTRAINT mcp_oauth_access_tokens_token_hash_check"
      end
    end
  end

  actions do
    defaults [:read]

    read :get_by_prefix do
      get? true
      argument :prefix, :string, allow_nil?: false
      filter expr(token_prefix == ^arg(:prefix))
    end

    create :issue do
      primary? true
      accept [:grant_id, :resource, :scopes]
      change Alplus.Mcp.OAuthAccessToken.Changes.Issue
      metadata :token, :string, allow_nil?: false
    end

    update :revoke do
      accept []
      require_atomic? false
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
    end

    update :touch do
      accept []
      require_atomic? false
      change set_attribute(:last_used_at, &DateTime.utc_now/0)
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
      constraints prefix: "mcoat"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate("mcoat") end
    end

    attribute :grant_id, Alplus.Id do
      constraints prefix: "mcogr"
      allow_nil? false
      public? true
    end

    attribute :token_hash, :string do
      allow_nil? false
      writable? false
      public? false
      sensitive? true
    end

    attribute :token_prefix, :string do
      allow_nil? false
      writable? false
      public? true
      constraints min_length: 8, max_length: 8
    end

    attribute :resource, :string do
      allow_nil? false
      public? true
    end

    attribute :scopes, {:array, :string} do
      allow_nil? false
      public? true
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      public? true
    end

    attribute :revoked_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_used_at, :utc_datetime_usec do
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
  end

  identities do
    identity :unique_token_prefix, [:token_prefix]
  end
end
