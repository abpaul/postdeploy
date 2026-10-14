defmodule Alplus.Monitoring.HttpConfig do
  @moduledoc "A 1:1 HTTP or keyword monitor configuration."
  use Alplus.Monitoring.Configs

  postgres do
    table "monitor_http_configs"
    repo Alplus.Repo

    custom_statements do
      statement :http_checks do
        up """
        ALTER TABLE monitor_http_configs
          ADD CONSTRAINT monitor_http_configs_url_check CHECK (octet_length(url) BETWEEN 1 AND 2048),
          ADD CONSTRAINT monitor_http_configs_method_check CHECK (method IN ('GET', 'HEAD', 'POST')),
          ADD CONSTRAINT monitor_http_configs_interval_check CHECK (interval_seconds BETWEEN 30 AND 31536000),
          ADD CONSTRAINT monitor_http_configs_timeout_check CHECK (timeout_seconds BETWEEN 1 AND 60),
          ADD CONSTRAINT monitor_http_configs_retry_check CHECK (retry_interval_seconds IS NULL OR (retry_interval_seconds BETWEEN 30 AND interval_seconds)),
          ADD CONSTRAINT monitor_http_configs_redirect_check CHECK (max_redirects BETWEEN 0 AND 10),
          ADD CONSTRAINT monitor_http_configs_response_threshold_check CHECK (response_time_threshold_ms IS NULL OR response_time_threshold_ms BETWEEN 100 AND 60000),
          ADD CONSTRAINT monitor_http_configs_headers_cap_check CHECK (headers IS NULL OR octet_length(headers::text) <= 16384),
          ADD CONSTRAINT monitor_http_configs_body_cap_check CHECK (body IS NULL OR octet_length(body) <= 65536),
          ADD CONSTRAINT monitor_http_configs_keyword_cap_check CHECK (keyword_match IS NULL OR octet_length(keyword_match::text) <= 1024)
        """

        down """
        ALTER TABLE monitor_http_configs
          DROP CONSTRAINT monitor_http_configs_url_check,
          DROP CONSTRAINT monitor_http_configs_method_check,
          DROP CONSTRAINT monitor_http_configs_interval_check,
          DROP CONSTRAINT monitor_http_configs_timeout_check,
          DROP CONSTRAINT monitor_http_configs_retry_check,
          DROP CONSTRAINT monitor_http_configs_redirect_check,
          DROP CONSTRAINT monitor_http_configs_response_threshold_check,
          DROP CONSTRAINT monitor_http_configs_headers_cap_check,
          DROP CONSTRAINT monitor_http_configs_body_cap_check,
          DROP CONSTRAINT monitor_http_configs_keyword_cap_check
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
        :url,
        :method,
        :expected_status,
        :keyword_match,
        :headers,
        :body,
        :follow_redirects,
        :max_redirects,
        :interval_seconds,
        :retry_interval_seconds,
        :timeout_seconds,
        :response_time_threshold_ms,
        :ssl_expiry_warn_days,
        :domain_expiry_warn_days
      ]
    end

    update :update do
      accept [:url, :keyword_match, :interval_seconds]
    end

    destroy :destroy do
    end
  end

  attributes do
    attribute :url, :string, allow_nil?: false, public?: true
    attribute :method, :string, allow_nil?: false, default: "GET", public?: true
    attribute :expected_status, :map, allow_nil?: false, public?: true
    attribute :keyword_match, :map, allow_nil?: true, public?: true
    attribute :headers, :map, allow_nil?: true, public?: true
    attribute :body, :string, allow_nil?: true, public?: false, sensitive?: true
    attribute :follow_redirects, :boolean, allow_nil?: false, default: true, public?: true
    attribute :max_redirects, :integer, allow_nil?: false, default: 5, public?: true
    attribute :interval_seconds, :integer, allow_nil?: false, public?: true
    attribute :retry_interval_seconds, :integer, allow_nil?: true, public?: true
    attribute :timeout_seconds, :integer, allow_nil?: false, public?: true
    attribute :response_time_threshold_ms, :integer, allow_nil?: true, public?: true
    attribute :ssl_expiry_warn_days, {:array, :integer}, allow_nil?: true, public?: true
    attribute :domain_expiry_warn_days, {:array, :integer}, allow_nil?: true, public?: true
  end
end
