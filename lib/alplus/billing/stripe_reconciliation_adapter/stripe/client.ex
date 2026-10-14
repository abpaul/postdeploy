defmodule Alplus.Billing.StripeReconciliationAdapter.Stripe.Client do
  @moduledoc false

  def list_subscriptions(params), do: Stripe.Subscription.list(params)
  def list_invoices(params), do: Stripe.Invoice.list(params)
end
