#!/usr/bin/env elixir

# Run locally with:
#
#     MIX_TEST_PARTITION=measure_benchmark MIX_ENV=test mix ecto.create
#     MIX_TEST_PARTITION=measure_benchmark MIX_ENV=test mix ecto.migrate
#     MIX_TEST_PARTITION=measure_benchmark MIX_ENV=test mix run scripts/benchmark-measure-queries.exs
#
# The script requires test mode, uses the SQL sandbox, and rolls back all
# fixture rows. It uses the production UnavailableAdapter, so every read uses
# durable PostgreSQL rollups. It reports warm wall times and Repo telemetry.

if Mix.env() != :test do
  raise "refusing to benchmark outside MIX_ENV=test"
end

defmodule Alplus.MeasureQueryBenchmark do
  alias Alplus.{Repo, Scope}
  alias Alplus.Measure.Dashboard
  alias Alplus.OrgsFixtures

  @now DateTime.utc_now()
  @repetitions 20
  @windows ["7d", "30d"]
  @dimensions ["path", "referrer", "event"]
  @telemetry_id {__MODULE__, :repo_queries}

  def run do
    Req.Test.stub(Alplus.Accounts.Hibp.Client, fn conn -> Req.Test.text(conn, "") end)

    Req.Test.stub(Alplus.Turnstile.Client, fn conn ->
      Req.Test.json(conn, %{"success" => true})
    end)

    unless Repo.config()[:hostname] in ["127.0.0.1", "localhost"] do
      raise "benchmark requires a local PostgreSQL server"
    end

    IO.inspect(Repo.query!("SELECT current_database(), version()").rows, label: "local database")

    previous_adapter = Application.get_env(:alplus, :analytics_engine_adapter)

    Application.put_env(
      :alplus,
      :analytics_engine_adapter,
      Alplus.Measure.AnalyticsEngine.UnavailableAdapter
    )

    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    attach_telemetry()

    try do
      {org, owner_scope} = OrgsFixtures.org_fixture(OrgsFixtures.scope_fixture())
      OrgsFixtures.set_plan_fixture(org, "scale")
      project = OrgsFixtures.project_fixture(owner_scope, org)
      scope = Scope.put_project(owner_scope, project.id)
      sources = create_sources(org, project, owner_scope, 10)
      seed_rollups!(org, project, sources)
      validate_fixture!(org, project, sources)
      # Sandbox inserts are invisible to autovacuum. Refresh the planner before timing.
      for table <-
            ~w(analytics_days analytics_hours analytics_dimensions memberships organizations subscriptions sources) do
        Repo.query!("ANALYZE " <> table)
      end

      results = benchmark(sources, scope)
      explain = explain_hot_query(sources, scope)
      output(results, explain)
    after
      :telemetry.detach(@telemetry_id)
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
      Application.put_env(:alplus, :analytics_engine_adapter, previous_adapter)
    end
  end

  defp attach_telemetry do
    :telemetry.attach(
      @telemetry_id,
      [:alplus, :repo, :query],
      fn _event, measurements, metadata, _config ->
        if Process.get(:measure_benchmark_queries) do
          Process.put(:measure_benchmark_queries, [
            %{
              measurements: measurements,
              query: Map.get(metadata, :query, ""),
              params: Map.get(metadata, :params, [])
            }
            | Process.get(:measure_benchmark_queries)
          ])
        end
      end,
      nil
    )
  end

  defp create_sources(org, project, owner_scope, count) do
    Enum.map(1..count, fn index ->
      {source, _secret} =
        OrgsFixtures.source_fixture(owner_scope, org, project, %{
          type: :measure,
          environment: "production",
          name: "Benchmark #{index}"
        })

      %{source | inserted_at: DateTime.add(@now, -120 * 86_400, :second)}
    end)
  end

  defp seed_rollups!(org, project, sources) do
    # Bulk inserts model durable aggregate rows without timing the ingest path.
    source_ids = Enum.map(sources, & &1.id)
    first_id = hd(source_ids)

    Repo.query!(
      """
      INSERT INTO analytics_days
        (id, org_id, project_id, source_id, environment, date, pageviews, visitors, visits, bounces, duration_seconds, inserted_at, updated_at)
      SELECT md5(concat('measure-bench-day:', s.source_id, ':', d.day))::uuid,
             $1, $2, s.source_id, 'production',
           ((now() AT TIME ZONE 'UTC')::date - 59 + d.day)::date,
             2400, 1920, 1680, 240, 2880,
             now(), now()
      FROM unnest($3::text[]) AS s(source_id)
      CROSS JOIN generate_series(0, 59) AS d(day)
      ON CONFLICT (project_id, environment, date, source_id) DO NOTHING
      """,
      [org.id, project.id, source_ids],
      timeout: 60_000
    )

    Repo.query!(
      """
      INSERT INTO analytics_hours
        (id, org_id, project_id, source_id, environment, hour, pageviews, visitors, visits, bounces, duration_seconds, inserted_at, updated_at)
      SELECT md5(concat('measure-bench-hour:', s.source_id, ':', h.hour))::uuid,
             $1, $2, s.source_id, 'production',
             (date_trunc('hour', now() AT TIME ZONE 'UTC') - interval '335 hours' + h.hour * interval '1 hour'),
             100, 80, 70, 10, 120, now(), now()
      FROM unnest($3::text[]) AS s(source_id)
      CROSS JOIN generate_series(0, 335) AS h(hour)
      ON CONFLICT (project_id, environment, hour, source_id) DO NOTHING
      """,
      [org.id, project.id, source_ids],
      timeout: 60_000
    )

    # The first source carries the full 1,000-value daily cardinality curve.
    # The second source carries 100 values. The remaining eight carry 10 values.
    Repo.query!(
      """
      INSERT INTO analytics_dimensions
        (id, org_id, project_id, source_id, environment, date, dimension, value, visitors, pageviews, visits, inserted_at, updated_at)
      SELECT md5(concat('measure-bench-dimension:', s.source_id, ':', d.day, ':', dim.name, ':', v.value))::uuid,
           $1, $2, s.source_id, 'production', ((now() AT TIME ZONE 'UTC')::date - 59 + d.day)::date,
             dim.name, CASE WHEN dim.name = 'event' THEN concat('event_', v.value) ELSE concat('/', dim.name, '/', v.value) END,
             1, 1, 1, now(), now()
      FROM unnest($3::text[]) AS s(source_id)
      CROSS JOIN generate_series(0, 59) AS d(day)
      CROSS JOIN unnest(ARRAY['path','referrer','event']::text[]) AS dim(name)
      CROSS JOIN LATERAL generate_series(1,
        CASE WHEN s.source_id = $4 THEN 1000
             WHEN s.source_id = $5 THEN 100
             ELSE 10 END) AS v(value)
      ON CONFLICT (project_id, environment, date, dimension, value, source_id) DO NOTHING
      """,
      [org.id, project.id, source_ids, first_id, Enum.at(source_ids, 1)],
      timeout: 60_000
    )
  end

  defp validate_fixture!(org, project, sources) do
    %{rows: [[day_count, hour_count, dimension_count]]} =
      Repo.query!(
        """
        SELECT
          (SELECT count(*) FROM analytics_days WHERE org_id = $1 AND project_id = $2),
          (SELECT count(*) FROM analytics_hours WHERE org_id = $1 AND project_id = $2),
          (SELECT count(*) FROM analytics_dimensions WHERE org_id = $1 AND project_id = $2)
        """,
        [org.id, project.id]
      )

    expected = {length(sources) * 60, length(sources) * 336, 60 * (1000 + 100 + 8 * 10) * 3}
    actual = {day_count, hour_count, dimension_count}

    IO.inspect(actual, label: "fixture rows (days, hours, dimensions)")

    if actual != expected,
      do: raise("fixture count mismatch: expected #{inspect(expected)}, got #{inspect(actual)}")
  end

  defp benchmark(sources, scope) do
    portfolios =
      for window <- @windows, count <- [1, 10], into: %{} do
        {"portfolio/#{window}/sources=#{count}",
         timed(fn -> Dashboard.portfolio(Enum.take(sources, count), window, scope, now: @now) end)}
      end

    details =
      for window <- @windows, cardinality <- [10, 100, 1000], into: %{} do
        source = Enum.at(sources, cardinality_source_index(cardinality))
        result = timed(fn -> detail_load(source, window, scope) end)

        IO.puts(
          "detail/#{window}/cardinality=#{cardinality}: #{inspect(Map.drop(result, [:samples]))}"
        )

        {"detail/#{window}/cardinality=#{cardinality}", result}
      end

    one_panel = timed(fn -> Dashboard.panel(hd(sources), "30d", "path", 1, scope, now: @now) end)
    portfolios |> Map.merge(details) |> Map.put("panel/30d/cardinality=1000", one_panel)
  end

  defp cardinality_source_index(10), do: 2
  defp cardinality_source_index(100), do: 1
  defp cardinality_source_index(1000), do: 0

  defp detail_load(source, window, scope) do
    summary = Dashboard.summaries([source], window, scope)
    comparison = Dashboard.comparison(source, window, scope, now: @now)
    panels = Enum.map(@dimensions, &Dashboard.panel(source, window, &1, 1, scope, now: @now))

    if map_size(summary) != 1 or comparison.unavailable? or Enum.any?(panels, &(&1.rows == [])),
      do: raise("benchmark read returned empty or unavailable data")

    if get_in(summary, [source.id, :totals, :pageviews]) <= 0 do
      raise "summary must report seeded traffic"
    end

    expected_days = if window == "7d", do: 7, else: 30

    Enum.each(panels, fn panel ->
      unless length(panel.rows) == 8 and Enum.all?(panel.rows, &(&1.count == expected_days)) do
        raise "panel must aggregate each value over the selected date window"
      end
    end)

    %{summary: summary, comparison: comparison, panels: panels}
  end

  defp timed(fun) do
    Process.delete(:measure_benchmark_queries)
    fun.()
    fun.()

    samples =
      for _ <- 1..@repetitions do
        Process.put(:measure_benchmark_queries, [])
        {micros, result} = :timer.tc(fun)
        queries = Process.get(:measure_benchmark_queries, [])
        Process.delete(:measure_benchmark_queries)
        if queries == [], do: raise("Repo telemetry captured no queries")
        if empty_result?(result), do: raise("benchmark read returned empty data")
        %{wall_ms: micros / 1000, queries: queries}
      end

    %{
      wall_ms: summarize(Enum.map(samples, & &1.wall_ms)),
      query_count: summarize(Enum.map(samples, &length(&1.queries))),
      db_ms: summarize(Enum.map(samples, &db_ms(&1.queries))),
      samples: samples
    }
  end

  defp empty_result?(%{unavailable?: true}), do: true
  defp empty_result?(%{rows: rows}), do: rows == []

  defp empty_result?(%{totals: %{pageviews: %{value: value}}}),
    do: not is_number(value) or value <= 0

  defp empty_result?(%{sites: sites}) when map_size(sites) == 0, do: true
  defp empty_result?(_), do: false

  defp db_ms(queries),
    do:
      Enum.sum(
        Enum.map(
          queries,
          &(native_ms(Map.get(&1.measurements, :query_time, 0)) +
              native_ms(Map.get(&1.measurements, :decode_time, 0)))
        )
      )

  defp native_ms(value), do: System.convert_time_unit(value, :native, :microsecond) / 1000

  defp summarize(values) do
    sorted = Enum.sort(values)

    %{
      median:
        (Enum.at(sorted, div(length(sorted) - 1, 2)) + Enum.at(sorted, div(length(sorted), 2))) /
          2,
      p95: percentile(sorted, 0.95)
    }
  end

  defp percentile([], _), do: 0.0

  defp percentile(values, p),
    do: Enum.at(values, min(length(values) - 1, max(0, ceil(p * length(values)) - 1)))

  defp explain_hot_query(sources, scope) do
    source = hd(sources)

    %{samples: samples} =
      timed(fn -> Dashboard.panel(source, "30d", "path", 1, scope, now: @now) end)

    queries =
      samples
      |> List.last()
      |> Map.get(:queries, [])
      |> Enum.filter(&String.contains?(&1.query, "analytics_dimensions"))

    if queries == [], do: raise("expected a dimension query")

    Enum.map(queries, fn query ->
      %{rows: rows} =
        Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> query.query, query.params)

      %{query: query.query, explain: hd(rows) |> hd()}
    end)
  end

  defp output(results, explain) do
    File.mkdir_p!(".context")

    File.write!(
      ".context/measure-benchmark.json",
      Jason.encode!(
        %{
          generated_at: DateTime.utc_now(),
          now: @now,
          repetitions: @repetitions,
          warmups: 2,
          fixture: %{sources: 10, days: 60, hours: 336, dimension_rows: 212_400},
          results: results
        },
        pretty: true
      )
    )

    File.write!(".context/measure-benchmark-explain.json", Jason.encode!(explain, pretty: true))
    IO.puts("Measure benchmark written to .context/measure-benchmark.json")
    IO.puts("Hot analytics_dimensions plan written to .context/measure-benchmark-explain.json")

    IO.inspect(Map.new(results, fn {key, value} -> {key, Map.drop(value, [:samples])} end),
      label: "warm results"
    )
  end
end

Alplus.MeasureQueryBenchmark.run()
