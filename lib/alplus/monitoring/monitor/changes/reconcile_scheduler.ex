defmodule Alplus.Monitoring.Monitor.Changes.ReconcileScheduler do
  @moduledoc false

  use Ash.Resource.Change
  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, monitor} ->
          reconcile_scheduler(monitor.id)

          Phoenix.PubSub.broadcast(
            Alplus.PubSub,
            "monitor:#{monitor.project_id}",
            {:monitor_updated, monitor.project_id}
          )

        _ ->
          :ok
      end

      result
    end)
  end

  # The scheduler reconciles on its own tick, so a failed reconcile here
  # must not fail the underlying Ash action. It is logged, never swallowed silently.
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
