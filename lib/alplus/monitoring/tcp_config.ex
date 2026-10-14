defmodule Alplus.Monitoring.TcpConfig do
  @moduledoc "A 1:1 TCP monitor configuration."
  use Alplus.Monitoring.Configs

  postgres do
    table "monitor_tcp_configs"
    repo Alplus.Repo

    custom_statements do
      statement :tcp_checks do
        up """
        ALTER TABLE monitor_tcp_configs
          ADD CONSTRAINT monitor_tcp_configs_hostname_check CHECK (octet_length(hostname) BETWEEN 1 AND 2048),
          ADD CONSTRAINT monitor_tcp_configs_port_check CHECK (port BETWEEN 1 AND 65535),
          ADD CONSTRAINT monitor_tcp_configs_timeout_check CHECK (timeout_seconds BETWEEN 1 AND 30),
          ADD CONSTRAINT monitor_tcp_configs_interval_check CHECK (interval_seconds BETWEEN 30 AND 31536000),
          ADD CONSTRAINT monitor_tcp_configs_retry_check CHECK (retry_interval_seconds IS NULL OR retry_interval_seconds BETWEEN 30 AND interval_seconds)
        """

        down """
        ALTER TABLE monitor_tcp_configs
          DROP CONSTRAINT monitor_tcp_configs_hostname_check,
          DROP CONSTRAINT monitor_tcp_configs_port_check,
          DROP CONSTRAINT monitor_tcp_configs_timeout_check,
          DROP CONSTRAINT monitor_tcp_configs_interval_check,
          DROP CONSTRAINT monitor_tcp_configs_retry_check
        """
      end
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :monitor_id,
        :org_id,
        :hostname,
        :port,
        :timeout_seconds,
        :interval_seconds,
        :retry_interval_seconds
      ]
    end

    update :update do
      accept [:hostname, :port, :interval_seconds]
    end

    destroy :destroy do
    end
  end

  attributes do
    attribute :hostname, :string, allow_nil?: false, public?: true
    attribute :port, :integer, allow_nil?: false, public?: true
    attribute :timeout_seconds, :integer, allow_nil?: false, public?: true
    attribute :interval_seconds, :integer, allow_nil?: false, public?: true
    attribute :retry_interval_seconds, :integer, allow_nil?: true, public?: true
  end
end
