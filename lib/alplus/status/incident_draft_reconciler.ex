defmodule Alplus.Status.IncidentDraftReconciler do
  @moduledoc false

  use GenServer

  @interval :timer.minutes(1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)

  @impl true
  def init(:ok) do
    schedule_reconcile()
    {:ok, nil}
  end

  @impl true
  def handle_info(:reconcile, state) do
    Alplus.Status.IncidentDraftWorker.reconcile_pending()
    schedule_reconcile()
    {:noreply, state}
  end

  defp schedule_reconcile do
    case Application.get_env(:alplus, :incident_draft_reconcile_interval_ms, @interval) do
      interval when is_integer(interval) and interval > 0 ->
        Process.send_after(self(), :reconcile, interval)

      _ ->
        :ok
    end
  end
end
