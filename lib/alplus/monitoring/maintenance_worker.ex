defmodule Alplus.Monitoring.MaintenanceWorker do
  @moduledoc false

  use Oban.Worker, queue: :telemetry, max_attempts: 3

  alias Alplus.Monitoring.{Retention, Rollup}
  alias Alplus.Scope

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "daily"}}) do
    finalize_yesterday()
    prune_history()
    :ok
  end

  def perform(%Oban.Job{}) do
    finalize_yesterday()
    :ok
  end

  defp finalize_yesterday do
    day = Date.add(Date.utc_today(), -1)

    Alplus.Repo.query!("SELECT id, org_id, project_id FROM monitors").rows
    |> Enum.each(fn [monitor_id, org_id, project_id] ->
      {:ok, _rollup} = Rollup.finalize(scope(org_id, project_id), monitor_id, day)
    end)
  end

  defp prune_history do
    Alplus.Repo.query!("SELECT org_id, id FROM projects").rows
    |> Enum.each(fn [org_id, project_id] ->
      scoped = scope(org_id, project_id)
      Retention.prune_monitor_checks(scoped, DateTime.utc_now())
      Rollup.prune(scoped, Date.utc_today())
    end)

    Retention.prune_heartbeat_ping_deduplications(DateTime.utc_now())
  end

  defp scope(org_id, project_id), do: %Scope{org_id: org_id, project_id: project_id}
end
