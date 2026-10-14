defmodule AlplusWeb.StripeWebhookControllerTest do
  use AlplusWeb.ConnCase, async: false
  use Oban.Testing, repo: Alplus.Repo

  import Alplus.OrgsFixtures

  alias Alplus.Billing.{Checkout, WebhookProcessor, WebhookWorker}
  alias Alplus.Repo

  @webhook_secret "whsec_alplus_test_webhook_secret"

  test "verifies the signature and enqueues only allowlisted Stripe fields", %{conn: conn} do
    event =
      event("checkout.session.completed", false)
      |> put_in(["data", "object"], %{
        "customer" => "cus_allowed",
        "customer_email" => "private@example.test",
        "billing_details" => %{"address" => %{"line1" => "private"}},
        "metadata" => %{
          "org_id" => "org_allowed",
          "plan_id" => "postdeploy",
          "billing_interval" => "monthly",
          "email" => "private@example.test"
        }
      })

    response = post_event(conn, event)

    assert response.status == 200
    [job] = all_enqueued(worker: WebhookWorker)

    assert job.args == %{
             "event" => %{
               "id" => event["id"],
               "type" => "checkout.session.completed",
               "livemode" => false,
               "api_version" => "2025-01-27.acacia",
               "data" => %{
                 "object" => %{
                   "customer" => "cus_allowed",
                   "metadata" => %{
                     "org_id" => "org_allowed",
                     "plan_id" => "postdeploy",
                     "billing_interval" => "monthly"
                   }
                 }
               }
             },
             "stripe_environment" => "local"
           }
  end

  test "keeps subscription periods and price identity without nested personal fields" do
    event =
      subscription_event()
      |> put_in(["data", "object", "items"], %{
        "data" => [
          %{
            "current_period_start" => 1_000,
            "current_period_end" => 2_000,
            "price" => %{
              "lookup_key" => "postdeploy_monthly_usd",
              "recurring" => %{"interval" => "month"},
              "billing_details" => %{"name" => "private"}
            },
            "description" => "private"
          }
        ]
      })

    assert {:ok, normalized} = WebhookProcessor.normalize_event(event)

    assert normalized["data"]["object"]["items"] == %{
             "data" => [
               %{
                 "current_period_start" => 1_000,
                 "current_period_end" => 2_000,
                 "price" => %{
                   "lookup_key" => "postdeploy_monthly_usd",
                   "recurring" => %{"interval" => "month"}
                 }
               }
             ]
           }
  end

  test "keeps invoice mirror fields without customer details" do
    event = %{
      "id" => "evt_invoice_allowlist",
      "type" => "invoice.paid",
      "livemode" => false,
      "created" => 1_000,
      "data" => %{
        "object" => %{
          "id" => "in_allowlist",
          "customer" => "cus_allowlist",
          "amount_due" => 1_500,
          "amount_paid" => 1_500,
          "currency" => "usd",
          "status" => "paid",
          "invoice_pdf" => "https://invoice.stripe.test/in_allowlist",
          "period_start" => 1_000,
          "period_end" => 2_000,
          "metadata" => %{"org_id" => "org_allowlist", "email" => "private@example.test"},
          "customer_email" => "private@example.test",
          "shipping_details" => %{"address" => %{"line1" => "private"}}
        }
      }
    }

    assert {:ok, normalized} = WebhookProcessor.normalize_event(event)

    assert normalized["data"]["object"] == %{
             "id" => "in_allowlist",
             "customer" => "cus_allowlist",
             "amount_due" => 1_500,
             "amount_paid" => 1_500,
             "currency" => "usd",
             "status" => "paid",
             "invoice_pdf" => "https://invoice.stripe.test/in_allowlist",
             "period_start" => 1_000,
             "period_end" => 2_000,
             "metadata" => %{"org_id" => "org_allowlist"}
           }
  end

  test "acknowledges unsupported event types without a billing job", %{conn: conn} do
    response = post_event(conn, event("charge.succeeded", false))

    assert response.status == 200
    refute_enqueued(worker: WebhookWorker)
  end

  test "rejects a missing or invalid Stripe signature", %{conn: conn} do
    body = Jason.encode!(event("invoice.paid", false))

    missing =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/webhooks/stripe", body)

    assert missing.status == 400

    invalid =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", "t=#{System.system_time(:second)},v1=invalid")
      |> post("/webhooks/stripe", body)

    assert invalid.status == 400
    refute_enqueued(worker: WebhookWorker)
  end

  test "rejects a correctly signed event from the wrong Stripe mode", %{conn: conn} do
    response = post_event(conn, event("invoice.paid", true))

    assert response.status == 400
    refute_enqueued(worker: WebhookWorker)
  end

  test "a test-mode Checkout grants the subscription only after its signed webhook", %{conn: conn} do
    user = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(user.id))

    assert {:ok, "https://checkout.stripe.test/session"} =
             Checkout.create_checkout(owner_scope, org.id,
               adapter: Alplus.Billing.StripeAdapter.Fake,
               stripe_environment: "local",
               price_id: "price_test_postdeploy_monthly",
               base_url: "https://alplus.test"
             )

    assert_receive {:stripe_checkout, %{mode: :subscription, automatic_tax: %{enabled: true}}}

    assert {:ok, :trial} = Alplus.Billing.Access.check(org.id)

    checkout = checkout_event(org.id)
    assert post_event(conn, checkout).status == 200

    assert {:ok, normalized_checkout} = WebhookProcessor.normalize_event(checkout)

    assert :ok =
             perform_job(WebhookWorker, %{
               "event" => normalized_checkout,
               "stripe_environment" => "local"
             })

    subscription = subscription_event()
    assert post_event(build_conn(), subscription).status == 200

    assert {:ok, normalized_subscription} = WebhookProcessor.normalize_event(subscription)

    assert :ok =
             perform_job(WebhookWorker, %{
               "event" => normalized_subscription,
               "stripe_environment" => "local"
             })

    assert {:ok, :subscribed} = Alplus.Billing.Access.check(org.id)
  end

  defp post_event(conn, event) do
    body = Jason.encode!(event)
    timestamp = System.system_time(:second)
    signature = signature(timestamp, body)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", "t=#{timestamp},v1=#{signature}")
    |> post("/webhooks/stripe", body)
  end

  defp signature(timestamp, payload) do
    :crypto.mac(:hmac, :sha256, @webhook_secret, "#{timestamp}.#{payload}")
    |> Base.encode16(case: :lower)
  end

  defp event(type, livemode) do
    %{
      "id" => "evt_boundary_#{System.unique_integer([:positive])}",
      "object" => "event",
      "type" => type,
      "livemode" => livemode,
      "api_version" => "2025-01-27.acacia",
      "data" => %{"object" => %{}}
    }
  end

  defp checkout_event(org_id) do
    %{
      "id" => "evt_checkout_#{System.unique_integer([:positive])}",
      "object" => "event",
      "type" => "checkout.session.completed",
      "livemode" => false,
      "data" => %{
        "object" => %{
          "customer" => "cus_acceptance",
          "metadata" => %{"org_id" => org_id, "plan_id" => "postdeploy"}
        }
      }
    }
  end

  defp subscription_event do
    %{
      "id" => "evt_subscription_#{System.unique_integer([:positive])}",
      "object" => "event",
      "type" => "customer.subscription.updated",
      "livemode" => false,
      "created" => 1_000,
      "data" => %{
        "object" => %{
          "id" => "sub_acceptance",
          "customer" => "cus_acceptance",
          "status" => "active",
          "current_period_start" => 1_000,
          "current_period_end" => 2_000,
          "created" => 1_000,
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
        }
      }
    }
  end
end
