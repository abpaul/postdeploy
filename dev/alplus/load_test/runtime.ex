defmodule Alplus.LoadTest.Runtime do
  @moduledoc false

  def run(fun) when is_function(fun, 1) do
    Mix.Task.run("app.config")

    if started?(:alplus) do
      raise Mix.Error,
        message:
          "alplus.loadtest must run in a fresh Mix process so it can start its HTTP listener"
    end

    serve_endpoints = Application.fetch_env(:phoenix, :serve_endpoints)
    endpoint_config = Application.fetch_env(:alplus, AlplusWeb.Endpoint)

    boot_rehydrate_enabled =
      Application.fetch_env(:alplus, :monitor_scheduler_boot_rehydrate_enabled?)

    reconcile_interval = Application.fetch_env(:alplus, :monitor_reconcile_interval_ms)

    log_level = Logger.level()

    try do
      Application.put_env(
        :alplus,
        :monitor_scheduler_boot_rehydrate_enabled?,
        false,
        persistent: true
      )

      Application.put_env(:alplus, :monitor_reconcile_interval_ms, 0, persistent: true)

      Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)

      current_endpoint_config = Application.get_env(:alplus, AlplusWeb.Endpoint, [])

      Application.put_env(
        :alplus,
        AlplusWeb.Endpoint,
        Keyword.merge(current_endpoint_config,
          code_reloader: false,
          watchers: [],
          debug_errors: false
        ),
        persistent: true
      )

      {:ok, _started} = Application.ensure_all_started(:alplus)
      Logger.configure(level: :warning)
      fun.(base_url())
    after
      if started?(:alplus), do: Application.stop(:alplus)
      Logger.configure(level: log_level)

      restore_env(
        :alplus,
        :monitor_scheduler_boot_rehydrate_enabled?,
        boot_rehydrate_enabled
      )

      restore_env(:alplus, :monitor_reconcile_interval_ms, reconcile_interval)
      restore_env(:phoenix, :serve_endpoints, serve_endpoints)
      restore_env(:alplus, AlplusWeb.Endpoint, endpoint_config)
    end
  end

  defp base_url do
    config = Application.get_env(:alplus, AlplusWeb.Endpoint, [])
    port = get_in(config, [:http, :port]) || 4000
    "http://127.0.0.1:#{port}"
  end

  defp restore_env(app, key, {:ok, value}),
    do: Application.put_env(app, key, value, persistent: true)

  defp restore_env(app, key, :error),
    do: Application.delete_env(app, key, persistent: true)

  defp started?(app) do
    Enum.any?(Application.started_applications(), fn {started_app, _description, _version} ->
      started_app == app
    end)
  end
end
