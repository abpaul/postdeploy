defmodule Alplus.Mcp.RateLimit do
  @moduledoc "Applies plan, organization, user, and tool weighted budgets with Hammer."

  use Hammer, backend: :ets, algorithm: :sliding_window

  alias Alplus.Billing.{Access, Package}
  alias Alplus.Mcp.{Error, Principal, Tool}

  @window_ms :timer.minutes(1)
  @burst_window_ms :timer.seconds(1)
  @burst_limit 20
  # Inactive plans retain a small read-only recovery budget, never unlimited
  # reads that bypass the MCP rate boundary.
  @inactive_read_budget 10

  @spec check(Principal.t(), String.t()) :: :ok | {:error, Error.t()}
  def check(%Principal{} = principal, tool) when is_binary(tool) do
    check(principal, tool, :read_write, 1)
  end

  @spec check(Principal.t(), Tool.t()) :: :ok | {:error, Error.t()}
  def check(%Principal{} = principal, %Tool{} = tool) do
    check(principal, tool.name, tool.requires_access, Tool.cost_weight!(tool))
  end

  def check(_principal, _tool), do: {:error, Error.from(:rate_limited)}

  defp check(principal, tool, access, cost) do
    case Access.check(principal.org_id) do
      {:ok, _access} ->
        charge(principal, tool, Package.limit(:api_rate_limit_per_minute), cost)

      {:error, %{code: :plan_inactive}} when access == :read ->
        charge(principal, tool, @inactive_read_budget, cost)

      {:error, entitlement_error} ->
        {:error, Error.from(entitlement_error)}
    end
  end

  defp charge(principal, tool, organization_budget, cost) do
    with {:allow, _count} <-
           hit_cost("org:" <> principal.org_id, @window_ms, organization_budget, cost),
         {:allow, _count} <-
           optional_hit(
             "project:",
             principal.project_id,
             @window_ms,
             organization_budget,
             cost
           ),
         {:allow, _count} <-
           hit_cost("user:" <> principal.user_id, @burst_window_ms, @burst_limit, cost),
         {:allow, _count} <-
           optional_hit(
             "grant:",
             principal.grant_id,
             @burst_window_ms,
             @burst_limit,
             cost
           ) do
      :ok
    else
      {:deny, retry_after} ->
        {:error,
         Error.new(:rate_limited, "Rate limit exceeded", %{
           retry_after_ms: retry_after,
           tool: tool
         })}
    end
  end

  defp optional_hit(_prefix, nil, _window, _limit, _cost), do: {:allow, 0}

  defp optional_hit(prefix, id, window, limit, cost) when is_binary(id),
    do: hit_cost(prefix <> id, window, limit, cost)

  # Charge cost units in both windows. If the burst window counted requests
  # instead of units, its cap would hide every tool's configured weight.
  defp hit_cost(key, window, limit, cost) do
    Enum.reduce_while(1..cost, {:allow, 0}, fn _, _result ->
      case hit(key, window, limit) do
        {:allow, count} -> {:cont, {:allow, count}}
        {:deny, _retry_after} = denied -> {:halt, denied}
      end
    end)
  end
end
