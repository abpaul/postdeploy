defmodule Alplus.Monitoring.DnsConfig do
  @moduledoc "A 1:1 DNS monitor configuration."
  use Alplus.Monitoring.Configs

  postgres do
    table "monitor_dns_configs"
    repo Alplus.Repo

    custom_statements do
      statement :dns_checks do
        up """
        ALTER TABLE monitor_dns_configs
          ADD CONSTRAINT monitor_dns_configs_hostname_check CHECK (octet_length(hostname) BETWEEN 1 AND 2048),
          ADD CONSTRAINT monitor_dns_configs_record_type_check CHECK (record_type IN ('A', 'AAAA', 'CNAME', 'MX', 'TXT', 'NS')),
          ADD CONSTRAINT monitor_dns_configs_expected_values_check CHECK (cardinality(expected_values) BETWEEN 0 AND 20 AND octet_length(array_to_string(expected_values, ',')) <= 12288),
          ADD CONSTRAINT monitor_dns_configs_interval_check CHECK (interval_seconds BETWEEN 30 AND 31536000),
          ADD CONSTRAINT monitor_dns_configs_retry_check CHECK (retry_interval_seconds IS NULL OR retry_interval_seconds BETWEEN 30 AND interval_seconds)
        """

        down """
        ALTER TABLE monitor_dns_configs
          DROP CONSTRAINT monitor_dns_configs_hostname_check,
          DROP CONSTRAINT monitor_dns_configs_record_type_check,
          DROP CONSTRAINT monitor_dns_configs_expected_values_check,
          DROP CONSTRAINT monitor_dns_configs_interval_check,
          DROP CONSTRAINT monitor_dns_configs_retry_check
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
        :record_type,
        :expected_values,
        :match_mode,
        :interval_seconds,
        :retry_interval_seconds
      ]
    end

    update :update do
      accept [:hostname, :record_type, :expected_values, :match_mode, :interval_seconds]
    end

    destroy :destroy do
    end
  end

  attributes do
    attribute :hostname, :string, allow_nil?: false, public?: true
    attribute :record_type, :string, allow_nil?: false, public?: true
    attribute :expected_values, {:array, :string}, allow_nil?: false, public?: true

    attribute :match_mode, :atom do
      constraints one_of: [:all, :any]
      default :all
      allow_nil? false
      public? true
    end

    attribute :interval_seconds, :integer, allow_nil?: false, public?: true
    attribute :retry_interval_seconds, :integer, allow_nil?: true, public?: true
  end
end
