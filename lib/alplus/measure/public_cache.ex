defmodule Alplus.Measure.PublicCache do
  @moduledoc "A short-lived, per-panel cache for anonymous Measure dashboard reads."

  use GenServer

  @table __MODULE__
  @ttl_ms :timer.seconds(30)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def fetch(key, fun) when is_function(fun, 0) do
    :global.trans({{__MODULE__, key}, self()}, fn -> fetch_locked(key, fun) end)
  end

  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @ttl_ms)
    {:ok, %{}}
  end

  defp fetch_locked(key, fun) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now -> value
      _missing_or_expired -> put(key, fun.(), now)
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @ttl_ms)
    {:noreply, state}
  end

  defp put(key, value, now) do
    true = :ets.insert(@table, {key, value, now + @ttl_ms})
    value
  end
end
