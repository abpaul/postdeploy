defmodule Alplus.Measure.AnalyticsEngine.Batcher do
  @moduledoc false

  use GenServer

  @table __MODULE__
  @counter_key :counter
  @flush_interval_ms 1_000
  @max_batch_size 100
  @max_buffer_size 1_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec enqueue(Alplus.Measure.AnalyticsEngine.point()) :: :ok
  def enqueue(point) do
    if :ets.whereis(@table) == :undefined do
      dropped(:batcher_unavailable)
    else
      count = :ets.update_counter(@table, @counter_key, {2, 1})

      if count <= @max_buffer_size do
        true =
          :ets.insert(@table, {{System.unique_integer([:positive, :monotonic]), point}, true})

        report_depth(count)
      else
        _count = :ets.update_counter(@table, @counter_key, {2, -1})
        dropped(:buffer_full)
      end
    end

    :ok
  end

  @doc false
  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc false
  def depth do
    case :ets.whereis(@table) do
      :undefined -> 0
      _table -> :ets.lookup_element(@table, @counter_key, 2)
    end
  rescue
    ArgumentError -> 0
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :ordered_set, read_concurrency: true])
    true = :ets.insert(table, {@counter_key, 0})
    {:ok, %{timer: schedule_flush()}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    Process.cancel_timer(state.timer)
    drain_all()
    {:reply, :ok, %{state | timer: schedule_flush()}}
  end

  @impl true
  def handle_info(:flush, state) do
    drain_batch()
    delay = if depth() >= @max_batch_size, do: 0, else: @flush_interval_ms
    {:noreply, %{state | timer: Process.send_after(self(), :flush, delay)}}
  end

  defp drain_all do
    case take_batch() do
      [] ->
        :ok

      batch ->
        write(batch)
        drain_all()
    end
  end

  defp drain_batch do
    case take_batch() do
      [] -> :ok
      batch -> write(batch)
    end
  end

  defp take_batch, do: take_batch(:ets.next(@table, @counter_key), [])

  defp take_batch(:"$end_of_table", points), do: Enum.reverse(points)
  defp take_batch(_key, points) when length(points) >= @max_batch_size, do: Enum.reverse(points)

  defp take_batch(key, points) do
    next = :ets.next(@table, key)

    case :ets.take(@table, key) do
      [{{_sequence, point}, true}] ->
        _count = :ets.update_counter(@table, @counter_key, {2, -1})
        take_batch(next, [point | points])

      [] ->
        take_batch(next, points)
    end
  end

  defp write(points) do
    case Alplus.Measure.AnalyticsEngine.adapter().write(points) do
      :ok -> true
      {:error, _reason} -> dropped(:adapter_error, length(points)) == :ok
    end
  end

  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval_ms)

  defp dropped(reason, count \\ 1) do
    :telemetry.execute(
      [:alplus, :ingest, :analytics_engine, :dropped],
      %{count: count},
      %{reason: reason}
    )

    :ok
  end

  defp report_depth(value) do
    :telemetry.execute([:alplus, :ingest, :analytics_engine, :depth], %{depth: value}, %{})
    :ok
  end
end
