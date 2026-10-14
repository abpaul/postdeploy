defmodule Alplus.Billing.UsageCache do
  @moduledoc false

  use GenServer

  @table __MODULE__
  @ttl_ms :timer.minutes(5)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec fetch(String.t(), Date.t(), integer()) :: {:ok, map()} | :miss
  def fetch(org_id, period_start, now_ms) do
    case :ets.lookup(@table, {org_id, period_start}) do
      [{{^org_id, ^period_start}, expires_at, usage}] when expires_at > now_ms -> {:ok, usage}
      _ -> :miss
    end
  end

  @spec put(String.t(), Date.t(), map(), integer()) :: :ok
  def put(org_id, period_start, usage, now_ms) do
    true = :ets.insert(@table, {{org_id, period_start}, now_ms + @ttl_ms, usage})
    :ok
  end

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true, write_concurrency: true])
    {:ok, %{}}
  end
end
