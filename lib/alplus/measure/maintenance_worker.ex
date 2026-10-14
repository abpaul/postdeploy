defmodule Alplus.Measure.MaintenanceWorker do
  @moduledoc false

  use Oban.Worker, queue: :telemetry, max_attempts: 3

  alias Alplus.Measure.{Retention, VisitorSalt}
  alias Alplus.Scope

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Alplus.Repo.query!("""
    SELECT org_id, id FROM projects
    """).rows
    |> Enum.each(fn [org_id, project_id] ->
      Retention.prune(%Scope{org_id: org_id, project_id: project_id}, Date.utc_today())
    end)

    VisitorSalt.prune(Date.utc_today())
    :ok
  end
end
