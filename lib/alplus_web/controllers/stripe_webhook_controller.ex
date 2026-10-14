defmodule AlplusWeb.StripeWebhookController do
  use AlplusWeb, :controller

  alias Alplus.Billing.{StripeConfig, WebhookProcessor, WebhookWorker}

  @doc "Accepts Stripe deliveries after checking their exact signed wire body."
  def create(conn, _params) do
    with {:ok, payload} <- raw_body(conn),
         {:ok, signature} <- stripe_signature(conn),
         {:ok, secret} <- StripeConfig.webhook_secret(),
         {:ok, environment} <- StripeConfig.environment(),
         {:ok, event} <- construct_event(payload, signature, secret),
         :ok <- validate_livemode(event, environment),
         {:ok, response} <- acknowledge(event, environment, conn) do
      response
    else
      {:error, :invalid_signature} -> reject(conn, :bad_request)
      {:error, :invalid_livemode} -> reject(conn, :bad_request)
      {:error, :missing_signature} -> reject(conn, :bad_request)
      {:error, :invalid_payload} -> reject(conn, :bad_request)
      {:error, :enqueue_failed} -> reject(conn, :internal_server_error)
      {:error, :missing_webhook_secret} -> reject(conn, :internal_server_error)
      {:error, :invalid_stripe_environment} -> reject(conn, :internal_server_error)
    end
  end

  defp acknowledge(event, environment, conn) do
    if WebhookProcessor.supported_type?(event["type"]) do
      case WebhookProcessor.normalize_event(event) do
        {:ok, normalized_event} ->
          case WebhookWorker.new(%{
                 "event" => normalized_event,
                 "stripe_environment" => environment
               })
               |> Oban.insert() do
            {:ok, _job} -> {:ok, send_resp(conn, :ok, "")}
            {:error, _changeset} -> {:error, :enqueue_failed}
          end

        {:error, :invalid_payload} ->
          {:error, :invalid_payload}
      end
    else
      # Stripe retries non-2xx responses. Unsupported event types are deliberately
      # acknowledged, so they cannot block the endpoint or produce retry noise.
      {:ok, send_resp(conn, :ok, "")}
    end
  end

  defp raw_body(%{private: %{alplus_raw_body: payload}}) when is_binary(payload),
    do: {:ok, payload}

  defp raw_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, payload, _conn} -> {:ok, payload}
      _ -> {:error, :invalid_payload}
    end
  end

  defp stripe_signature(conn) do
    case Plug.Conn.get_req_header(conn, "stripe-signature") do
      [signature] when byte_size(signature) > 0 -> {:ok, signature}
      _ -> {:error, :missing_signature}
    end
  end

  defp construct_event(payload, signature, secret) do
    try do
      case Stripe.Webhook.construct_event(payload, signature, secret, response_as: :map) do
        {:ok, event} when is_map(event) -> {:ok, event}
        {:error, _reason} -> {:error, :invalid_signature}
      end
    rescue
      Jason.DecodeError -> {:error, :invalid_payload}
    end
  end

  defp validate_livemode(%{"livemode" => livemode}, environment) when is_boolean(livemode) do
    if StripeConfig.livemode_matches?(livemode, environment),
      do: :ok,
      else: {:error, :invalid_livemode}
  end

  defp validate_livemode(_, _environment), do: {:error, :invalid_payload}

  defp reject(conn, status), do: conn |> put_status(status) |> json(%{error: "invalid_webhook"})
end
