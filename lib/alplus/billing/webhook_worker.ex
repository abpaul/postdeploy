defmodule Alplus.Billing.WebhookWorker do
  @moduledoc """
  Durable worker for the normalized fields required by Stripe billing events.

  The controller removes all third-party fields outside the billing allowlist
  before this job is inserted. The worker receives only JSON maps and IDs.
  """

  use Oban.Worker, queue: :billing, max_attempts: 10

  alias Alplus.Billing.WebhookProcessor

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event" => event, "stripe_environment" => environment}}) do
    case WebhookProcessor.process(event, environment) do
      {:ok, _result} -> :ok
      {:error, :event_is_being_processed} -> {:snooze, 5}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, "invalid Stripe webhook job"}
end
