defmodule Alplus.Monitoring.AnonymousProbe.RateLimiter do
  @moduledoc false

  use Hammer, backend: :ets, algorithm: :sliding_window

  @window_ms :timer.minutes(1)
  @scope "health-check"

  @spec check(:inet.ip_address() | String.t()) :: :ok | {:error, pos_integer()}
  def check(ip) do
    window_ms = setting(:window_ms, @window_ms)
    ip_limit = setting(:ip_limit, 10)
    global_limit = setting(:global_limit, 60)
    # One ETS table serves the whole node, so every counter is namespaced. A
    # test that needs its own budget sets `:scope` and shares nothing with the
    # traffic another test already recorded in the same window.
    scope = setting(:scope, @scope)

    with {:allow, _} <- hit(scope <> ":ip:" <> ip_key(ip), window_ms, ip_limit),
         {:allow, _} <- hit(scope <> ":global", window_ms, global_limit) do
      :ok
    else
      {:deny, retry_after} -> {:error, max(1, ceil(retry_after / 1_000))}
    end
  end

  defp ip_key(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp ip_key(ip) when is_binary(ip), do: ip

  defp setting(key, default) do
    :alplus
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
