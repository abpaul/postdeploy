defmodule Alplus.Billing.StripeReconciliationAdapter.StripeTest do
  use ExUnit.Case, async: false

  alias Alplus.Billing.StripeReconciliationAdapter.Stripe

  defmodule StripeClientFake do
    def list_subscriptions(params), do: next(:subscriptions, params)
    def list_invoices(params), do: next(:invoices, params)

    defp next(kind, params) do
      send(self(), {kind, params})

      case Process.get({__MODULE__, kind}, []) do
        [response | responses] ->
          Process.put({__MODULE__, kind}, responses)
          response

        [] ->
          {:error, :unexpected_page}
      end
    end
  end

  setup do
    previous = Application.get_env(:alplus, :stripe_reconciliation_client)
    Application.put_env(:alplus, :stripe_reconciliation_client, StripeClientFake)

    on_exit(fn ->
      if previous do
        Application.put_env(:alplus, :stripe_reconciliation_client, previous)
      else
        Application.delete_env(:alplus, :stripe_reconciliation_client)
      end
    end)

    :ok
  end

  test "reads every subscription page with a stable cursor" do
    Process.put({StripeClientFake, :subscriptions}, [
      {:ok, %{data: [%{id: "sub_1"}, %{id: "sub_2"}], has_more: true}},
      {:ok, %{data: [%{id: "sub_3"}], has_more: false}}
    ])

    assert {:ok, [%{id: "sub_1"}, %{id: "sub_2"}, %{id: "sub_3"}]} =
             Stripe.list_subscriptions("production")

    assert_received {:subscriptions, %{limit: 100, status: :all}}
    assert_received {:subscriptions, %{limit: 100, status: :all, starting_after: "sub_2"}}
  end

  test "reads invoices without a status filter" do
    Process.put({StripeClientFake, :invoices}, [
      {:ok, %{data: [%{id: "in_1"}], has_more: false}}
    ])

    assert {:ok, [%{id: "in_1"}]} = Stripe.list_invoices("production")
    assert_received {:invoices, %{limit: 100}}
  end

  test "returns a malformed pagination response as an error" do
    Process.put({StripeClientFake, :subscriptions}, [
      {:ok, %{data: [], has_more: true}}
    ])

    assert {:error, :invalid_stripe_list_response} = Stripe.list_subscriptions("production")
  end

  test "returns a Stripe page failure for the Oban worker to retry" do
    Process.put({StripeClientFake, :invoices}, [{:error, :stripe_unavailable}])

    assert {:error, :stripe_unavailable} = Stripe.list_invoices("production")
  end
end
