defmodule Alplus.Measure.AnalyticsEngine.DevAdapter do
  @moduledoc """
  Development Analytics Engine adapter.

  It stores only the same aggregate points that the batcher accepts. It exists
  to make local dashboard windows observable without creating a second data
  store or retaining visitor data.
  """

  @behaviour Alplus.Measure.AnalyticsEngine

  use GenServer

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Alplus.Measure.AnalyticsEngine
  def write(points) when is_list(points), do: GenServer.call(__MODULE__, {:write, points})

  @impl Alplus.Measure.AnalyticsEngine
  def recent(source_id, %DateTime{} = since),
    do: GenServer.call(__MODULE__, {:recent, source_id, since})

  @impl Alplus.Measure.AnalyticsEngine
  def recent_many(source_ids, %DateTime{} = since) when is_list(source_ids),
    do: GenServer.call(__MODULE__, {:recent_many, source_ids, since})

  # This store never evicts, so it holds everything it was ever given from its
  # oldest point onward. Before that point it holds nothing and cannot tell
  # "no traffic" from "never received", so it declares no coverage at all.
  @impl Alplus.Measure.AnalyticsEngine
  def coverage_since, do: GenServer.call(__MODULE__, :coverage_since)

  @doc false
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def init(_opts), do: {:ok, {:ets.new(@table, [:set, :private]), :unknown}}

  @impl true
  def handle_call({:write, points}, _from, {table, coverage}) do
    Enum.each(points, fn point ->
      key = {point.source_id, DateTime.to_unix(point.hour, :microsecond)}

      current =
        case :ets.lookup(table, key) do
          [{^key, saved}] -> saved
          [] -> %{point | pageviews: 0, visitors: 0, visits: 0, bounces: 0, duration_seconds: 0}
        end

      true = :ets.insert(table, {key, sum(current, point)})
    end)

    {:reply, :ok, {table, Enum.reduce(points, coverage, &earliest(&2, &1.hour))}}
  end

  def handle_call({:recent, source_id, since}, _from, {table, _coverage} = state) do
    points =
      :ets.tab2list(table)
      |> Enum.map(fn {_key, point} -> point end)
      |> Enum.filter(&(&1.source_id == source_id and DateTime.compare(&1.hour, since) != :lt))
      |> Enum.sort_by(&DateTime.to_unix(&1.hour, :microsecond))

    {:reply, {:ok, points}, state}
  end

  def handle_call({:recent_many, source_ids, since}, _from, {table, _coverage} = state) do
    id_set = MapSet.new(source_ids)

    points_by_source =
      :ets.tab2list(table)
      |> Enum.map(fn {_key, point} -> point end)
      |> Enum.filter(
        &(MapSet.member?(id_set, &1.source_id) and DateTime.compare(&1.hour, since) != :lt)
      )
      |> Enum.sort_by(&DateTime.to_unix(&1.hour, :microsecond))
      |> Enum.group_by(& &1.source_id)

    {:reply, {:ok, Map.new(source_ids, &{&1, Map.get(points_by_source, &1, [])})}, state}
  end

  def handle_call(:coverage_since, _from, {_table, coverage} = state),
    do: {:reply, coverage, state}

  def handle_call(:clear, _from, {table, _coverage}) do
    :ets.delete_all_objects(table)
    {:reply, :ok, {table, :unknown}}
  end

  defp earliest(:unknown, %DateTime{} = hour), do: {:ok, hour}

  defp earliest({:ok, %DateTime{} = current}, %DateTime{} = hour),
    do: {:ok, if(DateTime.compare(hour, current) == :lt, do: hour, else: current)}

  defp sum(current, point) do
    %{
      current
      | pageviews: current.pageviews + point.pageviews,
        visitors: current.visitors + point.visitors,
        visits: current.visits + point.visits,
        bounces: max(0, current.bounces + point.bounces),
        duration_seconds: current.duration_seconds + point.duration_seconds
    }
  end
end
