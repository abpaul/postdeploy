defmodule Alplus.Mcp.OAuthRefreshToken do
  @moduledoc """
  Long-lived MCP OAuth refresh token. The raw `mcort_*` secret is returned
  once in action metadata; only the hash and prefix are persisted.
  Tokens expire after 30 days and rotate at most once.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Mcp,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "mcp_oauth_refresh_tokens"
    repo Alplus.Repo

    references do
      reference :grant, on_delete: :delete
      reference :rotated_from, on_delete: :nilify
    end

    custom_statements do
      statement :token_hash_format do
        up "ALTER TABLE mcp_oauth_refresh_tokens ADD CONSTRAINT mcp_oauth_refresh_tokens_token_hash_check CHECK (token_hash ~ '^[0-9a-f]{64}$')"

        down "ALTER TABLE mcp_oauth_refresh_tokens DROP CONSTRAINT mcp_oauth_refresh_tokens_token_hash_check"
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
      accept [:grant_id, :resource, :scopes, :rotated_from_id]
      change Alplus.Mcp.OAuthRefreshToken.Changes.Issue
      metadata :token, :string, allow_nil?: false
    end

    update :rotate do
      accept []
      require_atomic? false
      filter expr(is_nil(rotated_at) and is_nil(revoked_at))
      validate negate(present(:rotated_at))
      validate negate(present(:revoked_at))
      change set_attribute(:rotated_at, &DateTime.utc_now/0)
    end

    update :revoke do
      accept []
      require_atomic? false
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
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
      constraints prefix: "mcort"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate("mcort") end
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

    attribute :rotated_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :rotated_from_id, Alplus.Id do
      constraints prefix: "mcort"
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
    belongs_to :grant, Alplus.Mcp.OAuthGrant do
      source_attribute :grant_id
      define_attribute? false
      allow_nil? false
    end

    belongs_to :rotated_from, Alplus.Mcp.OAuthRefreshToken do
      source_attribute :rotated_from_id
      define_attribute? false
      allow_nil? true
    end
  end

  identities do
    identity :unique_token_prefix, [:token_prefix]
  end
end
