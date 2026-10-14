defmodule Alplus.Billing.ReconciliationWorker do
  @moduledoc "Runs daily reconciliation when a Stripe adapter is configured."

  use Oban.Worker, queue: :billing, max_attempts: 3

  alias Alplus.Billing.Reconciliation

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"stripe_environment" => environment}}) do
    case Application.fetch_env(:alplus, :stripe_reconciliation_adapter) do
      {:ok, adapter} -> Reconciliation.reconcile(adapter, environment)
      :error -> {:cancel, "Stripe reconciliation adapter is not configured"}
    end
  end

  def perform(%Oban.Job{}) do
    perform(%Oban.Job{
      args: %{"stripe_environment" => Application.get_env(:alplus, :stripe_environment, "local")}
    })
  end
end
