defmodule Alplus.Growth.RetentionWorker do
  @moduledoc """
  Durable daily entry point for health-check journey retention.
  """

  use Oban.Worker, queue: :telemetry, unique: [period: 60]

  @impl true
  def perform(_job) do
    Alplus.Growth.Retention.prune(DateTime.utc_now())
    :ok
  end
end
