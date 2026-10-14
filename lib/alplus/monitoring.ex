defmodule Alplus.Monitoring do
  @moduledoc """
  Durable Monitor state. Runtime scheduling stays in native OTP and is added
  in the next Phase 6 slice (ARCHITECTURE.md §§3, 6).
  """

  use Ash.Domain, otp_app: :alplus

  resources do
    resource Alplus.Monitoring.Monitor do
      define :create_monitor, action: :create
      define :get_monitor, action: :read, get_by: [:id]
      define :list_monitors_for_project, action: :list_for_project, args: [:project_id]
      define :list_monitors_for_projects, action: :list_for_projects, args: [:project_ids]
      define :list_public_homepage_monitors, action: :public_homepage_for_vendor
      define :update_monitor, action: :update
    end

    resource Alplus.Monitoring.HttpConfig do
      define :list_public_homepage_http_configs,
        action: :public_homepage_for_vendor,
        args: [:monitor_ids]

      define :create_http_config, action: :create
      define :get_http_config, action: :read, get_by: [:monitor_id]
    end

    resource Alplus.Monitoring.HeartbeatConfig do
      define :list_public_homepage_heartbeat_configs,
        action: :public_homepage_for_vendor,
        args: [:monitor_ids]

      define :create_heartbeat_config, action: :create
      define :issue_heartbeat_token, action: :issue
      define :reissue_heartbeat_token, action: :reissue_token
      define :get_heartbeat_config, action: :read, get_by: [:monitor_id]
    end

    resource Alplus.Monitoring.TcpConfig do
      define :list_public_homepage_tcp_configs,
        action: :public_homepage_for_vendor,
        args: [:monitor_ids]

      define :create_tcp_config, action: :create
      define :get_tcp_config, action: :read, get_by: [:monitor_id]
    end

    resource Alplus.Monitoring.DnsConfig do
      define :list_public_homepage_dns_configs,
        action: :public_homepage_for_vendor,
        args: [:monitor_ids]

      define :create_dns_config, action: :create
      define :get_dns_config, action: :read, get_by: [:monitor_id]
    end

    resource Alplus.Monitoring.MonitorCheck do
      define :get_monitor_check, action: :read, get_by: [:id]
      define :list_monitor_checks, action: :read

      define :list_public_homepage_monitor_checks,
        action: :public_homepage_for_vendor,
        args: [:monitor_ids]
    end

    resource Alplus.Monitoring.Incident do
      define :get_incident, action: :read, get_by: [:id]
      define :list_incidents, action: :read
      define :acknowledge_incident, action: :acknowledge
    end

    resource Alplus.Monitoring.HeartbeatRuntimeState do
    end

    resource Alplus.Monitoring.ActiveRuntimeState do
    end

    resource Alplus.Monitoring.DailyRollup do
      define :get_daily_rollup, action: :read, get_by: [:id]
      define :list_daily_rollups, action: :read

      define :list_daily_rollups_for_projects,
        action: :list_for_projects,
        args: [:project_ids]

      define :list_public_homepage_monitor_rollups,
        action: :public_homepage_for_vendor,
        args: [:monitor_ids, :since, :until]
    end

    resource Alplus.Monitoring.PauseInterval do
      define :list_pause_intervals, action: :read
    end
  end
end
