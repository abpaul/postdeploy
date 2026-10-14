defmodule Alplus.Measure.Dashboard.TelemetryResolver do
  @moduledoc """
  Resolves Measure telemetry through Analytics Engine and PostgreSQL rollups.

  Callers provide the PostgreSQL adapter because private dashboard and public
  share actors use different Ash actions. This module owns source selection,
  merging, fallback, and result metadata for both actor types.
  """

  require Logger

  alias Alplus.Measure.{AnalyticsEngine, DataLayerErrors}

  @type metadata :: %{
          data_source: String.t(),
          data_source_key: :analytics_engine | :postgres_rollup | :mixed_rollup | :unavailable,
          fallback?: boolean(),
          unavailable?: boolean(),
          analytics_engine_state: :available | :empty | :partial | :unavailable,
          analytics_engine_partial?: boolean(),
          analytics_engine_unavailable?: boolean(),
          durable_coverage?: boolean()
        }

  @doc "Resolves recent hourly points from both telemetry adapters."
  def recent(sources, since, until, rollup_adapter) when is_function(rollup_adapter, 3) do
    source_ids = Enum.map(sources, & &1.id)

    case recent_points(source_ids, since, until) do
      {:ok, ae_points} ->
        case rollup_adapter.(sources, since, until) do
          {:ok, rollup_points} -> merge(source_ids, ae_points, rollup_points)
          {:error, _reason} -> engine_only(source_ids, ae_points, coverage_since(), since)
        end

      {:error, _reason} ->
        case rollup_adapter.(sources, since, until) do
          {:ok, rollup_points} ->
            {rollup_points, metadata_for(source_ids, :postgres_rollup, true, :unavailable, true)}

          {:error, _reason} ->
            unavailable(source_ids)
        end
    end
  end

  @doc "Resolves historical daily points from the PostgreSQL adapter."
  def historical(sources, since, until, rollup_adapter) when is_function(rollup_adapter, 3) do
    source_ids = Enum.map(sources, & &1.id)

    case rollup_adapter.(sources, since, until) do
      {:ok, points} ->
        {points, metadata_for(source_ids, :postgres_rollup, false, :available, true)}

      {:error, _reason} ->
        unavailable(source_ids)
    end
  end

  defp recent_points(source_ids, since, until) do
    case AnalyticsEngine.recent_many(source_ids, since, until) do
      {:ok, points} when is_map(points) ->
        {:ok,
         Map.new(source_ids, fn source_id ->
           {source_id, Map.get(points, source_id, [])}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception ->
      if DataLayerErrors.unavailable?(exception) do
        Logger.warning(
          "analytics engine recent_many failed, falling back: #{Exception.message(exception)}"
        )

        {:error, :unavailable}
      else
        reraise(exception, __STACKTRACE__)
      end
  end

  defp merge(source_ids, ae_points, rollup_points) do
    Enum.reduce(source_ids, {%{}, %{}}, fn source_id, {resolved, metadata} ->
      ae = Map.get(ae_points, source_id, [])
      durable = Map.get(rollup_points, source_id, [])

      {points, entry} =
        cond do
          ae == [] and durable == [] ->
            {[], metadata(:postgres_rollup, true, :empty, true)}

          ae == [] ->
            {durable, metadata(:postgres_rollup, true, :empty, true)}

          durable == [] ->
            {ae, metadata(:analytics_engine, false, :available, true)}

          true ->
            durable_by_bucket = Map.new(durable, &{bucket_key(&1), &1})
            ae_by_bucket = Map.new(ae, &{bucket_key(&1), &1})
            merged = Map.merge(durable_by_bucket, ae_by_bucket) |> Map.values() |> sort_points()

            entry =
              if map_size(Map.drop(durable_by_bucket, Map.keys(ae_by_bucket))) > 0 do
                metadata(:mixed_rollup, true, :partial, true)
              else
                metadata(:analytics_engine, false, :available, true)
              end

            {merged, entry}
        end

      {Map.put(resolved, source_id, points), Map.put(metadata, source_id, entry)}
    end)
  end

  defp engine_only(source_ids, ae_points, coverage_since, since) do
    Enum.reduce(source_ids, {%{}, %{}}, fn source_id, {resolved, metadata} ->
      points = Map.get(ae_points, source_id, [])

      entry =
        cond do
          points != [] and covers?(coverage_since, since) ->
            metadata(:analytics_engine, false, :available, false, coverage_since)

          points != [] ->
            metadata(:analytics_engine, false, :partial, false, coverage_since)

          covers?(coverage_since, since) ->
            metadata(:analytics_engine, false, :empty, false, coverage_since)

          true ->
            metadata(:unavailable, false, :unavailable, false, coverage_since)
        end

      {Map.put(resolved, source_id, points), Map.put(metadata, source_id, entry)}
    end)
  end

  defp unavailable(source_ids) do
    {Map.new(source_ids, &{&1, []}),
     metadata_for(source_ids, :unavailable, false, :unavailable, false)}
  end

  defp metadata_for(source_ids, key, fallback?, engine_state, durable_coverage?) do
    Map.new(source_ids, &{&1, metadata(key, fallback?, engine_state, durable_coverage?)})
  end

  defp metadata(key, fallback?, engine_state, durable_coverage?, coverage_since \\ :complete) do
    %{
      data_source: data_source(key),
      data_source_key: key,
      fallback?: fallback?,
      unavailable?: key == :unavailable,
      analytics_engine_state: engine_state,
      analytics_engine_partial?: engine_state == :partial,
      analytics_engine_unavailable?: engine_state == :unavailable,
      durable_coverage?: durable_coverage?,
      coverage_since: coverage_since
    }
  end

  defp data_source(:analytics_engine), do: "Analytics Engine"
  defp data_source(:postgres_rollup), do: "PostgreSQL rollups"
  defp data_source(:mixed_rollup), do: "Analytics Engine and PostgreSQL rollups"
  defp data_source(:unavailable), do: "Data unavailable"

  defp bucket_key(%{hour: hour}), do: DateTime.to_unix(hour, :microsecond)
  defp sort_points(points), do: Enum.sort_by(points, & &1.hour, {:asc, DateTime})

  defp coverage_since do
    AnalyticsEngine.coverage_since()
  rescue
    exception ->
      if DataLayerErrors.unavailable?(exception),
        do: :unknown,
        else: reraise(exception, __STACKTRACE__)
  end

  defp covers?({:ok, %DateTime{} = boundary}, %DateTime{} = since),
    do: DateTime.compare(boundary, since) != :gt

  defp covers?(_coverage_since, _since), do: false
end
