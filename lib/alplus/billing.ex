defmodule Alplus.Billing do
  @moduledoc "Durable local mirror of Stripe-owned billing state."

  use Ash.Domain, otp_app: :alplus

  resources do
    resource Alplus.Billing.TrialClaim do
      define :claim_trial, action: :claim
    end

    resource Alplus.Billing.StripeCustomer do
      define :get_stripe_customer, action: :read, get_by: [:id]
    end

    resource Alplus.Billing.Subscription do
      define :get_subscription, action: :read, get_by: [:id]
      define :list_subscriptions, action: :read
    end

    resource Alplus.Billing.Invoice do
      define :list_invoices, action: :list_for_org, args: [:stripe_environment]
    end

    resource Alplus.Billing.StripeWebhookEvent
  end
end
