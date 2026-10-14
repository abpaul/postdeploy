defmodule Alplus.Monitoring.HeartbeatRateLimiter do
  @moduledoc false

  use Hammer, backend: :ets, algorithm: :sliding_window

  @window_ms :timer.minutes(1)
  @absolute_requests_per_minute 120

  def check(token) when is_binary(token) do
    key = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

    case hit("heartbeat:" <> key, @window_ms, @absolute_requests_per_minute) do
      {:allow, _count} -> :ok
      {:deny, retry_after} -> {:error, max(1, ceil(retry_after / 1_000))}
    end
  end
end
