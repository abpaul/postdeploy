defmodule Alplus.Mcp.OAuthDeviceCode do
  @moduledoc """
  RFC 8628 device authorization request. The raw `mcodc_*` device code is
  returned once in action metadata; only the hash and prefix are persisted.
  The `user_code` is shown to a person and is therefore stored in the clear.
  Requests expire after 15 minutes and are single-use.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Mcp,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "mcp_oauth_device_codes"
    repo Alplus.Repo

    references do
      reference :grant, on_delete: :nilify
      reference :oauth_client, on_delete: :delete
    end

    custom_indexes do
      # `prune_expired/0` deletes by this column on a schedule.
      index [:expires_at]
    end

    custom_statements do
      statement :device_code_hash_format do
        up "ALTER TABLE mcp_oauth_device_codes ADD CONSTRAINT mcp_oauth_device_codes_device_code_hash_check CHECK (device_code_hash ~ '^[0-9a-f]{64}$')"

        down "ALTER TABLE mcp_oauth_device_codes DROP CONSTRAINT mcp_oauth_device_codes_device_code_hash_check"
      end
    end
  end

  actions do
    defaults [:read]

    read :get_by_prefix do
      get? true
      argument :prefix, :string, allow_nil?: false
      filter expr(device_code_prefix == ^arg(:prefix))
    end

    read :get_by_user_code do
      get? true
      argument :user_code, :string, allow_nil?: false
      filter expr(user_code == ^arg(:user_code))
    end

    create :issue do
      primary? true
      accept [:oauth_client_id, :user_code, :resource, :scopes]
      change Alplus.Mcp.OAuthDeviceCode.Changes.Issue
      metadata :device_code, :string, allow_nil?: false
    end

    # A person approved the request in the browser. The grant carries the
    # organization and project; `scopes` records what they approved for this
    # device code, because one client can hold several at once.
    update :approve do
      accept [:grant_id, :scopes]
      require_atomic? false
      filter expr(is_nil(approved_at) and is_nil(denied_at) and is_nil(consumed_at))
      validate present(:grant_id)
      validate present(:scopes)
      change set_attribute(:approved_at, &DateTime.utc_now/0)
    end

    update :deny do
      accept []
      require_atomic? false
      filter expr(is_nil(approved_at) and is_nil(denied_at) and is_nil(consumed_at))
      change set_attribute(:denied_at, &DateTime.utc_now/0)
    end

    # The client exchanged the device code for tokens. Single-use.
    update :consume do
      accept []
      require_atomic? false
      filter expr(is_nil(consumed_at))
      validate negate(present(:consumed_at))
      change set_attribute(:consumed_at, &DateTime.utc_now/0)
    end

    # Records a poll so the token endpoint can enforce the polling interval.
    update :touch_poll do
      accept []
      require_atomic? false
      change set_attribute(:last_polled_at, &DateTime.utc_now/0)
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
      constraints prefix: "mcodv"
      primary_key? true
      allow_nil? false
      writable? false
      public? true
      default fn -> Alplus.Id.generate("mcodv") end
    end

    attribute :oauth_client_id, Alplus.Id do
      constraints prefix: "mcocl"
      allow_nil? false
      public? true
    end

    # Set when a person approves. Absent until then.
    attribute :grant_id, Alplus.Id do
      constraints prefix: "mcogr"
      allow_nil? true
      public? true
    end

    attribute :device_code_hash, :string do
      allow_nil? false
      writable? false
      public? false
      sensitive? true
    end

    attribute :device_code_prefix, :string do
      allow_nil? false
      writable? false
      public? false
      sensitive? true
      constraints min_length: 8, max_length: 8
    end

    # Shown to a person, so it is short and readable rather than secret.
    # Entropy is bounded; the short expiry and the poll interval carry the
    # rest of the protection.
    attribute :user_code, :string do
      allow_nil? false
      public? true
      constraints min_length: 9, max_length: 9
    end

    attribute :resource, :string do
      allow_nil? false
      public? true
    end

    # The permissions the client asked for. The person may grant a subset.
    attribute :scopes, {:array, :string} do
      allow_nil? false
      public? true
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      public? true
    end

    attribute :last_polled_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :approved_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :denied_at, :utc_datetime_usec do
      allow_nil? true
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
      allow_nil? true
    end

    belongs_to :oauth_client, Alplus.Mcp.OAuthClient do
      source_attribute :oauth_client_id
      define_attribute? false
      allow_nil? false
    end
  end

  identities do
    identity :unique_device_code_prefix, [:device_code_prefix]
    identity :unique_user_code, [:user_code]
  end
end
