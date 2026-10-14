defmodule Alplus.Mcp.OAuthClient do
  @moduledoc """
  Cached CIMD client metadata. Issuer, client id, and redirect URIs are
  immutable snapshots of the last successful fetch; `:cache` upserts on
  `(issuer, client_id)`. System callers use `authorize?: false`.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Mcp,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "mcp_oauth_clients"
    repo Alplus.Repo

    custom_statements do
      statement :field_caps do
        up """
        ALTER TABLE mcp_oauth_clients
          ADD CONSTRAINT mcp_oauth_clients_issuer_size_check CHECK (octet_length(issuer) <= 2048),
          ADD CONSTRAINT mcp_oauth_clients_client_id_size_check CHECK (octet_length(client_id) <= 2048),
          ADD CONSTRAINT mcp_oauth_clients_client_name_size_check CHECK (client_name IS NULL OR octet_length(client_name) <= 256),
          ADD CONSTRAINT mcp_oauth_clients_redirect_uris_size_check CHECK (octet_length(redirect_uris::text) <= 16384)
        """

        down """
        ALTER TABLE mcp_oauth_clients
          DROP CONSTRAINT mcp_oauth_clients_issuer_size_check,
          DROP CONSTRAINT mcp_oauth_clients_client_id_size_check,
          DROP CONSTRAINT mcp_oauth_clients_client_name_size_check,
          DROP CONSTRAINT mcp_oauth_clients_redirect_uris_size_check
        """
      end
    end
  end

  actions do
    defaults [:read]

    create :cache do
      primary? true
      accept [:issuer, :client_id, :client_name, :redirect_uris, :fetched_at, :expires_at]
      upsert? true
      upsert_identity :unique_issuer_client_id
      upsert_fields [:client_name, :redirect_uris, :fetched_at, :expires_at]
    end
  end

  policies do
    # Direct client reads/writes are system-only (`authorize?: false`).
    # Grant list can load this row for Connected Clients (no secrets here).
    bypass accessing_from(Alplus.Mcp.OAuthGrant, :oauth_client) do
      authorize_if action_type(:read)
    end

    policy always() do
      forbid_if always()
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "mcocl"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate(:mcp_oauth_client) end
    end

    attribute :issuer, :string do
      allow_nil? false
      public? true
      constraints max_length: 2048
    end

    attribute :client_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 2048
    end

    attribute :client_name, :string do
      allow_nil? true
      public? true
      constraints max_length: 256
    end

    attribute :redirect_uris, {:array, :string} do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 32, items: [max_length: 2048]
    end

    attribute :fetched_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      default &DateTime.utc_now/0
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :grants, Alplus.Mcp.OAuthGrant do
      destination_attribute :oauth_client_id
    end
  end

  identities do
    identity :unique_issuer_client_id, [:issuer, :client_id], eager_check?: true
  end
end
