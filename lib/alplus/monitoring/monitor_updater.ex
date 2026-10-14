defmodule Alplus.Monitoring.MonitorUpdater do
  @moduledoc """
  Updates a monitor and its typed configuration.

  This resolves the organization's durable billing plan before checking the
  requested interval, mirroring `Alplus.Monitoring.MonitorCreator`. Unlike
  create, it never checks monitor-count capacity: the monitor already
  counts against it. `Monitor`'s `:update` action already reconciles the
  scheduler and broadcasts `{:monitor_updated, project_id}` via
  `Alplus.Monitoring.Monitor.Changes.ReconcileScheduler`, so this boundary
  does not repeat that broadcast.

  The two updates are not wrapped in a shared `Repo.transaction`: that
  change's `Ash.Changeset.after_transaction` hook would then fire before
  the outer transaction actually commits (Ash reuses the surrounding
  connection instead of opening its own), broadcasting an update that a
  later step in the same transaction could still roll back. Each `Ash.update/3`
  keeps its own real, already-committed transaction instead.

  `MonitorFormAttrs` bounds every field the DB enforces via `CHECK`
  constraints before this boundary ever runs, so a DB rejection here should
  not happen. Belt-and-suspenders: the config write (the one carrying most
  of those constraints) still goes first, so any DB-level rejection this
  boundary receives leaves the monitor's own row (name/environment)
  unchanged, rather than committing that half and failing on the config.
  The public update boundary for Monitor UI/API code.
  """

  alias Alplus.Billing.Access
  alias Alplus.Monitoring.Monitor

  @spec update(Monitor.t(), struct(), map(), map(), Alplus.Scope.t()) ::
          {:ok, Monitor.t()} | {:error, term()}
  def update(%Monitor{} = monitor, config, monitor_attrs, config_attrs, actor)
      when is_map(monitor_attrs) and is_map(config_attrs) do
    with :ok <- authorize_scope(monitor, actor),
         :ok <- check_entitlement(monitor.org_id, monitor.type, config_attrs),
         {:ok, _updated_config} <- Ash.update(config, config_attrs, action: :update, actor: actor) do
      Ash.update(monitor, monitor_attrs, action: :update, actor: actor)
    end
  end

  @doc "Updates only the lifecycle status for a project-scoped monitor."
  @spec update_status(Monitor.t(), String.t(), Alplus.Scope.t()) ::
          {:ok, Monitor.t()} | {:error, term()}
  def update_status(%Monitor{} = monitor, status, actor) when status in ["active", "paused"] do
    with :ok <- authorize_scope(monitor, actor) do
      Ash.update(monitor, %{status: status}, action: :update, actor: actor)
    end
  end

  def update_status(_monitor, _status, _actor), do: {:error, :invalid_status}

  @doc "Reissues a heartbeat secret after authorizing the monitor's project scope."
  @spec reissue_heartbeat_token(Monitor.t(), Alplus.Scope.t()) ::
          {:ok, struct()} | {:error, term()}
  def reissue_heartbeat_token(%Monitor{type: "heartbeat"} = monitor, actor) do
    with :ok <- authorize_scope(monitor, actor),
         {:ok, config} <- Alplus.Monitoring.get_heartbeat_config(monitor.id, actor: actor) do
      Alplus.Monitoring.reissue_heartbeat_token(config, actor: actor)
    end
  end

  def reissue_heartbeat_token(_monitor, _actor), do: {:error, :invalid_monitor_type}

  defp check_entitlement(org_id, "heartbeat", config_attrs) do
    with {:ok, _access} <- Access.check(org_id) do
      heartbeat_interval_entitlement(org_id, config_attrs)
    end
  end

  defp check_entitlement(org_id, _type, config_attrs) do
    Access.allow_monitor_update(org_id, %{
      interval_seconds: Map.get(config_attrs, :interval_seconds)
    })
  end

  defp heartbeat_interval_entitlement(_org_id, %{interval_seconds: nil}), do: :ok

  defp heartbeat_interval_entitlement(org_id, %{interval_seconds: interval}) do
    Access.allow_monitor_update(org_id, %{interval_seconds: interval})
  end

  defp authorize_scope(%Monitor{org_id: org_id, project_id: project_id}, %{
         org_id: org_id,
         project_id: project_id
       }),
       do: :ok

  defp authorize_scope(_monitor, _actor), do: {:error, :scope_mismatch}
end
