defmodule Alplus.Billing.UsageRolloverWorker do
  @moduledoc false

  use Oban.Worker, queue: :billing, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Alplus.Billing.UsageRollover.rollover(Date.utc_today())
    :ok
  end
end
