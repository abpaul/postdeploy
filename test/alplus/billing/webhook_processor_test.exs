defmodule Alplus.Billing.WebhookProcessorTest do
  use Alplus.DataCase, async: true

  alias Alplus.Billing.WebhookProcessor
  alias Alplus.OrgsFixtures
  alias Alplus.Repo

  defmodule ReconciliationAdapter do
    @behaviour Alplus.Billing.StripeReconciliationAdapter

    @impl true
    def list_subscriptions(_environment), do: {:ok, Process.get(:billing_subscriptions, [])}

    @impl true
    def list_invoices(_environment), do: {:ok, Process.get(:billing_invoices, [])}
  end

  defmodule StripeSubscriptionItems do
    defstruct [:data]
  end

  defmodule StripeSubscriptionItem do
    defstruct [:current_period_start, :current_period_end, :price]
  end

  test "records a checkout, mirrors an active subscription, and replays as a no-op" do
    owner = OrgsFixtures.scope_fixture()
    {org, _scope} = OrgsFixtures.org_fixture(owner)

    assert org.billing_status == :trialing

    assert [["trialing"]] =
             Repo.query!("SELECT plan_status FROM organizations WHERE id = $1", [org.id]).rows

    assert {:ok, :processed} =
             WebhookProcessor.process(checkout_event(org.id), "local")

    assert [[customer_org_id, "cus_checkout"]] =
             Repo.query!(
               "SELECT org_id, stripe_customer_id FROM stripe_customers WHERE stripe_environment = 'local'"
             ).rows

    assert customer_org_id == org.id

    assert [["trialing"]] =
             Repo.query!("SELECT plan_status FROM organizations WHERE id = $1", [org.id]).rows

    event = subscription_event("evt_subscription_created", "active", 200)
    assert {:ok, :processed} = WebhookProcessor.process(event, "local")
    assert {:ok, :already_processed} = WebhookProcessor.process(event, "local")

    assert [["sub_123", "active"]] =
             Repo.query!(
               "SELECT stripe_subscription_id, status FROM subscriptions WHERE org_id = $1",
               [org.id]
             ).rows

    assert {:ok, :subscribed} = Alplus.Billing.Access.check(org.id)

    assert [["processed", 1]] =
             Repo.query!(
               "SELECT status, attempt_count FROM stripe_webhook_events WHERE stripe_event_id = 'evt_subscription_created'"
             ).rows
  end

  test "rejects a stale subscription update and keeps the canceled state" do
    owner = OrgsFixtures.scope_fixture()
    {org, _scope} = OrgsFixtures.org_fixture(owner)
    assert {:ok, :processed} = WebhookProcessor.process(checkout_event(org.id), :local)

    assert {:ok, :processed} =
             WebhookProcessor.process(subscription_event("evt_canceled", "canceled", 300), :local)

    assert {:ok, :processed} =
             WebhookProcessor.process(
               subscription_event("evt_stale_active", "active", 300),
               :local
             )

    assert [["canceled"]] =
             Repo.query!("SELECT status FROM subscriptions WHERE org_id = $1", [org.id]).rows

    assert {:error, %Alplus.Billing.EntitlementError{cause: :subscription_lapsed}} =
             Alplus.Billing.Access.check(org.id)
  end

  test "checkout metadata alone cannot move the organization out of trial" do
    owner = OrgsFixtures.scope_fixture()
    {org, _scope} = OrgsFixtures.org_fixture(owner)

    assert {:ok, :processed} =
             WebhookProcessor.process(checkout_event(org.id, "postdeploy"), :local)

    assert [["trialing"]] =
             Repo.query!("SELECT plan_status FROM organizations WHERE id = $1", [org.id]).rows
  end

  test "a delayed checkout cannot reactivate a canceled subscription" do
    owner = OrgsFixtures.scope_fixture()
    {org, _scope} = OrgsFixtures.org_fixture(owner)
    assert {:ok, :processed} = WebhookProcessor.process(checkout_event(org.id), :local)

    assert {:ok, :processed} =
             WebhookProcessor.process(
               subscription_event("evt_canceled_first", "canceled", 300),
               :local
             )

    assert {:ok, :processed} =
             WebhookProcessor.process(
               checkout_event(org.id, "postdeploy", "evt_checkout_delayed"),
               :local
             )

    assert {:error, %Alplus.Billing.EntitlementError{cause: :subscription_lapsed}} =
             Alplus.Billing.Access.check(org.id)
  end

  test "authoritative reconciliation repairs state after a newer webhook" do
    owner = OrgsFixtures.scope_fixture()
    {org, _scope} = OrgsFixtures.org_fixture(owner)
    assert {:ok, :processed} = WebhookProcessor.process(checkout_event(org.id), :local)

    assert {:ok, :processed} =
             WebhookProcessor.process(
               subscription_event("evt_canceled_newer", "canceled", 300),
               :local
             )

    assert :ok =
             WebhookProcessor.reconcile_subscription(
               %{
                 "id" => "sub_123",
                 "customer" => "cus_checkout",
                 "status" => "active",
                 "current_period_start" => 100,
                 "current_period_end" => 10_000,
                 "created" => 100,
                 "cancel_at_period_end" => false,
                 "items" => %{
                   "data" => [
                     %{
                       "price" => %{
                         "lookup_key" => "postdeploy_monthly_usd",
                         "recurring" => %{"interval" => "month"}
                       }
                     }
                   ]
                 },
                 "metadata" => %{"plan_id" => "postdeploy", "billing_interval" => "monthly"}
               },
               :local
             )

    assert {:ok, :subscribed} = Alplus.Billing.Access.check(org.id)
  end

  test "mirrors invoice events only through the Stripe customer tenant mapping" do
    owner = OrgsFixtures.scope_fixture()
    {org, _scope} = OrgsFixtures.org_fixture(owner)
    assert {:ok, :processed} = WebhookProcessor.process(checkout_event(org.id), :local)

    assert {:ok, :processed} = WebhookProcessor.process(invoice_event(), :local)

    assert [[invoice_org_id, 500, 500, "paid"]] =
             Repo.query!(
               "SELECT org_id, amount_due, amount_paid, status FROM invoices WHERE stripe_invoice_id = 'in_123'"
             ).rows

    assert invoice_org_id == org.id

    unknown_customer_event =
      put_in(invoice_event(), ["id"], "evt_unknown_invoice")
      |> put_in(["data", "object", "customer"], "cus_other")

    assert {:error, :unknown_stripe_customer} =
             WebhookProcessor.process(unknown_customer_event, :local)

    assert [["failed"]] =
             Repo.query!(
               "SELECT status FROM stripe_webhook_events WHERE stripe_event_id = 'evt_unknown_invoice'"
             ).rows
  end

  test "replaying an invoice.finalized/invoice.paid event is a no-op, and mirrors stay per-environment" do
    owner = OrgsFixtures.scope_fixture()
    {org, _scope} = OrgsFixtures.org_fixture(owner)
    assert {:ok, :processed} = WebhookProcessor.process(checkout_event(org.id), :local)

    finalized = put_in(invoice_event(), ["type"], "invoice.finalized")
    assert {:ok, :processed} = WebhookProcessor.process(finalized, :local)
    assert {:ok, :already_processed} = WebhookProcessor.process(finalized, :local)

    paid = put_in(invoice_event(), ["id"], "evt_invoice_paid")
    assert {:ok, :processed} = WebhookProcessor.process(paid, :local)
    # Same event id replayed under Stripe's own retry semantics: no new row.
    assert {:ok, :already_processed} = WebhookProcessor.process(paid, :local)

    assert [[1]] =
             Repo.query!(
               "SELECT count(*) FROM invoices WHERE stripe_invoice_id = 'in_123' AND stripe_environment = 'local'"
             ).rows

    # A staging customer mirror never resolves against the local invoice's
    # customer id, so the same Stripe invoice id in another environment
    # stays isolated (`stripe_invoice_id` is unique per `stripe_environment`,
    # not globally).
    staging_event =
      invoice_event()
      |> put_in(["id"], "evt_invoice_staging")
      |> put_in(["data", "object", "customer"], "cus_staging_unmapped")

    assert {:error, :unknown_stripe_customer} =
             WebhookProcessor.process(staging_event, :staging)

    assert [[1]] =
             Repo.query!("SELECT count(*) FROM invoices WHERE stripe_invoice_id = 'in_123'").rows
  end

  test "rejects invoice metadata that disagrees with the customer tenant mapping" do
    owner = OrgsFixtures.scope_fixture()
    {org, _scope} = OrgsFixtures.org_fixture(owner)
    other_owner = OrgsFixtures.scope_fixture()
    {other_org, _scope} = OrgsFixtures.org_fixture(other_owner)

    assert {:ok, :processed} = WebhookProcessor.process(checkout_event(org.id), :local)

    event =
      invoice_event()
      |> put_in(["id"], "evt_invoice_org_mismatch")
      |> put_in(["data", "object", "metadata"], %{"org_id" => other_org.id})

    assert {:error, :organization_mismatch} = WebhookProcessor.process(event, :local)
    assert [[0]] = Repo.query!("SELECT count(*) FROM invoices").rows
  end

  test "invalid environment, payload, and package fail without writing a row" do
    assert {:error, :invalid_environment} =
             WebhookProcessor.process(%{"type" => "invoice.paid", "id" => "evt_x"}, :nope)

    assert {:error, _} =
             WebhookProcessor.process(%{"type" => "invoice.paid", "id" => "evt_x"}, "local")

    assert {:error, _} =
             WebhookProcessor.process(
               %{
                 "id" => "evt_bad_package",
                 "type" => "customer.subscription.created",
                 "livemode" => false,
                 "created" => 1,
                 "data" => %{
                   "object" => %{
                     "id" => "sub_bad",
                     "customer" => "cus_missing",
                     "status" => "active",
                     "current_period_start" => 1,
                     "current_period_end" => 2,
                     "created" => 1,
                     "cancel_at_period_end" => false,
                     "metadata" => %{"plan_id" => "not-the-package"}
                   }
                 }
               },
               "local"
             )
  end

  test "ignores event types outside the seven Stripe billing event types" do
    assert {:ok, :ignored} =
             WebhookProcessor.process(
               %{"id" => "evt_ignore", "type" => "charge.refunded"},
               :local
             )
  end

  # Stripe's `2026-06-24.dahlia` moved the billing period off the Subscription
  # object onto each subscription item. Reading only the top level made every
  # `customer.subscription.*` event fail with `{:invalid, :period_start}`, so a
  # paying org stayed on its trial.
  test "mirrors a subscription whose period lives on the item, not the top level" do
    owner = OrgsFixtures.scope_fixture()
    {org, _scope} = OrgsFixtures.org_fixture(owner)

    assert {:ok, _} = WebhookProcessor.process(checkout_event(org.id), "local")

    event = %{
      "id" => "evt_item_period",
      "type" => "customer.subscription.created",
      "livemode" => false,
      "created" => 300,
      "data" => %{
        "object" => %{
          "id" => "sub_item_period",
          "customer" => "cus_checkout",
          "status" => "active",
          # Absent at the top level, exactly as Stripe now sends it.
          "items" => %{
            "data" => [
              %{
                "current_period_start" => 100,
                "current_period_end" => 10_000,
                "price" => %{
                  "lookup_key" => "postdeploy_monthly_usd",
                  "recurring" => %{"interval" => "month"}
                }
              }
            ]
          },
          "created" => 300,
          "cancel_at_period_end" => false,
          "metadata" => %{"plan_id" => "postdeploy", "billing_interval" => "monthly"}
        }
      }
    }

    assert {:ok, _} = WebhookProcessor.process(event, "local")

    assert [["active", start_at, end_at]] =
             Repo.query!(
               "SELECT status, current_period_start, current_period_end FROM subscriptions WHERE stripe_subscription_id = 'sub_item_period'"
             ).rows

    # Raw SQL hands back `NaiveDateTime`; unix 100 and 10_000 are the values
    # the event carried on its item.
    assert NaiveDateTime.compare(start_at, ~N[1970-01-01 00:01:40.000000]) == :eq
    assert NaiveDateTime.compare(end_at, ~N[1970-01-01 02:46:40.000000]) == :eq

    # The environment-scoped subscription wins without changing the global
    # organization mirror used by production compatibility reads.
    assert {:ok, :subscribed} = Alplus.Billing.Access.check(org.id)
  end

  test "a subscription with no period on the item or the top level is still rejected" do
    event = %{
      "id" => "evt_no_period",
      "type" => "customer.subscription.created",
      "livemode" => false,
      "created" => 300,
      "data" => %{
        "object" => %{
          "id" => "sub_no_period",
          "customer" => "cus_checkout",
          "status" => "active",
          "items" => %{
            "data" => [
              %{
                "price" => %{
                  "lookup_key" => "postdeploy_monthly_usd",
                  "recurring" => %{"interval" => "month"}
                }
              }
            ]
          },
          "created" => 300,
          "cancel_at_period_end" => false,
          "metadata" => %{"plan_id" => "postdeploy", "billing_interval" => "monthly"}
        }
      }
    }

    assert {:error, {:invalid, :period_start}} = WebhookProcessor.process(event, "local")
  end

  test "rejects an unsupported subscription cadence" do
    event =
      subscription_event("evt_invalid_cadence", "active", 400)
      |> put_in(["data", "object", "metadata", "billing_interval"], "quarterly")

    assert {:error, {:invalid, :billing_interval}} = WebhookProcessor.process(event, "local")
  end

  test "accepts the package from the Stripe price lookup key alone" do
    owner = OrgsFixtures.scope_fixture()
    {org, _scope} = OrgsFixtures.org_fixture(owner)
    assert {:ok, :processed} = WebhookProcessor.process(checkout_event(org.id), "local")

    event =
      subscription_event("evt_lookup_key", "active", 400)
      |> put_in(["data", "object", "metadata"], %{})
      |> put_in(
        ["data", "object", "items"],
        %{
          "data" => [
            %{
              "price" => %{
                "lookup_key" => "postdeploy_monthly_usd",
                "recurring" => %{"interval" => "month"}
              }
            }
          ]
        }
      )

    assert {:ok, :processed} = WebhookProcessor.process(event, "local")

    assert [["active"]] =
             Repo.query!(
               "SELECT status FROM subscriptions WHERE stripe_subscription_id = 'sub_123'"
             ).rows
  end

  # PostDeploy sells no annual price. A yearly subscription made by hand in the
  # Stripe dashboard must not be mirrored as the monthly package.
  test "rejects a retired or annual Stripe price" do
    for lookup_key <- ["postdeploy_annual_usd", "indie_founding_monthly_usd", "pro_annual_usd"] do
      event =
        subscription_event("evt_#{lookup_key}", "active", 400)
        |> put_in(["data", "object", "metadata"], %{})
        |> put_in(
          ["data", "object", "items"],
          %{"data" => [%{"price" => %{"lookup_key" => lookup_key}}]}
        )

      assert {:error, :unknown_package} = WebhookProcessor.process(event, "local")
    end
  end

  # Metadata is writable in the Stripe dashboard, so it can never stand in for
  # the price. Accepting it alone would mirror a subscription on a retired,
  # cheaper price as the package.
  test "refuses a subscription whose package is claimed only by metadata" do
    event =
      subscription_event("evt_metadata_only", "active", 400)
      |> put_in(["data", "object", "items"], %{"data" => [%{}]})

    assert {:error, {:invalid, :package}} = WebhookProcessor.process(event, "local")
  end

  test "rejects a yearly Stripe price behind the monthly lookup key" do
    event =
      subscription_event("evt_conflicting_price", "active", 400)
      |> put_in(
        ["data", "object", "items"],
        %{
          "data" => [
            %{
              "price" => %{
                "lookup_key" => "postdeploy_monthly_usd",
                "recurring" => %{"interval" => "year"}
              }
            }
          ]
        }
      )

    assert {:error, {:invalid, :billing_interval}} = WebhookProcessor.process(event, "local")
  end

  test "rejects every unknown subscription price lookup key" do
    event =
      subscription_event("evt_unknown_lookup_key", "active", 400)
      |> put_in(["data", "object", "metadata"], %{})
      |> put_in(
        ["data", "object", "items"],
        %{
          "data" => [
            %{
              "price" => %{
                "lookup_key" => "indie_founding_monthly_eur",
                "recurring" => %{"interval" => "month"}
              }
            }
          ]
        }
      )

    assert {:error, :unknown_package} = WebhookProcessor.process(event, "local")
  end

  test "rejects a subscription whose customer and organization metadata disagree" do
    owner = OrgsFixtures.scope_fixture()
    {org, _scope} = OrgsFixtures.org_fixture(owner)
    other_owner = OrgsFixtures.scope_fixture()
    {other_org, _scope} = OrgsFixtures.org_fixture(other_owner)

    assert {:ok, :processed} = WebhookProcessor.process(checkout_event(org.id), "local")

    event =
      subscription_event("evt_org_mismatch", "active", 400)
      |> put_in(["data", "object", "metadata", "org_id"], other_org.id)

    assert {:error, :organization_mismatch} = WebhookProcessor.process(event, "local")
    assert [[0]] = Repo.query!("SELECT count(*) FROM subscriptions").rows
  end

  test "rejects a live event in a non-live billing environment" do
    event = put_in(checkout_event("org_unknown"), ["livemode"], true)

    assert {:error, :wrong_livemode} = WebhookProcessor.process(event, "local")
    assert [[0]] = Repo.query!("SELECT count(*) FROM stripe_webhook_events").rows
  end

  test "non-canonical Stripe environments cannot overwrite canonical organization state" do
    owner = OrgsFixtures.scope_fixture()
    {org, _scope} = OrgsFixtures.org_fixture(owner)

    assert {:ok, :processed} = WebhookProcessor.process(checkout_event(org.id), :local)

    assert {:ok, :processed} =
             WebhookProcessor.process(subscription_event("evt_local", "active", 200), :local)

    assert {:ok, :processed} =
             WebhookProcessor.process(
               checkout_event(org.id, "postdeploy", "evt_preview_checkout"),
               :preview
             )

    assert {:ok, :processed} =
             WebhookProcessor.process(
               subscription_event("evt_preview_canceled", "canceled", 300),
               :preview
             )

    assert [["trialing"]] =
             Repo.query!("SELECT plan_status FROM organizations WHERE id = $1", [org.id]).rows

    assert {:ok, :subscribed} = Alplus.Billing.Access.check(org.id)
  end

  test "invoice reconciliation rejects a wrong Stripe livemode" do
    invoice = Map.put(invoice_event()["data"]["object"], "livemode", true)

    assert {:error, :wrong_livemode} = WebhookProcessor.reconcile_invoice(invoice, :local)
    assert [[0]] = Repo.query!("SELECT count(*) FROM invoices").rows
  end

  test "reconciliation reads item periods from atom-keyed adapter structs" do
    owner = OrgsFixtures.scope_fixture()
    {org, _scope} = OrgsFixtures.org_fixture(owner)

    subscription = %{
      id: "sub_atom_period",
      customer: "cus_atom_period",
      status: "active",
      items: %StripeSubscriptionItems{
        data: [
          %StripeSubscriptionItem{
            current_period_start: 100,
            current_period_end: 10_000,
            price: %{lookup_key: "postdeploy_monthly_usd", recurring: %{interval: "month"}}
          }
        ]
      },
      created: 300,
      cancel_at_period_end: false,
      metadata: %{org_id: org.id}
    }

    assert :ok = WebhookProcessor.reconcile_subscription(subscription, "local")

    assert [["active"]] =
             Repo.query!(
               "SELECT status FROM subscriptions WHERE stripe_subscription_id = 'sub_atom_period'"
             ).rows
  end

  test "reconciliation adapter mirrors a subscription and invoice without inventing webhook rows" do
    owner = OrgsFixtures.scope_fixture()
    {org, _scope} = OrgsFixtures.org_fixture(owner)

    Process.put(:billing_subscriptions, [
      %{
        "id" => "sub_reconciled",
        "customer" => "cus_reconciled",
        "status" => "active",
        "current_period_start" => 100,
        "current_period_end" => 10_000,
        "created" => 300,
        "items" => %{
          "data" => [
            %{
              "price" => %{
                "lookup_key" => "postdeploy_monthly_usd",
                "recurring" => %{"interval" => "month"}
              }
            }
          ]
        },
        "metadata" => %{
          "org_id" => org.id,
          "plan_id" => "postdeploy",
          "billing_interval" => "monthly"
        }
      }
    ])

    Process.put(:billing_invoices, [
      %{
        "id" => "in_reconciled",
        "customer" => "cus_reconciled",
        "amount_due" => 2_900,
        "amount_paid" => 2_900,
        "currency" => "usd",
        "status" => "paid",
        "period_start" => 100,
        "period_end" => 10_000
      }
    ])

    assert :ok = Alplus.Billing.Reconciliation.reconcile(ReconciliationAdapter, "local")

    assert {:ok, :subscribed} = Alplus.Billing.Access.check(org.id)

    assert [["active"]] =
             Repo.query!(
               "SELECT status FROM subscriptions WHERE stripe_subscription_id = 'sub_reconciled'"
             ).rows

    assert [[0]] = Repo.query!("SELECT count(*) FROM stripe_webhook_events").rows
  end

  defp checkout_event(org_id, plan_id \\ "postdeploy", event_id \\ "evt_checkout") do
    %{
      "id" => event_id,
      "type" => "checkout.session.completed",
      "livemode" => false,
      "data" => %{
        "object" => %{
          "customer" => "cus_checkout",
          "metadata" => %{"org_id" => org_id, "plan_id" => plan_id}
        }
      }
    }
  end

  defp subscription_event(id, status, created) do
    %{
      "id" => id,
      "type" => "customer.subscription.updated",
      "livemode" => false,
      "created" => created,
      "data" => %{
        "object" => %{
          "id" => "sub_123",
          "customer" => "cus_checkout",
          "status" => status,
          "current_period_start" => 100,
          "current_period_end" => 10_000,
          "items" => %{
            "data" => [
              %{
                "price" => %{
                  "lookup_key" => "postdeploy_monthly_usd",
                  "recurring" => %{"interval" => "month"}
                }
              }
            ]
          },
          # A Subscription object's created time never changes. Ordering must
          # use the top-level event's created time instead.
          "created" => 100,
          "cancel_at_period_end" => status == "canceled",
          "metadata" => %{"plan_id" => "postdeploy", "billing_interval" => "monthly"}
        }
      }
    }
  end

  defp invoice_event do
    %{
      "id" => "evt_invoice",
      "type" => "invoice.paid",
      "livemode" => false,
      "created" => 200,
      "data" => %{
        "object" => %{
          "id" => "in_123",
          "customer" => "cus_checkout",
          "amount_due" => 500,
          "amount_paid" => 500,
          "currency" => "usd",
          "status" => "paid",
          "period_start" => 100,
          "period_end" => 10_000,
          "created" => 200
        }
      }
    }
  end
end
