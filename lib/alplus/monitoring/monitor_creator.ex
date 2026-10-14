defmodule Alplus.Monitoring.MonitorCreator do
  @moduledoc """
  Creates a monitor and its required typed configuration in one transaction.

  The plan entitlement check runs INSIDE that transaction. It locks the
  organization row before it counts monitors, so two concurrent creates for
  the last slot cannot both pass: the loser waits for the lock, then counts
  the winner's row. Checking before the transaction took no lock and let
  both succeed.

  It is the public creation boundary for Monitor UI/API code.
  """

  require Logger

  alias Alplus.Billing.Access

  alias Alplus.Monitoring.{
    DnsConfig,
    HeartbeatConfig,
    HttpConfig,
    Monitor,
    TcpConfig
  }

  @spec create(map(), map(), Alplus.Scope.t()) ::
          {:ok, %{monitor: Monitor.t(), heartbeat_token: String.t() | nil}} | {:error, term()}
  def create(monitor_attrs, config_attrs, actor)
      when is_map(monitor_attrs) and is_map(config_attrs) do
    with :ok <- authorize_scope(monitor_attrs, actor),
         {:ok, {monitor, config, entitlement, notifications}} <-
           create_transaction(monitor_attrs, config_attrs, actor) do
      Ash.Notifier.notify(notifications)
      reconcile_scheduler(monitor.id)

      Phoenix.PubSub.broadcast(
        Alplus.PubSub,
        "monitor:#{monitor.project_id}",
        {:monitor_updated, monitor.project_id}
      )

      {:ok,
       %{
         monitor: Map.put(monitor, :entitlement, entitlement),
         heartbeat_token: Ash.Resource.get_metadata(config, :heartbeat_token)
       }}
    end
  end

  defp authorize_scope(%{org_id: org_id, project_id: project_id}, %{
         org_id: org_id,
         project_id: project_id
       }),
       do: :ok

  defp authorize_scope(_, _), do: {:error, :scope_mismatch}

  defp check_entitlement(%{type: "heartbeat"} = monitor_attrs, config_attrs) do
    # Cron expressions have no meaningful fixed interval. Capacity remains
    # plan-gated, and interval heartbeats use the same cron capacity pool.
    with {:ok, entitlement} <-
           Access.allow_heartbeat_create(monitor_attrs.org_id, %{
             project_id: monitor_attrs.project_id
           }),
         :ok <- heartbeat_interval_entitlement(monitor_attrs.org_id, config_attrs) do
      {:ok, entitlement}
    end
  end

  defp check_entitlement(monitor_attrs, config_attrs) do
    Access.allow_monitor_create(monitor_attrs.org_id, %{
      project_id: monitor_attrs.project_id,
      type: monitor_attrs.type,
      interval_seconds: Map.get(config_attrs, :interval_seconds),
      retry_interval_seconds: Map.get(config_attrs, :retry_interval_seconds)
    })
  end

  defp create_transaction(monitor_attrs, config_attrs, actor) do
    Alplus.Repo.transaction(fn ->
      with {:ok, entitlement} <- check_entitlement(monitor_attrs, config_attrs),
           {:ok, monitor, monitor_notifications} <-
             Ash.create(Monitor, monitor_attrs,
               action: :create,
               actor: actor,
               return_notifications?: true
             ),
           {:ok, config, config_notifications} <- create_config(monitor, config_attrs, actor) do
        {monitor, config, entitlement, monitor_notifications ++ config_notifications}
      else
        {:error, reason} -> Alplus.Repo.rollback(reason)
      end
    end)
  end

  defp create_config(%Monitor{type: type} = monitor, attrs, actor) do
    resource = config_resource(type)
    attrs = Map.merge(attrs, %{monitor_id: monitor.id, org_id: monitor.org_id})

    Ash.create(resource, attrs,
      action: config_action(type),
      actor: actor,
      return_notifications?: true
    )
  end

  defp config_resource(type) when type in ["http", "keyword"], do: HttpConfig
  defp config_resource("heartbeat"), do: HeartbeatConfig
  defp config_resource("tcp"), do: TcpConfig
  defp config_resource("dns"), do: DnsConfig

  defp config_action("heartbeat"), do: :issue
  defp config_action(_type), do: :create

  defp heartbeat_interval_entitlement(_org_id, %{interval_seconds: nil}), do: :ok

  defp heartbeat_interval_entitlement(org_id, %{interval_seconds: interval}) do
    Access.allow_monitor_update(org_id, %{interval_seconds: interval})
  end

  # The scheduler reconciles on its own tick, so a failed reconcile here
  # must not fail monitor creation. It is logged, never swallowed silently.
  defp reconcile_scheduler(monitor_id) do
    case Alplus.Monitoring.Scheduler.reconcile_monitor(monitor_id) do
      {:ok, _pid} ->
        :ok

      :ok ->
        :ok

      # `:ignore` means the worker declined to start: the monitor is a
      # heartbeat, is inactive, or its row is not visible to the worker's
      # connection yet. None of those is a failure.
      :ignore ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Failed to reconcile scheduler for monitor #{monitor_id}: #{inspect(reason)}"
        )
    end
  end
end
