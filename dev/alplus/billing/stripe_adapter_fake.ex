defmodule Alplus.Billing.StripeAdapter.Fake do
  @moduledoc """
  The Stripe double, for `:dev` and `:test`.

  It lives under `dev/` rather than `test/support/` because `config/dev.exs`
  names it as `:stripe_adapter`, and `mix.exs` compiles `test/support` only in
  `:test` — so in dev the configured module did not exist, and every Choose
  plan / Manage subscription click raised
  `UndefinedFunctionError` and took the Billing LiveView down with it. `dev/`
  is on `elixirc_paths` for both `:dev` and `:test`, and on neither for
  `:prod`, so this fake reaches a release in no environment.

  The `send(self(), …)` calls are the test seam: `checkout_test.exs` and
  `stripe_webhook_controller_test.exs` assert on those messages. Any LiveView
  that triggers this adapter therefore needs a catch-all `handle_info/2`, or
  the message it posts to itself has no matching clause.
  """

  @behaviour Alplus.Billing.StripeAdapter

  @impl true
  def create_checkout_session(params) do
    send(self(), {:stripe_checkout, params})
    {:ok, "https://checkout.stripe.test/session"}
  end

  @impl true
  def create_portal_session(params) do
    send(self(), {:stripe_portal, params})
    {:ok, "https://billing.stripe.test/session"}
  end
end
