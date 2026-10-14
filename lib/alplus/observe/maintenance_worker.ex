defmodule Alplus.Observe.MaintenanceWorker do
  @moduledoc false

  use Oban.Worker, queue: :telemetry, max_attempts: 3

  alias Alplus.Observe.{PayloadStorageWorker, Retention}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    Alplus.Repo.query!("SELECT id FROM organizations").rows
    |> Enum.each(fn [org_id] -> Retention.prune(org_id, now) end)

    Retention.prune_session_dedup(now)
    PayloadStorageWorker.replay_stranded(now)

    :ok
  end
end
