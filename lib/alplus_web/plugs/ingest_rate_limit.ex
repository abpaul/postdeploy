defmodule AlplusWeb.Plugs.IngestRateLimit do
  @moduledoc """
  Package rate limiting for the ingest pipelines (issue #57).

  Runs in the pipeline immediately after authentication and before any
  body buffering or database work downstream, so a rate-limited client is
  rejected with `429` + `Retry-After` without the server reading its
  payload. The bucket selects both the limiter (Measure beacons have their
  own budget, separate from Observe errors/sessions) and the wire error
  shape those paths published before this plug existed.
  """

  @behaviour Plug

  import Plug.Conn

  alias Alplus.Billing.{Access, EntitlementError}

  # Fixed, compile-time bucket wiring — never request data.
  @buckets %{
    errors: {Alplus.Observe.RateLimiter, :check, "invalid_request_error"},
    sessions: {Alplus.Observe.RateLimiter, :check_sessions, "invalid_request_error"},
    artifacts: {Alplus.Observe.RateLimiter, :check, "invalid_request_error"},
    measure: {Alplus.Measure.RateLimiter, :check, "rate_limit_error"},
    product_events: {Alplus.Analytics.RateLimiter, :check, "rate_limit_error"}
  }

  @impl true
  def init(bucket) when is_map_key(@buckets, bucket), do: bucket

  @impl true
  def call(conn, bucket) do
    case conn.assigns[:source] do
      nil ->
        # The Measure token plug passes malformed payloads through so the
        # controller's envelope validation answers 400; nothing to limit.
        conn

      source ->
        case Access.check(source.org_id) do
          {:ok, _access} ->
            limit(conn, bucket, source)

          {:error, %EntitlementError{reason: :plan_inactive} = error} ->
            payment_required(conn, error)
        end
    end
  end

  defp limit(conn, bucket, source) do
    {limiter, check, error_type} = Map.fetch!(@buckets, bucket)

    case apply(limiter, check, [source.id]) do
      :ok ->
        conn

      {:error, retry_after} when is_integer(retry_after) ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_resp_content_type("application/json")
        |> send_resp(
          :too_many_requests,
          Jason.encode!(%{error: %{type: error_type, code: "rate_limit_exceeded"}})
        )
        |> halt()
    end
  end

  # The organization has no active access (issue #61): 402 with the same
  # `%{error: %{type, code}}` shape the ingest controllers emit, plus the
  # cause and purge date when the gate carried them.
  defp payment_required(conn, %EntitlementError{} = error) do
    payload =
      %{error: %{type: "invalid_request_error", code: "plan_inactive"}}
      |> maybe_put(:cause, error.cause)
      |> maybe_put(:purge_date, error.purge_date && Date.to_iso8601(error.purge_date))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(:payment_required, Jason.encode!(payload))
    |> halt()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
