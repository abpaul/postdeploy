defmodule Alplus.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    attach_self_observability()

    analytics_engine_children =
      case Application.fetch_env!(:alplus, :analytics_engine_adapter) do
        Alplus.Measure.AnalyticsEngine.DevAdapter ->
          [Alplus.Measure.AnalyticsEngine.DevAdapter, Alplus.Measure.AnalyticsEngine.Batcher]

        _adapter ->
          [Alplus.Measure.AnalyticsEngine.Batcher]
      end

    children =
      [
        AlplusWeb.Telemetry,
        Alplus.Repo
      ] ++
        ingest_repo_children() ++
        [
          Alplus.NotificationsVault,
          {Alplus.Mcp.RateLimit, clean_period: :timer.minutes(2)},
          Alplus.Ingest.Admission,
          Alplus.Ingest.OperationalMonitor,
          {Alplus.Measure.VisitorState,
           max_entries: Application.fetch_env!(:alplus, :visitor_state_max_entries)},
          Alplus.Measure.VisitorSalt,
          Alplus.Measure.RateLimiter,
          Alplus.Measure.PublicCache,
          Alplus.Status.RateLimiter,
          Alplus.Observe.RateLimiter,
          Alplus.Analytics.RateLimiter,
          Alplus.Monitoring.HeartbeatRateLimiter,
          Alplus.Mcp.OAuth.DeviceRateLimiter,
          Alplus.Monitoring.AnonymousProbe.RateLimiter,
          Alplus.Monitoring.AnonymousProbe.Gate,
          Alplus.Notifications.AlertRateLimiter,
          Alplus.Observe.Symbolicator,
          Alplus.Billing.UsageCache
        ] ++
        analytics_engine_children ++
        [
          {Registry, keys: :unique, name: Alplus.Monitoring.Registry},
          {DynamicSupervisor, strategy: :one_for_one, name: Alplus.Monitoring.MonitorSupervisor},
          {Task.Supervisor, name: Alplus.Monitoring.CheckTaskSupervisor},
          Alplus.Monitoring.Scheduler,
          Alplus.Status.IncidentDraftReconciler,
          {DNSCluster, query: Application.get_env(:alplus, :dns_cluster_query) || :ignore},
          {Oban,
           AshOban.config(
             Application.fetch_env!(:alplus, :ash_domains),
             Application.fetch_env!(:alplus, Oban)
           )},
          {Phoenix.PubSub, name: Alplus.PubSub},
          {Alplus.Accounts.LoginLockout, []},
          # Start to serve requests, typically the last entry
          AlplusWeb.Endpoint,
          {AshAuthentication.Supervisor, [otp_app: :alplus]}
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Alplus.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp ingest_repo_children do
    case Application.fetch_env!(:alplus, :ingest_repo) do
      Alplus.Repo ->
        []

      name ->
        [
          Supervisor.child_spec(
            {Alplus.Repo,
             name: name,
             pool_size: Application.fetch_env!(:alplus, :ingest_pool_size),
             queue_target: 50,
             queue_interval: 100,
             timeout: 5_000},
            id: name
          )
        ]
    end
  end

  # Dogfooding: this app reports its own crashes and error logs to its own
  # Observe ingest with the official Sentry SDK, through the public HTTP
  # endpoint a customer uses.
  #
  # Attached only when `ALPLUS_KEY` is set. Without a DSN the SDK sends
  # nothing, so a developer machine and CI need no key.
  defp attach_self_observability do
    if System.get_env("ALPLUS_KEY") do
      :logger.add_handler(:sentry, Sentry.LoggerHandler, %{
        config: %{capture_log_messages: true, level: :error, metadata: [:user_id, :request_id]}
      })
    end

    :ok
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AlplusWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
