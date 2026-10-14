defmodule Alplus.Analytics.RateLimiter do
  @moduledoc """
  The `POST /v1/events` budget, on its own bucket (ADR 0007).

  Product analytics keys are published inside customer applications, so this
  path takes traffic from every installed copy at once. It never shares a
  budget with Observe or Measure: a burst of analytics events must not
  starve error ingest for the same project, or the reverse.

  The bucket counts requests, not events, and a request carries up to 100
  events. The monthly event quota (`Alplus.Billing.EventMeter`) is what
  bounds the volume; this bounds the request rate.
  """

  use Hammer, backend: :ets, algorithm: :sliding_window

  alias Alplus.Billing.Package

  @window_ms :timer.minutes(1)
  @absolute_requests_per_minute 600

  @spec check(String.t()) :: :ok | {:error, pos_integer()}
  def check(source_id) when is_binary(source_id) do
    limit = min(Package.limit(:api_rate_limit_per_minute), @absolute_requests_per_minute)

    case hit("analytics:" <> source_id, @window_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, retry_after} -> {:error, max(1, ceil(retry_after / 1_000))}
    end
  end
end
