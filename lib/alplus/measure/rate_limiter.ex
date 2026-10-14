defmodule Alplus.Measure.RateLimiter do
  @moduledoc false

  use Hammer, backend: :ets, algorithm: :sliding_window

  alias Alplus.Billing.Package

  @window_ms :timer.minutes(1)
  @absolute_requests_per_minute 600

  @spec check(String.t()) :: :ok | {:error, pos_integer()}
  def check(source_id) when is_binary(source_id) do
    limit = min(Package.limit(:api_rate_limit_per_minute), @absolute_requests_per_minute)

    case hit("measure:" <> source_id, @window_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, retry_after} -> {:error, max(1, ceil(retry_after / 1_000))}
    end
  end

  @doc "Limits anonymous dashboard reads independently for each resolved share."
  def check_share(share_id) when is_binary(share_id) do
    case hit("measure-share:" <> share_id, @window_ms, 60) do
      {:allow, _count} -> :ok
      {:deny, retry_after} -> {:error, max(1, ceil(retry_after / 1_000))}
    end
  end
end
