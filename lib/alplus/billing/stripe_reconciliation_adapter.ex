defmodule Alplus.Billing.StripeReconciliationAdapter do
  @moduledoc """
  Boundary for the daily Stripe read reconciliation.

  The Stripe client implementation belongs behind this behaviour so the local
  Billing mirror has no dependency on a particular HTTP library.
  """

  @callback list_subscriptions(String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback list_invoices(String.t()) :: {:ok, [map()]} | {:error, term()}
end
