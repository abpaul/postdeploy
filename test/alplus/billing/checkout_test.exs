defmodule Alplus.Billing.CheckoutTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Billing.{Checkout, StripeCustomer, Subscription}

  @stripe_options [
    adapter: Alplus.Billing.StripeAdapter.Fake,
    stripe_environment: "local",
    price_id: "price_postdeploy_monthly",
    base_url: "https://alplus.test"
  ]

  test "creates a monthly subscription Checkout session with tax and immutable billing metadata" do
    user = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(user.id))

    assert {:ok, "https://checkout.stripe.test/session"} =
             Checkout.create_checkout(owner_scope, org.id, @stripe_options)

    assert_receive {:stripe_checkout, params}
    assert params.mode == :subscription
    assert params.line_items == [%{price: "price_postdeploy_monthly", quantity: 1}]
    assert params.automatic_tax == %{enabled: true}
    # Without this, Stripe Checkout renders no promotion-code field at all, so
    # a coupon created in the dashboard is unredeemable.
    assert params.allow_promotion_codes == true
    # Stripe rejects a session that sets both, so this must stay absent.
    refute Map.has_key?(params, :discounts)

    assert params.metadata == %{"org_id" => org.id}
    assert params.subscription_data.metadata == %{"org_id" => org.id}
    assert params.client_reference_id == org.id

    # First purchase: no mirrored customer yet, so PostDeploy supplies the email and
    # Checkout opens prefilled instead of with an empty field.
    refute Map.has_key?(params, :customer)
    assert params.customer_email == to_string(user.email)

    assert params.success_url ==
             "https://alplus.test/dashboard/orgs/#{org.public_token}/billing?checkout=success"

    assert params.cancel_url ==
             "https://alplus.test/dashboard/orgs/#{org.public_token}/billing?checkout=cancel"
  end

  test "reuses the mirrored Stripe customer for Checkout and Portal" do
    user = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(user.id))

    Ash.create!(
      StripeCustomer,
      %{org_id: org.id, stripe_environment: "local", stripe_customer_id: "cus_123"},
      action: :record,
      authorize?: false
    )

    assert {:ok, "https://checkout.stripe.test/session"} =
             Checkout.create_checkout(owner_scope, org.id, @stripe_options)

    assert_receive {:stripe_checkout, checkout_params}
    assert checkout_params.customer == "cus_123"

    # Stripe prefills from the customer record here and rejects a session
    # carrying both, so PostDeploy must not send an email of its own.
    refute Map.has_key?(checkout_params, :customer_email)

    assert {:ok, "https://billing.stripe.test/session"} =
             Checkout.create_portal(owner_scope, org.id, @stripe_options)

    expected_return_url = "https://alplus.test/dashboard/orgs/#{org.public_token}/billing"
    assert_receive {:stripe_portal, %{customer: "cus_123", return_url: ^expected_return_url}}
  end

  test "refuses a paying organization so one Stripe customer keeps one subscription" do
    for status <- [:active, :past_due] do
      {org, owner_scope} = paying_org(status)

      assert {:error, :subscription_already_active} =
               Checkout.create_checkout(owner_scope, org.id, @stripe_options)

      refute_receive {:stripe_checkout, _params}
    end
  end

  test "lets a lapsed organization subscribe again" do
    {org, owner_scope} = paying_org(:canceled)

    assert {:ok, "https://checkout.stripe.test/session"} =
             Checkout.create_checkout(owner_scope, org.id, @stripe_options)

    assert_receive {:stripe_checkout, %{line_items: [%{price: "price_postdeploy_monthly"}]}}
  end

  test "rejects admins, an unconfigured price, and a portal without a customer" do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    admin = user_fixture()
    admin_scope = member_fixture(owner_scope, org, admin, "admin")

    assert {:error, :billing_owner_required} =
             Checkout.create_checkout(admin_scope, org.id, @stripe_options)

    assert {:error, :stripe_price_not_configured} =
             Checkout.create_checkout(
               owner_scope,
               org.id,
               Keyword.put(@stripe_options, :price_id, "")
             )

    assert {:error, :stripe_customer_missing} =
             Checkout.create_portal(owner_scope, org.id, @stripe_options)
  end

  defp paying_org(status) do
    user = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(user.id))
    subscribed_fixture(org)

    Ash.create!(
      Subscription,
      %{
        org_id: org.id,
        stripe_environment: "local",
        stripe_subscription_id: "sub_#{status}",
        status: status,
        current_period_start: ~U[2026-08-01 00:00:00.000000Z],
        current_period_end: ~U[2026-09-01 00:00:00.000000Z]
      },
      action: :record,
      authorize?: false
    )

    {org, owner_scope}
  end
end
