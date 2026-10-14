defmodule Alplus.Billing.Checkout do
  @moduledoc """
  Creates short-lived Stripe Checkout and Customer Portal sessions.

  Stripe remains the payment authority. The webhook processor is the only
  path that changes the local billing mirror after a successful checkout.

  Checkout only ever creates a subscription, so it refuses an organization
  that already has an active or past-due subscription mirrored. On 2026-09-10
  a paying organization bought a second subscription here and ended up with
  two active subscriptions on one Stripe customer; the mirror holds one row
  per `(org_id, stripe_environment)`, so the nightly reconciliation wrote both
  Stripe subscriptions into that row. PostDeploy sells one package at one
  monthly price. A paying organization manages or cancels its subscription in
  the Stripe Customer Portal.
  """

  require Ash.Query

  alias Alplus.Billing.StripeCustomer
  alias Alplus.Billing.Subscription

  @type result :: {:ok, String.t()} | {:error, atom() | term()}

  @doc "Opens Checkout for the PostDeploy package, billed monthly."
  @spec create_checkout(Alplus.Scope.t(), String.t(), keyword()) :: result()
  def create_checkout(scope, org_id, opts \\ []) do
    with :ok <- authorize_billing(scope, org_id),
         {:ok, environment} <- environment(opts),
         :ok <- no_live_subscription(scope, org_id, environment),
         {:ok, price_id} <- price_id(opts),
         {:ok, customer_id} <- customer_id(scope, org_id, environment),
         {:ok, buyer_email} <- buyer_email(scope, customer_id),
         {:ok, routes} <- routes(scope, org_id, opts) do
      params =
        %{
          mode: :subscription,
          line_items: [%{price: price_id, quantity: 1}],
          automatic_tax: %{enabled: true},
          # Renders Stripe Checkout's "Add promotion code" field, so a coupon
          # created in the dashboard can be redeemed by the customer. Founder
          # decision 2026-08-20: needed to exercise a real subscription in
          # production against a 100%-off code, and it is how a comped account
          # gets set up thereafter.
          #
          # Mutually exclusive with Stripe's `discounts:` param — passing both
          # is an API error. Apply a coupon server-side instead of here only if
          # this flag is removed.
          #
          # A 100%-off code still collects a card unless the session also sets
          # `payment_method_collection: :if_required`. That is deliberately not
          # set: a card on file with a $0 charge is the correct outcome for a
          # discount that expires, and it keeps this change to one key.
          allow_promotion_codes: true,
          metadata: %{"org_id" => org_id},
          subscription_data: %{metadata: %{"org_id" => org_id}},
          success_url: routes.success_url,
          cancel_url: routes.cancel_url,
          client_reference_id: org_id
        }
        |> put_customer(customer_id)
        |> put_customer_email(buyer_email)

      adapter(opts).create_checkout_session(params)
    end
  end

  @spec create_portal(Alplus.Scope.t(), String.t(), keyword()) :: result()
  def create_portal(scope, org_id, opts \\ []) do
    with :ok <- authorize_billing(scope, org_id),
         {:ok, environment} <- environment(opts),
         {:ok, customer_id} <- required_customer_id(scope, org_id, environment),
         {:ok, routes} <- routes(scope, org_id, opts) do
      adapter(opts).create_portal_session(%{customer: customer_id, return_url: routes.return_url})
    end
  end

  defp authorize_billing(%Alplus.Scope{org_id: org_id, role: "owner"}, org_id), do: :ok
  defp authorize_billing(_, _), do: {:error, :billing_owner_required}

  defp environment(opts) do
    case Keyword.fetch(opts, :stripe_environment) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _} -> {:error, :invalid_stripe_environment}
      :error -> Application.fetch_env(:alplus, :stripe_environment)
    end
  end

  defp price_id(opts) do
    price_id =
      Keyword.get_lazy(opts, :price_id, fn ->
        Application.fetch_env!(:alplus, :stripe_price_id)
      end)

    if is_binary(price_id) and price_id != "",
      do: {:ok, price_id},
      else: {:error, :stripe_price_not_configured}
  rescue
    ArgumentError -> {:error, :stripe_price_not_configured}
  end

  # A second Stripe subscription on one customer is what the mirror cannot
  # represent, so the refusal lives here, at the click a buyer can act on,
  # rather than at the webhook that would later pick a winner.
  defp no_live_subscription(scope, org_id, environment) do
    subscriptions =
      Ash.read!(
        Ash.Query.filter(
          Subscription,
          org_id == ^org_id and stripe_environment == ^environment
        ),
        actor: scope
      )

    case subscriptions do
      [%Subscription{status: status}] when status in [:active, :past_due] ->
        {:error, :subscription_already_active}

      _ ->
        :ok
    end
  rescue
    Ash.Error.Invalid -> {:error, :stripe_subscription_lookup_failed}
  end

  defp customer_id(scope, org_id, environment) do
    customers =
      Ash.read!(
        Ash.Query.filter(
          StripeCustomer,
          org_id == ^org_id and stripe_environment == ^environment
        ),
        actor: scope
      )

    case customers do
      [%StripeCustomer{stripe_customer_id: customer_id}] -> {:ok, customer_id}
      [] -> {:ok, nil}
    end
  rescue
    Ash.Error.Invalid -> {:error, :stripe_customer_lookup_failed}
  end

  defp required_customer_id(scope, org_id, environment) do
    case customer_id(scope, org_id, environment) do
      {:ok, customer_id} when is_binary(customer_id) -> {:ok, customer_id}
      {:ok, nil} -> {:error, :stripe_customer_missing}
      error -> error
    end
  end

  defp routes(scope, org_id, opts) do
    base_url = Keyword.get_lazy(opts, :base_url, &AlplusWeb.Endpoint.url/0)
    uri = URI.parse(base_url)

    with {:ok, organization} <- Alplus.Orgs.get_organization(org_id, actor: scope),
         %{scheme: scheme, host: host} <- uri,
         true <- scheme in ["http", "https"] and is_binary(host) and host != "" do
      origin = URI.to_string(%URI{scheme: scheme, host: host, port: uri.port})
      billing = origin <> "/dashboard/orgs/" <> organization.public_token <> "/billing"

      {:ok,
       %{
         success_url: billing <> "?checkout=success",
         cancel_url: billing <> "?checkout=cancel",
         return_url: billing
       }}
    else
      _ -> {:error, :billing_base_url_not_configured}
    end
  rescue
    ArgumentError -> {:error, :billing_base_url_not_configured}
  end

  defp adapter(opts),
    do:
      Keyword.get(
        opts,
        :adapter,
        Application.get_env(:alplus, :stripe_adapter, Alplus.Billing.StripeAdapter)
      )

  defp put_customer(params, nil), do: params
  defp put_customer(params, customer_id), do: Map.put(params, :customer, customer_id)

  defp put_customer_email(params, nil), do: params
  defp put_customer_email(params, email), do: Map.put(params, :customer_email, email)

  # Stripe prefills (and locks) the email from the customer record whenever the
  # session carries a `customer`, and rejects a session that sets both
  # `customer` and `customer_email`. So the email is only ours to supply on a
  # first purchase, which is exactly the case that used to open Checkout with
  # an empty field.
  #
  # Supplying it is not only convenience: without it a buyer can type a
  # different address into Stripe than the one they signed in with, and the
  # mirrored `StripeCustomer` then reconciles against an email PostDeploy has never
  # seen.
  #
  # `authorize_billing/2` has already established the actor is this org's
  # owner, and `User`'s read policy authorizes `id == ^actor(:user_id)`, so
  # this read cannot legitimately fail. It is still threaded through the `with`
  # chain rather than defaulted away: a missing actor row here is a broken
  # invariant, not something to paper over with a blank field.
  defp buyer_email(_scope, customer_id) when is_binary(customer_id), do: {:ok, nil}

  defp buyer_email(scope, nil) do
    case Ash.get(Alplus.Accounts.User, scope.user_id, actor: scope) do
      # `email` is an `Ash.CiString`, never a binary — Stripe needs the string.
      {:ok, %{email: email}} when not is_nil(email) -> {:ok, to_string(email)}
      _ -> {:error, :billing_actor_email_unavailable}
    end
  end
end
