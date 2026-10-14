defmodule Alplus.Billing.WebhookProcessor do
  @moduledoc """
  Applies an already verified Stripe event to PostDeploy's local Billing mirror.

  This is a direct Postgres escape hatch. A webhook delivery can race with a
  retry or arrive out of order, so recording, claiming, mirroring, and marking
  the event complete must share one database transaction. The HTTP boundary is
  deliberately outside this module: it verifies Stripe signatures and chooses
  the `stripe_environment` before calling `process/2`.
  """

  alias Alplus.Billing.{Package, StripeConfig}
  alias Alplus.{Id, Repo}

  @supported_types MapSet.new([
                     "checkout.session.completed",
                     "customer.subscription.created",
                     "customer.subscription.updated",
                     "customer.subscription.deleted",
                     "invoice.paid",
                     "invoice.payment_failed",
                     "invoice.finalized"
                   ])

  @claim_ttl_seconds 300

  @checkout_fields ~w(customer metadata client_reference_id)
  @subscription_fields ~w(
    id customer status current_period_start current_period_end created
    cancel_at_period_end metadata items
  )
  @invoice_fields ~w(
    id customer amount_due amount_paid currency status invoice_pdf
    period_start period_end created metadata
  )
  @metadata_fields ~w(org_id alplus_org_id plan_id alplus_plan_id billing_interval)
  @item_fields ~w(current_period_start current_period_end price)
  @price_fields ~w(lookup_key interval recurring)

  @type environment :: :local | :preview | :staging | :production

  @spec supported_type?(String.t()) :: boolean()
  def supported_type?(type) when is_binary(type), do: MapSet.member?(@supported_types, type)

  @doc """
  Keeps only the Stripe fields required by the billing processor.

  The returned map is safe to persist in an Oban job. It excludes customer
  contact data, payment details, and all nested fields outside this allowlist.
  """
  @spec normalize_event(map()) :: {:ok, map()} | {:error, :invalid_payload}
  def normalize_event(event) when is_map(event) do
    type = allowed_string(value(event, "type"))
    object = get_in_value(event, ["data", "object"])

    {:ok,
     %{
       "id" => allowed_string(value(event, "id")),
       "type" => type,
       "livemode" => allowed_boolean(value(event, "livemode")),
       "api_version" => allowed_string(value(event, "api_version")),
       "created" => allowed_integer(value(event, "created")),
       "data" => %{"object" => allowed_object(type, object)}
     }
     |> compact_map()}
  end

  def normalize_event(_event), do: {:error, :invalid_payload}

  defp allowed_object("checkout.session.completed", object) when is_map(object) do
    object
    |> allowed_map_fields(@checkout_fields)
    |> maybe_put("metadata", allowed_metadata(value(object, "metadata")))
  end

  defp allowed_object(type, object)
       when type in [
              "customer.subscription.created",
              "customer.subscription.updated",
              "customer.subscription.deleted"
            ] and is_map(object) do
    object
    |> allowed_map_fields(@subscription_fields)
    |> maybe_put("metadata", allowed_metadata(value(object, "metadata")))
    |> maybe_put("items", allowed_items(value(object, "items")))
  end

  defp allowed_object(type, object)
       when type in ["invoice.paid", "invoice.payment_failed", "invoice.finalized"] and
              is_map(object) do
    object
    |> allowed_map_fields(@invoice_fields)
    |> maybe_put("metadata", allowed_metadata(value(object, "metadata")))
  end

  defp allowed_object(_type, _object), do: %{}

  defp allowed_map_fields(object, fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      maybe_put(acc, field, allowed_field_value(field, value(object, field)))
    end)
  end

  defp allowed_field_value("metadata", value), do: allowed_metadata(value)
  defp allowed_field_value("items", value), do: allowed_items(value)
  defp allowed_field_value("price", value), do: allowed_price(value)
  defp allowed_field_value("recurring", value), do: allowed_recurring(value)
  defp allowed_field_value("cancel_at_period_end", value), do: allowed_boolean(value)

  defp allowed_field_value(field, value)
       when field in [
              "amount_due",
              "amount_paid",
              "current_period_start",
              "current_period_end",
              "period_start",
              "period_end",
              "created"
            ],
       do: allowed_integer(value)

  defp allowed_field_value(_field, value), do: allowed_string(value)

  defp allowed_items(items) when is_map(items) do
    case value(items, "data") do
      [%{} = item | _] ->
        item = allowed_map_fields(item, @item_fields)

        case item do
          %{} = item when map_size(item) > 0 -> %{"data" => [item]}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp allowed_items(_items), do: nil

  defp allowed_price(price) when is_map(price) do
    price
    |> allowed_map_fields(@price_fields)
    |> maybe_put("recurring", allowed_recurring(value(price, "recurring")))
  end

  defp allowed_price(_price), do: nil

  defp allowed_recurring(recurring) when is_map(recurring) do
    case allowed_string(value(recurring, "interval")) do
      nil -> nil
      interval -> %{"interval" => interval}
    end
  end

  defp allowed_recurring(_recurring), do: nil

  defp allowed_metadata(metadata) when is_map(metadata) do
    metadata =
      Enum.reduce(@metadata_fields, %{}, fn field, acc ->
        maybe_put(acc, field, allowed_string(value(metadata, field)))
      end)

    if map_size(metadata) == 0, do: nil, else: metadata
  end

  defp allowed_metadata(_metadata), do: nil

  defp allowed_string(value) when is_binary(value) and byte_size(value) <= 255, do: value
  defp allowed_string(_value), do: nil

  defp allowed_boolean(value) when is_boolean(value), do: value
  defp allowed_boolean(_value), do: nil

  defp allowed_integer(value) when is_integer(value), do: value
  defp allowed_integer(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp compact_map(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  @doc """
  Idempotently records and applies one Stripe event.

  Returns `:processed` when this call applied the event, `:already_processed`
  for a delivery Stripe has already completed, and `:ignored` for event types
  that the Billing contract does not mirror.
  """
  @spec process(map(), environment() | String.t()) ::
          {:ok, :processed | :already_processed | :ignored} | {:error, term()}
  def process(event, environment) when is_map(event) do
    if supported_type?(value(event, "type")) do
      with {:ok, environment} <- environment(environment),
           {:ok, job_event} <- normalize_event(event),
           {:ok, normalized} <- parse_event(job_event),
           :ok <- validate_livemode(normalized, environment) do
        claim_and_apply(normalized, environment)
      else
        {:error, _reason} = error -> error
      end
    else
      {:ok, :ignored}
    end
  end

  defp claim_and_apply(normalized, environment) do
    case Repo.transaction(fn -> claim_and_apply_in_transaction(normalized, environment) end) do
      {:error, {:mirror_failed, reason}} ->
        record_failure(normalized, environment, reason)
        {:error, reason}

      result ->
        transaction_result(result)
    end
  end

  defp claim_and_apply_in_transaction(normalized, environment) do
    case claim_event(normalized, environment) do
      {:claimed, claim} ->
        case apply_event(normalized, environment) do
          :ok ->
            complete_claim(claim)
            :processed

          {:error, reason} ->
            Repo.rollback({:mirror_failed, reason})
        end

      :processed ->
        :already_processed

      :busy ->
        Repo.rollback(:event_is_being_processed)
    end
  end

  @doc """
  Mirrors a subscription returned by daily reconciliation.

  The adapter must provide a Stripe subscription object with `id`, `customer`,
  `status`, period bounds, and the package's price lookup key. Reconciliation does not
  create fake webhook events; the event ledger remains a ledger of deliveries.
  """
  @spec reconcile_subscription(map(), environment() | String.t()) :: :ok | {:error, term()}
  def reconcile_subscription(subscription, environment) when is_map(subscription) do
    with {:ok, environment} <- environment(environment),
         :ok <- validate_optional_livemode(subscription, environment),
         {:ok, subscription} <- subscription_fields(subscription),
         {:ok, org_id} <- org_id_for_subscription(subscription, environment, false) do
      Repo.transaction(fn ->
        upsert_customer(org_id, environment, subscription.customer_id)

        if upsert_subscription(org_id, environment, subscription, true) do
          maybe_apply_billing_status(org_id, environment, subscription.status)
        end

        :ok
      end)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Mirrors an invoice returned by daily reconciliation."
  @spec reconcile_invoice(map(), environment() | String.t()) :: :ok | {:error, term()}
  def reconcile_invoice(invoice, environment) when is_map(invoice) do
    with {:ok, environment} <- environment(environment),
         :ok <- validate_optional_livemode(invoice, environment),
         {:ok, invoice} <- invoice_fields(invoice),
         {:ok, org_id} <- org_id_for(invoice, environment) do
      Repo.transaction(fn -> upsert_invoice(org_id, environment, invoice) end)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp claim_event(event, environment) do
    now = DateTime.utc_now()
    claim_token = Id.generate(:stripe_webhook_event)
    expires_at = DateTime.add(now, @claim_ttl_seconds, :second)

    result =
      Repo.query!(
        """
        INSERT INTO stripe_webhook_events
          (id, stripe_environment, stripe_event_id, type, api_version, livemode,
           payload_hash, status, attempt_count, claim_token, claim_fence,
           claim_expires_at, received_at, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, 'processing', 1, $8, 1, $9, $10, now(), now())
        ON CONFLICT (stripe_environment, stripe_event_id) DO UPDATE SET
          status = 'processing',
          attempt_count = stripe_webhook_events.attempt_count + 1,
          claim_token = EXCLUDED.claim_token,
          claim_fence = stripe_webhook_events.claim_fence + 1,
          claim_expires_at = EXCLUDED.claim_expires_at,
          last_error = NULL,
          updated_at = now()
        WHERE stripe_webhook_events.status IN ('pending', 'failed')
           OR (stripe_webhook_events.status = 'processing' AND stripe_webhook_events.claim_expires_at <= $10)
        RETURNING id, claim_fence
        """,
        [
          Id.generate(:stripe_webhook_event),
          environment,
          event.id,
          event.type,
          event.api_version,
          event.livemode,
          payload_hash(event.raw),
          claim_token,
          expires_at,
          now
        ]
      )

    case result.rows do
      [[id, claim_fence]] -> {:claimed, %{id: id, token: claim_token, fence: claim_fence}}
      [] -> claimed_event_status(event.id, environment)
    end
  end

  defp claimed_event_status(event_id, environment) do
    case Repo.query!(
           "SELECT status FROM stripe_webhook_events WHERE stripe_environment = $1 AND stripe_event_id = $2",
           [environment, event_id]
         ).rows do
      [["processed"]] -> :processed
      _ -> :busy
    end
  end

  defp complete_claim(%{id: id, token: token, fence: fence}) do
    %{num_rows: 1} =
      Repo.query!(
        """
        UPDATE stripe_webhook_events
        SET status = 'processed', processed_at = now(), claim_token = NULL,
            claim_expires_at = NULL, last_error = NULL, updated_at = now()
        WHERE id = $1 AND claim_token = $2 AND claim_fence = $3 AND status = 'processing'
        """,
        [id, token, fence]
      )
  end

  defp record_failure(event, environment, reason) do
    Repo.query!(
      """
      INSERT INTO stripe_webhook_events
        (id, stripe_environment, stripe_event_id, type, api_version, livemode,
         payload_hash, status, attempt_count, last_error, received_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, 'failed', 1, $8, now(), now(), now())
      ON CONFLICT (stripe_environment, stripe_event_id) DO UPDATE SET
        status = CASE WHEN stripe_webhook_events.status = 'processed' THEN 'processed' ELSE 'failed' END,
        last_error = CASE WHEN stripe_webhook_events.status = 'processed' THEN NULL ELSE EXCLUDED.last_error END,
        claim_token = NULL,
        claim_expires_at = NULL,
        updated_at = now()
      """,
      [
        Id.generate(:stripe_webhook_event),
        environment,
        event.id,
        event.type,
        event.api_version,
        event.livemode,
        payload_hash(event.raw),
        inspect(reason) |> String.slice(0, 4096)
      ]
    )
  end

  defp apply_event(%{type: "checkout.session.completed", object: object}, environment) do
    with {:ok, checkout} <- checkout_fields(object),
         :ok <- ensure_organization(checkout.org_id) do
      upsert_customer(checkout.org_id, environment, checkout.customer_id)
      :ok
    end
  end

  defp apply_event(%{type: type, object: object, event_created_at: event_created_at}, environment)
       when type in [
              "customer.subscription.created",
              "customer.subscription.updated",
              "customer.subscription.deleted"
            ] do
    with {:ok, event_created_at} <- required_event_datetime(event_created_at),
         {:ok, subscription} <- subscription_fields(object, event_created_at),
         {:ok, org_id} <- org_id_for_subscription(subscription, environment, true) do
      upsert_customer(org_id, environment, subscription.customer_id)

      if upsert_subscription(org_id, environment, subscription) do
        maybe_apply_billing_status(org_id, environment, subscription.status)
      end

      :ok
    end
  end

  defp apply_event(%{type: type, object: object, event_created_at: event_created_at}, environment)
       when type in ["invoice.paid", "invoice.payment_failed", "invoice.finalized"] do
    with {:ok, event_created_at} <- required_event_datetime(event_created_at),
         {:ok, invoice} <- invoice_fields(object, event_created_at),
         {:ok, org_id} <- org_id_for(invoice, environment) do
      upsert_invoice(org_id, environment, invoice)
    end
  end

  defp upsert_customer(org_id, environment, customer_id) do
    Repo.query!(
      """
      INSERT INTO stripe_customers (id, org_id, stripe_environment, stripe_customer_id, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, now(), now())
      ON CONFLICT (org_id, stripe_environment) DO UPDATE
      SET stripe_customer_id = EXCLUDED.stripe_customer_id, updated_at = now()
      WHERE stripe_customers.stripe_customer_id = EXCLUDED.stripe_customer_id
      """,
      [Id.generate(:stripe_customer), org_id, environment, customer_id]
    )

    :ok
  end

  defp upsert_subscription(org_id, environment, subscription, authoritative? \\ false) do
    %{num_rows: num_rows} =
      Repo.query!(
        """
        INSERT INTO subscriptions
          (id, org_id, stripe_environment, stripe_subscription_id, status,
           current_period_start, current_period_end, cancel_at_period_end,
           event_created_at, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, now(), now())
        ON CONFLICT (org_id, stripe_environment) DO UPDATE SET
          stripe_subscription_id = EXCLUDED.stripe_subscription_id,
          status = EXCLUDED.status,
          current_period_start = EXCLUDED.current_period_start,
          current_period_end = EXCLUDED.current_period_end,
          cancel_at_period_end = EXCLUDED.cancel_at_period_end,
          event_created_at = CASE
            WHEN $10 THEN subscriptions.event_created_at
            ELSE EXCLUDED.event_created_at
          END,
          updated_at = now()
        WHERE $10
           OR subscriptions.event_created_at IS NULL
           OR EXCLUDED.event_created_at IS NULL
           OR EXCLUDED.event_created_at > subscriptions.event_created_at
           OR (
             EXCLUDED.event_created_at = subscriptions.event_created_at
             AND (subscriptions.status <> 'canceled' OR EXCLUDED.status = 'canceled')
           )
        """,
        [
          Id.generate(:subscription),
          org_id,
          environment,
          subscription.id,
          subscription.status,
          subscription.period_start,
          subscription.period_end,
          subscription.cancel_at_period_end,
          subscription.event_created_at,
          authoritative?
        ]
      )

    num_rows == 1
  end

  defp upsert_invoice(org_id, environment, invoice) do
    Repo.query!(
      """
      INSERT INTO invoices
        (id, org_id, stripe_environment, stripe_invoice_id, amount_due, amount_paid,
         currency, status, invoice_pdf_url, period_start, period_end,
         event_created_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, now(), now())
      ON CONFLICT (stripe_environment, stripe_invoice_id) DO UPDATE SET
        amount_due = EXCLUDED.amount_due, amount_paid = EXCLUDED.amount_paid,
        currency = EXCLUDED.currency, status = EXCLUDED.status,
        invoice_pdf_url = EXCLUDED.invoice_pdf_url, period_start = EXCLUDED.period_start,
        period_end = EXCLUDED.period_end, event_created_at = EXCLUDED.event_created_at,
        updated_at = now()
      WHERE invoices.event_created_at IS NULL
         OR EXCLUDED.event_created_at IS NULL
         OR EXCLUDED.event_created_at >= invoices.event_created_at
      """,
      [
        Id.generate(:invoice),
        org_id,
        environment,
        invoice.id,
        invoice.amount_due,
        invoice.amount_paid,
        invoice.currency,
        invoice.status,
        invoice.pdf_url,
        invoice.period_start,
        invoice.period_end,
        invoice.event_created_at
      ]
    )

    :ok
  end

  # `billing_status` comes straight from Stripe. A canceled subscription
  # leaves `billing_status: :canceled`; the `Alplus.Billing.Access` decision
  # table turns that into read-only access.
  defp apply_billing_status(org_id, status) do
    case Alplus.Orgs.apply_billing_status(org_id, status) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback({:organization_billing_transition_failed, reason})
    end
  end

  defp maybe_apply_billing_status(org_id, environment, status) do
    case {StripeConfig.environment(), environment} do
      {{:ok, ^environment}, "production"} ->
        apply_billing_status(org_id, status)

      {{:ok, _other_environment}, _event_environment} ->
        :ok

      {{:error, reason}, _event_environment} ->
        Repo.rollback(reason)
    end
  end

  defp org_id_for(object, environment) do
    explicit_org_id = explicit_org_id(object)

    with {:ok, customer_org_id} <- org_id_for_customer(object.customer_id, environment),
         :ok <- ensure_organization(customer_org_id),
         :ok <- matching_org_id(explicit_org_id, customer_org_id) do
      {:ok, customer_org_id}
    end
  end

  defp org_id_for_customer(customer_id, environment) do
    case Repo.query!(
           "SELECT org_id FROM stripe_customers WHERE stripe_environment = $1 AND stripe_customer_id = $2",
           [environment, customer_id]
         ).rows do
      [[org_id]] -> {:ok, org_id}
      [] -> {:error, :unknown_stripe_customer}
    end
  end

  defp org_id_for_subscription(subscription, environment, require_customer?) do
    explicit_org_id = explicit_org_id(subscription)

    case org_id_for_customer(subscription.customer_id, environment) do
      {:ok, customer_org_id} ->
        with :ok <- ensure_organization(customer_org_id),
             :ok <- matching_org_id(explicit_org_id, customer_org_id) do
          {:ok, customer_org_id}
        end

      {:error, :unknown_stripe_customer}
      when not require_customer? and is_binary(explicit_org_id) ->
        case ensure_organization(explicit_org_id) do
          :ok -> {:ok, explicit_org_id}
          {:error, _reason} -> {:error, :unknown_organization}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp matching_org_id(nil, _customer_org_id), do: :ok
  defp matching_org_id(org_id, org_id), do: :ok
  defp matching_org_id(_explicit_org_id, _customer_org_id), do: {:error, :organization_mismatch}

  defp ensure_organization(org_id) do
    case Repo.query!("SELECT id FROM organizations WHERE id = $1 FOR KEY SHARE", [org_id]).rows do
      [[^org_id]] -> :ok
      [] -> {:error, :unknown_organization}
    end
  end

  defp parse_event(event) do
    with {:ok, id} <- required_string(value(event, "id"), :event_id),
         {:ok, type} <- required_string(value(event, "type"), :type),
         {:ok, livemode} <- required_boolean(value(event, "livemode"), :livemode),
         {:ok, object} <- required_map(get_in_value(event, ["data", "object"]), :object) do
      {:ok,
       %{
         id: id,
         type: type,
         livemode: livemode,
         api_version: optional_string(value(event, "api_version")),
         event_created_at: optional_stripe_datetime(value(event, "created")),
         object: object,
         raw: event
       }}
    end
  end

  defp validate_livemode(%{livemode: livemode}, environment) do
    if StripeConfig.livemode_matches?(livemode, environment),
      do: :ok,
      else: {:error, :wrong_livemode}
  end

  defp validate_optional_livemode(object, environment) do
    case value(object, "livemode") do
      nil ->
        :ok

      livemode when is_boolean(livemode) ->
        if StripeConfig.livemode_matches?(livemode, environment),
          do: :ok,
          else: {:error, :wrong_livemode}

      _other ->
        {:error, {:invalid, :livemode}}
    end
  end

  defp checkout_fields(object) do
    with {:ok, org_id} <- required_string(explicit_org_id(object), :org_id),
         {:ok, customer_id} <- required_string(value(object, "customer"), :customer_id) do
      {:ok, %{org_id: org_id, customer_id: customer_id}}
    end
  end

  defp subscription_fields(object, event_created_at \\ nil) do
    with {:ok, id} <- required_string(value(object, "id"), :subscription_id),
         {:ok, customer_id} <- required_string(value(object, "customer"), :customer_id),
         :ok <- validate_package(object),
         :ok <- validate_interval(object),
         {:ok, status} <- status(value(object, "status"), :subscription_status),
         {:ok, period_start} <- subscription_period(object, "current_period_start", :period_start),
         {:ok, period_end} <- subscription_period(object, "current_period_end", :period_end),
         true <- DateTime.compare(period_end, period_start) == :gt do
      {:ok,
       %{
         id: id,
         customer_id: customer_id,
         status: status,
         period_start: period_start,
         period_end: period_end,
         cancel_at_period_end: value(object, "cancel_at_period_end") == true,
         event_created_at: event_created_at || optional_stripe_datetime(value(object, "created")),
         metadata: value(object, "metadata")
       }}
    else
      false -> {:error, :invalid_period}
      {:error, _} = error -> error
    end
  end

  # Stripe moved the billing period off the Subscription object and onto each
  # subscription item. On `2026-06-24.dahlia` the top-level
  # `current_period_start`/`current_period_end` are absent, and every
  # `customer.subscription.*` event failed with `{:invalid, :period_start}` —
  # so no subscription could be mirrored at all, and an org stayed on `free`
  # after paying.
  #
  # Read the item first, since that is where the field lives now, and fall
  # back to the top level for an endpoint still pinned to an API version that
  # predates the move. A period that is missing from both is still an error:
  # neither branch invents a value.
  #
  # PostDeploy sells exactly one line item per subscription (`Checkout` sends a
  # single price, and the package has no add-ons), so the first item's period is the
  # subscription's period.
  defp subscription_period(object, field, name) do
    item_period =
      object
      |> value("items")
      |> value("data")
      |> case do
        [%{} = item | _] -> value(item, field)
        _ -> nil
      end

    stripe_datetime(item_period || value(object, field), name)
  end

  defp invoice_fields(object, event_created_at \\ nil) do
    with {:ok, id} <- required_string(value(object, "id"), :invoice_id),
         {:ok, customer_id} <- required_string(value(object, "customer"), :customer_id),
         {:ok, amount_due} <- non_negative_integer(value(object, "amount_due"), :amount_due),
         {:ok, amount_paid} <- non_negative_integer(value(object, "amount_paid"), :amount_paid),
         {:ok, currency} <- currency(value(object, "currency")),
         {:ok, status} <- invoice_status(value(object, "status")),
         {:ok, period_start} <- stripe_datetime(value(object, "period_start"), :period_start),
         {:ok, period_end} <- stripe_datetime(value(object, "period_end"), :period_end) do
      {:ok,
       %{
         id: id,
         customer_id: customer_id,
         amount_due: amount_due,
         amount_paid: amount_paid,
         currency: currency,
         status: status,
         pdf_url: optional_string(value(object, "invoice_pdf")),
         period_start: period_start,
         period_end: period_end,
         event_created_at: event_created_at || optional_stripe_datetime(value(object, "created")),
         metadata: value(object, "metadata")
       }}
    end
  end

  # A subscription sells the package only when its price carries the
  # package's lookup key. The key is required: metadata is customer-writable
  # in the dashboard, and accepting it alone once let a subscription on a
  # retired, cheaper price mirror as the package. The legacy `plan_id`
  # metadata, when present, must name the package too.
  defp validate_package(object) do
    metadata_package =
      explicit_value(value(object, "metadata"), "plan_id") ||
        explicit_value(value(object, "metadata"), "alplus_plan_id")

    lookup_key = get_in_value(object, ["items", "data", 0, "price", "lookup_key"])

    cond do
      is_nil(lookup_key) -> {:error, {:invalid, :package}}
      lookup_key != Package.stripe_lookup_key() -> {:error, :unknown_package}
      metadata_package not in [nil, "postdeploy"] -> {:error, :unknown_package}
      true -> :ok
    end
  end

  # The package is billed monthly. The event must state an interval, and
  # every interval it states must be monthly.
  defp validate_interval(object) do
    intervals = [
      explicit_value(value(object, "metadata"), "billing_interval"),
      get_in_value(object, ["items", "data", 0, "price", "recurring", "interval"]),
      get_in_value(object, ["items", "data", 0, "price", "interval"])
    ]

    stated = Enum.reject(intervals, &is_nil/1)

    if stated != [] and Enum.all?(stated, &(&1 in ["monthly", "month"])),
      do: :ok,
      else: {:error, {:invalid, :billing_interval}}
  end

  defp status(value, _name)
       when value in ~w(active past_due canceled incomplete incomplete_expired paused trialing unpaid),
       do: {:ok, value}

  defp status(_value, name), do: {:error, {:invalid, name}}

  defp invoice_status(value) when value in ~w(draft open paid uncollectible void),
    do: {:ok, value}

  defp invoice_status(_), do: {:error, {:invalid, :invoice_status}}

  defp currency(value) when is_binary(value) and byte_size(value) == 3 do
    if value == String.downcase(value), do: {:ok, value}, else: {:error, {:invalid, :currency}}
  end

  defp currency(_), do: {:error, {:invalid, :currency}}
  defp non_negative_integer(value, _name) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_negative_integer(_, name), do: {:error, {:invalid, name}}
  defp required_boolean(value, _name) when is_boolean(value), do: {:ok, value}
  defp required_boolean(_, name), do: {:error, {:invalid, name}}
  defp required_map(value, _name) when is_map(value), do: {:ok, value}
  defp required_map(_, name), do: {:error, {:invalid, name}}

  defp required_string(value, _name) when is_binary(value) and byte_size(value) in 1..255,
    do: {:ok, value}

  defp required_string(_, name), do: {:error, {:invalid, name}}
  defp optional_string(value) when is_binary(value) and byte_size(value) <= 255, do: value
  defp optional_string(_), do: nil

  defp stripe_datetime(value, _name) when is_integer(value) and value >= 0,
    do: {:ok, DateTime.from_unix!(value)}

  defp stripe_datetime(%DateTime{} = value, _name), do: {:ok, value}
  defp stripe_datetime(_, name), do: {:error, {:invalid, name}}
  defp optional_stripe_datetime(nil), do: nil

  defp optional_stripe_datetime(value) do
    case stripe_datetime(value, :created) do
      {:ok, datetime} -> datetime
      _ -> nil
    end
  end

  defp required_event_datetime(%DateTime{} = value), do: {:ok, value}
  defp required_event_datetime(_value), do: {:error, {:invalid, :event_created_at}}

  defp explicit_org_id(object) do
    explicit_value(value(object, "metadata"), "org_id") ||
      explicit_value(value(object, "metadata"), "alplus_org_id") ||
      optional_string(value(object, "client_reference_id"))
  end

  defp explicit_value(map, key) when is_map(map), do: optional_string(value(map, key))
  defp explicit_value(_, _), do: nil

  # `key` is always one of a handful of literal strings written at each call
  # site in this module ("id", "type", "metadata", ...), never an
  # attacker-controlled key name — only the *values* in the decoded Stripe
  # payload are attacker-controlled. Jason decodes with string keys, so the
  # atom branch below is a defensive fallback, not the live path.
  # sobelow_skip ["DOS.StringToAtom"]
  defp value(map, key) when is_map(map) do
    if Map.has_key?(map, key) do
      Map.get(map, key)
    else
      Map.get(map, String.to_atom(key))
    end
  end

  defp value(_, _), do: nil

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

  defp payload_hash(event),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(event, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp environment(value) when value in [:local, :preview, :staging, :production],
    do: {:ok, Atom.to_string(value)}

  defp environment(value) when value in ~w(local preview staging production), do: {:ok, value}
  defp environment(_), do: {:error, :invalid_environment}
end
