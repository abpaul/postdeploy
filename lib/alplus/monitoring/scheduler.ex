defmodule Alplus.Monitoring.Scheduler do
  @moduledoc false
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def rehydrate, do: call_if_enabled(:rehydrate)

  def rehydrate(monitor_ids) when is_list(monitor_ids),
    do: call_if_enabled({:rehydrate, monitor_ids})

  def stop_monitor(monitor_id), do: call_if_enabled({:stop, monitor_id})

  # The row read runs in the caller, not in the scheduler. A `Repo.query!`
  # inside `handle_call` blocked every other scheduler message for the length
  # of one database round trip, and a slow database froze monitor creation,
  # deletion and the reconcile tick together.
  def reconcile_monitor(monitor_id) do
    if Application.get_env(:alplus, :monitor_scheduler_enabled?, true) do
      GenServer.call(__MODULE__, {:reconcile, monitor_id, desired_state(monitor_id)})
    else
      :ok
    end
  end

  # Only a polled type gets a worker. A heartbeat monitor waits for the
  # customer's ping, so starting a checking worker for one asks the worker to
  # load a check configuration that cannot exist. The reconcile tick's own query
  # has always filtered by type; this read did not, so every heartbeat creation
  # asked the scheduler for a worker it must never have.
  @polled_types ~w(http keyword tcp dns)

  defp desired_state(monitor_id) do
    case Alplus.Repo.query!("SELECT status, type, org_id FROM monitors WHERE id = $1", [
           monitor_id
         ]) do
      %{rows: [["active", type, org_id]]} when is_binary(org_id) and type in @polled_types ->
        if entitled?(org_id), do: :running, else: :stopped

      _ ->
        :stopped
    end
  end

  # The database is the source of truth: `status='active'` means a check must be
  # running. Registration used to happen only on an explicit call from
  # `MonitorCreator`/`MonitorUpdater` or at boot, so anything that missed that
  # call left a monitor the console shows as active and which never checks
  # anything -- silent monitoring, the worst failure this product has. That
  # includes a transient `reconcile_monitor/1` failure (logged and deliberately
  # not fatal to creation), a row written outside the creator, and a monitor
  # whose worker died in a way its supervisor could not restart.
  #
  # So converge on a timer as well. `MonitorCreator` already documents this
  # behaviour ("the scheduler reconciles on its own tick"); until now that
  # sentence was false.
  @reconcile_interval_ms 60_000
  @boot_rehydrate_enabled_key :monitor_scheduler_boot_rehydrate_enabled?

  # Boot must not wait on the database. Rehydration used to run inside
  # `init/1`, so a slow or unreachable database delayed the whole supervision
  # tree behind it (Oban, PubSub, the endpoint) or failed application start
  # outright. A failed rehydrate now logs and leaves convergence to the
  # reconcile tick, which retries on every interval.
  @impl true
  def init(_) do
    {:ok, %{}, {:continue, :rehydrate}}
  end

  @impl true
  def handle_continue(:rehydrate, state) do
    state =
      if Application.get_env(:alplus, @boot_rehydrate_enabled_key, true) do
        try do
          rehydrate_all(state)
        rescue
          exception ->
            Logger.error(
              "monitor scheduler rehydrate failed, the reconcile tick retries: " <>
                Exception.message(exception)
            )

            state
        end
      else
        state
      end

    notify_rehydrated()
    schedule_reconcile()
    {:noreply, state}
  end

  @impl true
  def handle_call(:rehydrate, _from, state), do: {:reply, :ok, rehydrate_all(state)}

  def handle_call({:rehydrate, monitor_ids}, _from, state),
    do: {:reply, :ok, rehydrate_monitor_ids(state, monitor_ids)}

  def handle_call({:stop, monitor_id}, _from, state) do
    result = stop_child(monitor_id)

    {:reply, result, state}
  end

  def handle_call({:reconcile, monitor_id, :running}, _from, state),
    do: {:reply, start_child(monitor_id), state}

  def handle_call({:reconcile, monitor_id, :stopped}, _from, state),
    do: {:reply, stop_child(monitor_id), state}

  @impl true
  def handle_info(:reconcile_all, state) do
    try do
      active_ids = active_monitor_ids()
      Enum.each(active_ids, &start_child/1)
      stop_orphans(active_ids)
    rescue
      exception ->
        Logger.error("monitor scheduler reconcile failed: " <> Exception.message(exception))
    end

    schedule_reconcile()
    {:noreply, state}
  end

  defp schedule_reconcile do
    interval =
      Application.get_env(:alplus, :monitor_reconcile_interval_ms, @reconcile_interval_ms)

    if is_integer(interval) and interval > 0 do
      Process.send_after(self(), :reconcile_all, interval)
    end
  end

  # A worker still running for a monitor that is no longer active (paused,
  # deleted, or type-changed) would keep checking and keep alerting on a target
  # the customer believes they turned off.
  defp stop_orphans(active_ids) do
    active = MapSet.new(active_ids)

    Alplus.Monitoring.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.reject(&MapSet.member?(active, &1))
    |> Enum.each(&stop_child/1)
  end

  defp rehydrate_all(state) do
    Enum.each(active_monitor_ids(), &start_child/1)

    state
  end

  defp rehydrate_monitor_ids(state, monitor_ids) do
    Enum.each(monitor_ids, &start_child/1)

    state
  end

  defp active_monitor_ids do
    rows =
      Alplus.Repo.query!(
        "SELECT id, org_id FROM monitors WHERE status='active' AND type IN ('http','keyword','tcp','dns')"
      ).rows

    plans =
      rows
      |> Enum.map(fn [_id, org_id] -> org_id end)
      |> Enum.uniq()
      |> Alplus.Billing.Access.check_many()

    entitled_org_ids =
      plans
      |> Enum.filter(fn {_org_id, result} -> match?({:ok, _access}, result) end)
      |> Enum.map(fn {org_id, _result} -> org_id end)
      |> MapSet.new()

    for [id, org_id] <- rows, MapSet.member?(entitled_org_ids, org_id), do: id
  end

  defp entitled?(org_id), do: match?({:ok, _access}, Alplus.Billing.Access.check(org_id))

  defp start_child(monitor_id) do
    case DynamicSupervisor.start_child(
           Alplus.Monitoring.MonitorSupervisor,
           {Alplus.Monitoring.MonitorWorker, monitor_id}
         ) do
      {:error, {:already_started, _pid}} -> :ok
      result -> result
    end
  end

  defp stop_child(monitor_id) do
    case Registry.lookup(Alplus.Monitoring.Registry, monitor_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Alplus.Monitoring.MonitorSupervisor, pid)
      [] -> :ok
    end
  end

  defp call_if_enabled(message) do
    if Application.get_env(:alplus, :monitor_scheduler_enabled?, true) do
      GenServer.call(__MODULE__, message)
    else
      :ok
    end
  end

  defp notify_rehydrated do
    if Process.whereis(Alplus.PubSub) do
      Phoenix.PubSub.broadcast(
        Alplus.PubSub,
        "monitor:scheduler",
        {:monitor_scheduler_rehydrated, self()}
      )
    end
  end
end
