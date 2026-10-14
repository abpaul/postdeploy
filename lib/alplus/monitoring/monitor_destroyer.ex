defmodule Alplus.Monitoring.MonitorDestroyer do
  @moduledoc """
  Destroys a monitor and its typed configuration in one transaction, then
  deregisters it from the scheduler and broadcasts the same PubSub
  `Alplus.Monitoring.MonitorCreator.create/3` uses. The public destroy
  boundary for Monitor UI/API code.

  The DB cascades checks, incidents, pause intervals, and rollups on
  `monitors.id` (`ON DELETE CASCADE`), but the typed config tables
  (`monitor_http_configs`, `monitor_tcp_configs`, `monitor_dns_configs`,
  `monitor_heartbeat_configs`) have no `ON DELETE` action on `monitor_id` —
  a bare `Ash.destroy/2` on the monitor would hit a foreign key violation.
  This destroys the config row explicitly, in the same transaction, before
  the monitor.
  """

  require Logger

  alias Alplus.Monitoring.{DnsConfig, HeartbeatConfig, HttpConfig, Monitor, TcpConfig}

  @spec destroy(Monitor.t(), Alplus.Scope.t()) :: :ok | {:error, term()}
  def destroy(%Monitor{} = monitor, actor) do
    with :ok <- authorize_scope(monitor, actor),
         {:ok, notifications} <- destroy_transaction(monitor, actor) do
      Ash.Notifier.notify(notifications)
      deregister_scheduler(monitor.id)

      Phoenix.PubSub.broadcast(
        Alplus.PubSub,
        "monitor:#{monitor.project_id}",
        {:monitor_updated, monitor.project_id}
      )

      :ok
    end
  end

  defp destroy_transaction(monitor, actor) do
    Alplus.Repo.transaction(fn ->
      with {:ok, config_notifications} <- destroy_config(monitor, actor),
           {:ok, monitor_notifications} <-
             Ash.destroy(monitor, action: :destroy, actor: actor, return_notifications?: true) do
        config_notifications ++ monitor_notifications
      else
        {:error, reason} -> Alplus.Repo.rollback(reason)
      end
    end)
  end

  defp destroy_config(%Monitor{id: id, type: type}, actor) do
    resource = config_resource(type)

    case Ash.get(resource, id, actor: actor) do
      {:ok, config} ->
        Ash.destroy(config, action: :destroy, actor: actor, return_notifications?: true)

      {:error, %Ash.Error.Query.NotFound{}} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp config_resource(type) when type in ["http", "keyword"], do: HttpConfig
  defp config_resource("heartbeat"), do: HeartbeatConfig
  defp config_resource("tcp"), do: TcpConfig
  defp config_resource("dns"), do: DnsConfig

  defp authorize_scope(%Monitor{org_id: org_id, project_id: project_id}, %{
         org_id: org_id,
         project_id: project_id
       }),
       do: :ok

  defp authorize_scope(_monitor, _actor), do: {:error, :scope_mismatch}

  # The scheduler reconciles on its own tick, so a failed deregister here
  # must not fail the destroy. It is logged, never swallowed silently.
  defp deregister_scheduler(monitor_id) do
    case Alplus.Monitoring.Scheduler.stop_monitor(monitor_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Failed to deregister scheduler for monitor #{monitor_id}: #{inspect(reason)}"
        )
    end
  end
end
