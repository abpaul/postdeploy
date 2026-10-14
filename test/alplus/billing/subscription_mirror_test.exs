defmodule Alplus.Billing.SubscriptionMirrorTest do
  use Alplus.DataCase, async: true

  alias Alplus.Billing.{Invoice, StripeCustomer, Subscription}
  alias Alplus.OrgsFixtures

  test "billing rows are visible only inside the actor organization" do
    owner = OrgsFixtures.scope_fixture()
    {org, owner_scope} = OrgsFixtures.org_fixture(owner)
    other_owner = OrgsFixtures.scope_fixture()
    {_other_org, other_scope} = OrgsFixtures.org_fixture(other_owner)

    customer =
      Ash.create!(
        StripeCustomer,
        %{org_id: org.id, stripe_environment: "local", stripe_customer_id: "cus_123"},
        action: :record,
        authorize?: false
      )

    period_start = DateTime.utc_now()
    period_end = DateTime.add(period_start, 30, :day)

    subscription =
      Ash.create!(
        Subscription,
        %{
          org_id: org.id,
          stripe_environment: "local",
          stripe_subscription_id: "sub_123",
          status: :active,
          current_period_start: period_start,
          current_period_end: period_end
        },
        action: :record,
        authorize?: false
      )

    invoice =
      Ash.create!(
        Invoice,
        %{
          org_id: org.id,
          stripe_environment: "local",
          stripe_invoice_id: "in_123",
          amount_due: 1_900,
          amount_paid: 1_900,
          currency: "usd",
          status: :paid,
          period_start: period_start,
          period_end: period_end
        },
        action: :record,
        authorize?: false
      )

    assert [%{id: customer_id}] = Ash.read!(StripeCustomer, actor: owner_scope)
    assert customer_id == customer.id

    assert [%{id: subscription_id}] = Ash.read!(Subscription, actor: owner_scope)
    assert subscription_id == subscription.id

    assert [%{id: invoice_id}] =
             Invoice
             |> Ash.Query.for_read(:list_for_org, %{stripe_environment: "local"},
               actor: owner_scope
             )
             |> Ash.read!()

    assert invoice_id == invoice.id

    assert [] = Ash.read!(StripeCustomer, actor: other_scope)
    assert [] = Ash.read!(Subscription, actor: other_scope)

    assert [] =
             Invoice
             |> Ash.Query.for_read(:list_for_org, %{stripe_environment: "local"},
               actor: other_scope
             )
             |> Ash.read!()
  end
end
