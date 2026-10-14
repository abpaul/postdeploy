defmodule Alplus.Notifications.AlertRateLimiter do
  @moduledoc "Absolute safety limits for telemetry-triggered notification jobs."

  use Hammer, backend: :ets, algorithm: :sliding_window

  @window_ms :timer.minutes(1)
  @per_org_limit 60
  @global_limit 600

  @spec check(String.t()) :: :ok | {:error, :tenant_limit | :global_limit}
  def check(org_id) when is_binary(org_id) do
    case hit("alerts:org:" <> org_id, @window_ms, @per_org_limit) do
      {:deny, _retry_after} ->
        {:error, :tenant_limit}

      {:allow, _count} ->
        case hit("alerts:global", @window_ms, @global_limit) do
          {:allow, _count} -> :ok
          {:deny, _retry_after} -> {:error, :global_limit}
        end
    end
  end
end
