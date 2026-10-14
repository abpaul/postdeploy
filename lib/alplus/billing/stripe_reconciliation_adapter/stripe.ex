defmodule Alplus.Billing.StripeReconciliationAdapter.Stripe do
  @moduledoc """
  StripityStripe adapter for the daily full billing reconciliation.

  Stripe credentials select the provider account. The supplied environment
  labels the local mirror rows and is intentionally not sent to Stripe.
  """

  @behaviour Alplus.Billing.StripeReconciliationAdapter

  @page_size 100

  @impl true
  def list_subscriptions(_environment) do
    client = client()
    collect_pages(&client.list_subscriptions/1, %{limit: @page_size, status: :all})
  end

  @impl true
  def list_invoices(_environment) do
    client = client()
    collect_pages(&client.list_invoices/1, %{limit: @page_size})
  end

  defp collect_pages(list_page, params), do: collect_pages(list_page, params, [])

  defp collect_pages(list_page, params, pages) do
    case list_page.(params) do
      {:ok, %{data: rows, has_more: false}} when is_list(rows) ->
        {:ok, pages |> Enum.reverse() |> List.flatten() |> Kernel.++(rows)}

      {:ok, %{data: rows, has_more: true}} when is_list(rows) ->
        with {:ok, cursor} <- page_cursor(rows) do
          collect_pages(list_page, Map.put(params, :starting_after, cursor), [rows | pages])
        end

      {:ok, _response} ->
        {:error, :invalid_stripe_list_response}

      {:error, _reason} = error ->
        error
    end
  end

  defp page_cursor(rows) do
    case List.last(rows) do
      %{id: id} when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :invalid_stripe_list_response}
    end
  end

  defp client do
    Application.get_env(
      :alplus,
      :stripe_reconciliation_client,
      Alplus.Billing.StripeReconciliationAdapter.Stripe.Client
    )
  end
end
