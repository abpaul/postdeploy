defmodule Alplus.Status.RateLimiter do
  @moduledoc "Per-page anonymous read limit for public status pages."

  use Hammer, backend: :ets, algorithm: :sliding_window

  @window_ms :timer.minutes(1)
  @limit 120

  @spec check(String.t()) :: :ok | {:error, pos_integer()}
  def check(page_id) when is_binary(page_id) do
    case hit("status-page:" <> page_id, @window_ms, @limit) do
      {:allow, _count} -> :ok
      {:deny, retry_after} -> {:error, max(1, ceil(retry_after / 1_000))}
    end
  end
end
