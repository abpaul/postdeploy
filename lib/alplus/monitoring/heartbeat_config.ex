defmodule Alplus.Monitoring.HeartbeatConfig do
  @moduledoc "A 1:1 heartbeat schedule and secret hash."
  use Alplus.Monitoring.Configs, public_schedule_fields: [:interval_seconds, :cron_expression]

  postgres do
    table "monitor_heartbeat_configs"
    repo Alplus.Repo

    custom_indexes do
      index [:heartbeat_token_prefix], unique: true
    end

    custom_statements do
      statement :heartbeat_checks do
        up """
        ALTER TABLE monitor_heartbeat_configs
          ADD CONSTRAINT monitor_heartbeat_configs_hash_check CHECK (heartbeat_token_hash ~ '^[0-9a-f]{64}$'),
          ADD CONSTRAINT monitor_heartbeat_configs_schedule_check CHECK ((interval_seconds IS NOT NULL) <> (cron_expression IS NOT NULL)),
          ADD CONSTRAINT monitor_heartbeat_configs_interval_check CHECK (interval_seconds IS NULL OR interval_seconds BETWEEN 30 AND 31536000),
          ADD CONSTRAINT monitor_heartbeat_configs_grace_check CHECK (grace_period_seconds BETWEEN 0 AND 86400),
          ADD CONSTRAINT monitor_heartbeat_configs_duration_check CHECK (expected_duration_seconds IS NULL OR expected_duration_seconds BETWEEN 1 AND 86400),
          ADD CONSTRAINT monitor_heartbeat_configs_cron_check CHECK (cron_expression IS NULL OR octet_length(cron_expression) <= 100),
          ADD CONSTRAINT monitor_heartbeat_configs_timezone_check CHECK (octet_length(timezone) BETWEEN 1 AND 64)
        """

        down """
        ALTER TABLE monitor_heartbeat_configs DROP CONSTRAINT monitor_heartbeat_configs_hash_check, DROP CONSTRAINT monitor_heartbeat_configs_schedule_check, DROP CONSTRAINT monitor_heartbeat_configs_interval_check, DROP CONSTRAINT monitor_heartbeat_configs_grace_check, DROP CONSTRAINT monitor_heartbeat_configs_duration_check, DROP CONSTRAINT monitor_heartbeat_configs_cron_check, DROP CONSTRAINT monitor_heartbeat_configs_timezone_check
        """
      end
    end
  end

  actions do
    defaults [:read]

    read :get_by_prefix do
      get? true
      argument :prefix, :string, allow_nil?: false
      filter expr(heartbeat_token_prefix == ^arg(:prefix))
    end

    create :create do
      accept [
        :monitor_id,
        :org_id,
        :heartbeat_token_hash,
        :heartbeat_token_prefix,
        :grace_period_seconds,
        :interval_seconds,
        :cron_expression,
        :timezone,
        :track_duration,
        :expected_duration_seconds
      ]
    end

    create :issue do
      accept [
        :monitor_id,
        :org_id,
        :grace_period_seconds,
        :interval_seconds,
        :cron_expression,
        :timezone,
        :track_duration,
        :expected_duration_seconds
      ]

      change Alplus.Monitoring.HeartbeatConfig.Changes.IssueToken

      metadata :heartbeat_token, :string, allow_nil?: false
    end

    # The heartbeat URL is shown once, at creation (the token is only ever
    # stored hashed — "possession is the credential"). A dismissed or lost
    # banner had no path back before this: reissuing invalidates the old
    # token and mints a
    # fresh one the operator can copy right away
    # (`docs/research/onboarding-best-practices-2026-08-13.md`, monitor
    # setup dead-end fix).
    update :reissue_token do
      accept []
      require_atomic? false

      change Alplus.Monitoring.HeartbeatConfig.Changes.IssueToken

      metadata :heartbeat_token, :string, allow_nil?: false
    end

    update :update do
      accept [:interval_seconds, :cron_expression]
    end

    destroy :destroy do
    end
  end

  policies do
    policy action(:reissue_token) do
      authorize_if expr(
                     ^ref(:org_id) == ^actor(:org_id) and
                       exists(
                         monitor,
                         ^ref(:project_id) == ^actor(:project_id) and
                           exists(
                             organization.memberships,
                             ^ref(:user_id) == ^actor(:user_id) and
                               ^ref(:role) in ["owner", "admin"]
                           )
                       )
                   )
    end
  end

  attributes do
    attribute :heartbeat_token_hash, :string, allow_nil?: false, public?: false, sensitive?: true
    attribute :heartbeat_token_prefix, :string, allow_nil?: false, public?: true
    attribute :grace_period_seconds, :integer, allow_nil?: false, public?: true
    attribute :interval_seconds, :integer, allow_nil?: true, public?: true
    attribute :cron_expression, :string, allow_nil?: true, public?: true
    attribute :timezone, :string, allow_nil?: false, default: "UTC", public?: true
    attribute :track_duration, :boolean, allow_nil?: false, default: false, public?: true
    attribute :expected_duration_seconds, :integer, allow_nil?: true, public?: true
  end

  @doc "Authenticates a raw `hb_*` token without exposing why it failed."
  @spec authenticate(String.t()) :: {:ok, t()} | {:error, :not_found}
  def authenticate(token) when is_binary(token) do
    hash = Alplus.Security.BearerToken.hash(token)

    with "hb_" <> _ <- token,
         prefix when is_binary(prefix) <- Alplus.Security.BearerToken.short_prefix(token),
         {:ok, %__MODULE__{} = config} <-
           __MODULE__
           |> Ash.Query.for_read(:get_by_prefix, %{prefix: prefix}, authorize?: false)
           |> Ash.read_one(authorize?: false),
         true <- Alplus.Security.BearerToken.matches?(config.heartbeat_token_hash, hash) do
      {:ok, config}
    else
      _ -> {:error, :not_found}
    end
  end
end
