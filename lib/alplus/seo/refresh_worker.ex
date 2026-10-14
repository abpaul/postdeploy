defmodule Alplus.Seo.RefreshWorker do
  @moduledoc false
  use Oban.Worker,
    queue: :telemetry,
    max_attempts: 1,
    unique: [period: 7 * 24 * 60 * 60, keys: [:refresh_id]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"refresh_id" => refresh_id}}),
    do: Alplus.Seo.Refresher.run(refresh_id)
end
