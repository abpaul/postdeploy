defmodule Alplus.Billing.StripeAdapter do
  @moduledoc """
  Narrow boundary around StripityStripe.

  Keeping the Stripe calls here makes the Billing service deterministic in
  tests and prevents LiveViews from knowing Stripe request shapes.
  """

  @callback create_checkout_session(map()) :: {:ok, String.t()} | {:error, term()}
  @callback create_portal_session(map()) :: {:ok, String.t()} | {:error, term()}

  # stripity_stripe 3.3's PLT-derived success typing for
  # `Stripe.Checkout.Session.create/1` and `Stripe.BillingPortal.Session.create/1`
  # narrows to `{:error, Stripe.Error.t()}` only, so Dialyzer sees the
  # `{:ok, _}` clauses below as unreachable. That is a limitation of analyzing
  # the library's generated request code, not a bug here: both calls do
  # return `{:ok, _}` in production and in `Alplus.Billing.StripeAdapter.Fake`
  # (see `dev/alplus/billing/stripe_adapter_fake.ex`).
  @dialyzer {:nowarn_function, create_checkout_session: 1, create_portal_session: 1}

  def create_checkout_session(params) do
    case Stripe.Checkout.Session.create(params) do
      {:ok, %{url: url}} when is_binary(url) -> {:ok, url}
      {:ok, _session} -> {:error, :checkout_url_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_portal_session(params) do
    case Stripe.BillingPortal.Session.create(params) do
      {:ok, %{url: url}} when is_binary(url) -> {:ok, url}
      {:ok, _session} -> {:error, :portal_url_missing}
      {:error, reason} -> {:error, reason}
    end
  end
end
