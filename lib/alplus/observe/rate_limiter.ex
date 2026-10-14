defmodule Alplus.Observe.RateLimiter do
  @moduledoc false

  use Hammer, backend: :ets, algorithm: :sliding_window

  alias Alplus.Billing.Package

  @window_ms :timer.minutes(1)
  @absolute_requests_per_minute 600

  @spec check(String.t()) :: :ok | {:error, pos_integer()}
  def check(source_id) when is_binary(source_id) do
    limit = min(Package.limit(:api_rate_limit_per_minute), @absolute_requests_per_minute)

    case hit("observe:" <> source_id, @window_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, retry_after} -> {:error, max(1, ceil(retry_after / 1_000))}
    end
  end

  @doc """
  Rate-limits `POST /e/sessions` (issue #12) on its OWN bucket, distinct
  from `check/1`'s `/e/errors` bucket -- a burst of session traffic must
  never consume the same budget as (and starve) error ingest for the same
  Source, or vice versa.
  """
  @spec check_sessions(String.t()) :: :ok | {:error, pos_integer()}
  def check_sessions(source_id) when is_binary(source_id) do
    limit = min(Package.limit(:api_rate_limit_per_minute), @absolute_requests_per_minute)

    case hit("observe_sessions:" <> source_id, @window_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, retry_after} -> {:error, max(1, ceil(retry_after / 1_000))}
    end
  end
end
