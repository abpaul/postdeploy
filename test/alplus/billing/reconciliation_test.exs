defmodule Alplus.Billing.ReconciliationTest do
  use Alplus.DataCase, async: true

  alias Alplus.Billing.Access
  alias Alplus.Billing.Reconciliation
  alias Alplus.OrgsFixtures
  alias Alplus.Repo

  defmodule Adapter do
    @behaviour Alplus.Billing.StripeReconciliationAdapter

    @impl true
    def list_subscriptions(_environment), do: Process.get(:subscriptions, {:ok, []})

    @impl true
    def list_invoices(_environment), do: {:ok, Process.get(:invoices, [])}
  end

  test "two active subscriptions on one customer mirror the newest in either list order" do
    org = org()

    newer =
      subscription("sub_newer",
        org_id: org.id,
        lookup_key: "postdeploy_monthly_usd",
        created: 2_000
      )

    older =
      subscription("sub_older",
        org_id: org.id,
        lookup_key: "postdeploy_monthly_usd",
        created: 1_000
      )

    # Stripe lists newest first; the mirror must not depend on that order.
    Process.put(:subscriptions, {:ok, [newer, older]})
    assert :ok = Reconciliation.reconcile(Adapter, "local")
    assert mirrored(org) == ["sub_newer", "active"]
    assert {:ok, :subscribed} = Access.check(org.id)

    Process.put(:subscriptions, {:ok, [older, newer]})
    assert :ok = Reconciliation.reconcile(Adapter, "local")
    assert mirrored(org) == ["sub_newer", "active"]
    assert {:ok, :subscribed} = Access.check(org.id)
  end

  test "a newer canceled subscription does not replace an older active one" do
    org = org()

    Process.put(
      :subscriptions,
      {:ok,
       [
         subscription("sub_canceled",
           org_id: org.id,
           lookup_key: "postdeploy_monthly_usd",
           status: "canceled",
           created: 3_000
         ),
         subscription("sub_active",
           org_id: org.id,
           lookup_key: "postdeploy_monthly_usd",
           created: 1_000
         )
       ]}
    )

    assert :ok = Reconciliation.reconcile(Adapter, "local")
    assert mirrored(org) == ["sub_active", "active"]
    assert {:ok, :subscribed} = Access.check(org.id)
  end

  test "a customer whose only subscription is canceled mirrors the canceled state" do
    org = org()

    Process.put(
      :subscriptions,
      {:ok,
       [
         subscription("sub_gone_recent",
           org_id: org.id,
           lookup_key: "postdeploy_monthly_usd",
           status: "canceled",
           created: 3_000
         ),
         subscription("sub_gone_old",
           org_id: org.id,
           lookup_key: "postdeploy_monthly_usd",
           status: "canceled",
           created: 1_000
         )
       ]}
    )

    assert :ok = Reconciliation.reconcile(Adapter, "local")
    assert mirrored(org) == ["sub_gone_recent", "canceled"]
    assert {:error, %{reason: :plan_inactive}} = Access.check(org.id)
  end

  test "each customer mirrors its own winner" do
    first = org()
    second = org()

    Process.put(
      :subscriptions,
      {:ok,
       [
         subscription("sub_second",
           org_id: second.id,
           customer: "cus_second",
           lookup_key: "postdeploy_monthly_usd",
           created: 4_000
         ),
         subscription("sub_first",
           org_id: first.id,
           customer: "cus_first",
           lookup_key: "postdeploy_monthly_usd",
           created: 3_000
         ),
         subscription("sub_second_indie",
           org_id: second.id,
           customer: "cus_second",
           lookup_key: "postdeploy_monthly_usd",
           created: 2_000
         ),
         subscription("sub_first_canceled",
           org_id: first.id,
           customer: "cus_first",
           lookup_key: "postdeploy_monthly_usd",
           status: "canceled",
           created: 1_000
         )
       ]}
    )

    assert :ok = Reconciliation.reconcile(Adapter, "local")
    assert mirrored(first) == ["sub_first", "active"]
    assert mirrored(second) == ["sub_second", "active"]
  end

  test "a subscription that cannot be read is reported, not dropped" do
    org = org()

    Process.put(
      :subscriptions,
      {:ok, [subscription("sub_no_package", org_id: org.id, lookup_key: nil, created: 1_000)]}
    )

    assert {:error, {:invalid, :package}} = Reconciliation.reconcile(Adapter, "local")
  end

  test "a response that is not a list is refused" do
    Process.put(:subscriptions, {:ok, %{"data" => []}})

    assert {:error, :invalid_reconciliation_response} = Reconciliation.reconcile(Adapter, "local")
  end

  defp org do
    owner = OrgsFixtures.scope_fixture()
    {org, _scope} = OrgsFixtures.org_fixture(owner)
    org
  end

  defp mirrored(org) do
    [row] =
      Repo.query!(
        "SELECT stripe_subscription_id, status FROM subscriptions WHERE org_id = $1 AND stripe_environment = 'local'",
        [org.id]
      ).rows

    row
  end

  # The live account keeps a canceled subscription on a retired price. It must
  # not stop the run, or nothing after it ever reconciles.
  test "a subscription on a retired price is skipped, and the rest still mirrors" do
    org = org()

    retired =
      subscription("sub_retired",
        org_id: org.id,
        customer: "cus_retired",
        lookup_key: "indie_founding_monthly_usd",
        status: "canceled",
        created: 1_000
      )

    current =
      subscription("sub_current",
        org_id: org.id,
        lookup_key: "postdeploy_monthly_usd",
        created: 2_000
      )

    Process.put(:subscriptions, {:ok, [retired, current]})
    Process.put(:invoices, [invoice("in_after_retired")])

    assert :ok = Reconciliation.reconcile(Adapter, "local")

    assert mirrored(org) == ["sub_current", "active"]
    assert {:ok, :subscribed} = Access.check(org.id)

    # The invoice pass runs only when the subscription pass finished.
    assert [["in_after_retired"]] = Repo.query!("SELECT stripe_invoice_id FROM invoices").rows
  end

  defp invoice(id) do
    %{
      "id" => id,
      "customer" => "cus_shared",
      "amount_due" => 2_900,
      "amount_paid" => 2_900,
      "currency" => "usd",
      "status" => "paid",
      "period_start" => 100,
      "period_end" => 10_000
    }
  end

  defp subscription(id, opts) do
    %{
      "id" => id,
      "customer" => Keyword.get(opts, :customer, "cus_shared"),
      "status" => Keyword.get(opts, :status, "active"),
      "created" => Keyword.fetch!(opts, :created),
      "cancel_at_period_end" => false,
      "items" => %{
        "data" => [
          %{
            "current_period_start" => 100,
            "current_period_end" => 10_000,
            "price" => %{
              "lookup_key" => Keyword.fetch!(opts, :lookup_key),
              "recurring" => %{"interval" => "month"}
            }
          }
        ]
      },
      "metadata" => %{"org_id" => Keyword.fetch!(opts, :org_id)}
    }
  end
end
