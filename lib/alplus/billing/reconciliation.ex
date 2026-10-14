defmodule Alplus.Billing.Reconciliation do
  @moduledoc """
  Applies a Stripe reconciliation adapter's authoritative snapshots.

  ## Why one subscription per customer is selected here

  On 2026-09-10 a second Checkout created a second active Stripe
  subscription on a customer that already had one. The mirror holds exactly
  one subscription per `(org_id, stripe_environment)`, so the nightly job
  replayed both Stripe subscriptions into the same row. Stripe list
  endpoints return the newest subscription first, so the older subscription
  was written last and overwrote the newer row. The result depended only on
  list order.

  The upsert cannot fix this. It sees one subscription at a time and never
  sees the competitor. Reconciliation therefore groups the snapshot by Stripe
  customer and selects one winner per customer before it mirrors anything.
  The selection is total and deterministic: a live status wins over a
  terminal one, then the greatest `created` timestamp, then the greatest
  subscription id.

  A customer with no live subscription still mirrors its most recent terminal
  subscription, so a fully canceled organization correctly loses access.

  A subscription whose customer or package price cannot be read is mirrored unchanged.
  `WebhookProcessor` stays the single place that reports a field error.

  Invoices keep the replay-everything behaviour. An invoice row has its own
  unique key, so two invoices never contend for one row.
  """

  alias Alplus.Billing.Package
  alias Alplus.Billing.WebhookProcessor

  @live_statuses ~w(active trialing past_due unpaid paused)

  @spec reconcile(module(), String.t()) :: :ok | {:error, term()}
  def reconcile(adapter, environment) do
    with {:ok, subscriptions} <- adapter.list_subscriptions(environment),
         :ok <-
           subscriptions
           |> one_per_customer()
           |> mirror_all(&WebhookProcessor.reconcile_subscription(&1, environment)),
         {:ok, invoices} <- adapter.list_invoices(environment) do
      mirror_all(invoices, &WebhookProcessor.reconcile_invoice(&1, environment))
    end
  end

  # Three outcomes, not two. A subscription that positively sells another
  # price is skipped: PostDeploy does not mirror it, and forwarding it would
  # make `WebhookProcessor` refuse it, which halts the whole run. The live
  # account keeps a canceled `indie_founding_monthly_usd` subscription
  # (`docs/STRIPE-PRICING-RUNBOOK.md`), so every nightly run would otherwise
  # stop on it and no later subscription or invoice would reconcile.
  defp one_per_customer(subscriptions) when is_list(subscriptions) do
    {mirrorable, other} =
      Enum.split_with(subscriptions, fn subscription ->
        customer_id(subscription) != nil and sells_package?(subscription)
      end)

    unreadable = Enum.reject(other, &sells_another_price?/1)

    mirrorable
    |> Enum.group_by(&customer_id/1)
    |> Enum.map(fn {_customer_id, candidates} -> winner(candidates) end)
    |> Enum.concat(unreadable)
    |> Enum.sort_by(&{customer_id(&1) || "", subscription_id(&1) || ""})
  end

  defp one_per_customer(other), do: other

  defp winner(candidates) do
    case Enum.filter(candidates, &live?/1) do
      [] -> Enum.max_by(candidates, &terminal_key/1)
      live -> Enum.max_by(live, &live_key/1)
    end
  end

  defp live_key(subscription), do: {created(subscription), subscription_id(subscription) || ""}
  defp terminal_key(subscription), do: live_key(subscription)

  defp live?(subscription), do: status(subscription) in @live_statuses

  # A subscription sells the package when its price carries the package's
  # lookup key. The legacy `plan_id` metadata is the fallback for a
  # subscription whose price was not expanded in the list response;
  # `WebhookProcessor` requires the two to agree.
  defp sells_package?(subscription) do
    lookup_key(subscription) == Package.stripe_lookup_key()
  end

  # A readable price that is not the package's. Distinct from a subscription
  # whose price could not be read at all, which is still reported.
  defp sells_another_price?(subscription) do
    case lookup_key(subscription) do
      nil -> false
      key -> key != Package.stripe_lookup_key()
    end
  end

  defp lookup_key(subscription) do
    optional_string(get_in_value(subscription, ["items", "data", 0, "price", "lookup_key"]))
  end

  defp subscription_id(subscription), do: optional_string(value(subscription, "id"))
  defp customer_id(subscription), do: optional_string(value(subscription, "customer"))
  defp status(subscription), do: optional_string(value(subscription, "status"))

  defp created(subscription) do
    case value(subscription, "created") do
      created when is_integer(created) -> created
      %DateTime{} = created -> DateTime.to_unix(created)
      _other -> 0
    end
  end

  defp optional_string(value) when is_binary(value) and value != "", do: value

  defp optional_string(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp optional_string(_value), do: nil

  # Reconciliation snapshots arrive as StripityStripe structs with atom keys,
  # while a replayed JSON payload has string keys. Read both, the way
  # `WebhookProcessor.value/2` does.
  #
  # `key` is always one of a handful of literal strings written in this
  # module ("id", "customer", "status", ...), never a key name taken from the
  # Stripe payload.
  # sobelow_skip ["DOS.StringToAtom"]
  defp value(map, key) when is_map(map) do
    if Map.has_key?(map, key) do
      Map.get(map, key)
    else
      Map.get(map, String.to_atom(key))
    end
  end

  defp value(_map, _key), do: nil

  defp get_in_value(map, keys) do
    Enum.reduce_while(keys, map, fn
      index, acc when is_integer(index) and is_list(acc) ->
        case Enum.at(acc, index) do
          nil -> {:halt, nil}
          result -> {:cont, result}
        end

      key, acc ->
        case value(acc, key) do
          nil -> {:halt, nil}
          result -> {:cont, result}
        end
    end)
  end

  defp mirror_all(rows, mirror) when is_list(rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case mirror.(row) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp mirror_all(_, _), do: {:error, :invalid_reconciliation_response}
end
