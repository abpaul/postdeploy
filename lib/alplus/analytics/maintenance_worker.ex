defmodule Alplus.Analytics.MaintenanceWorker do
  @moduledoc """
  Daily product-analytics retention (ADR 0007).

  One pass across every project, because retention is a fixed package window
  rather than a per-project setting. Idempotent: a second run inside the same
  day deletes nothing.
  """

  use Oban.Worker, queue: :telemetry, max_attempts: 3

  require Logger

  alias Alplus.Analytics.RetentionPolicy

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    deleted = RetentionPolicy.prune(Date.utc_today())
    Logger.info("analytics retention pruned #{deleted} events")
    :ok
  end
end
