#!/usr/bin/env elixir

# Run locally with:
#
#     MIX_TEST_PARTITION=analytics_benchmark MIX_ENV=test mix ecto.create
#     MIX_TEST_PARTITION=analytics_benchmark MIX_ENV=test mix ecto.migrate
#     MIX_TEST_PARTITION=analytics_benchmark MIX_ENV=test mix run scripts/benchmark-analytics-queries.exs
#
# Optional: EVENTS=1000000 to change the fixture size. The default is 100k.
#
# Answers one question (ADR 0007): at what event volume does reading raw
# `product_events` stop being fast enough for a dashboard, and therefore when
# does the table need partitioning or a rollup ladder.
#
# The script requires test mode, uses the SQL sandbox, and rolls every fixture
# row back. It runs ANALYZE before timing, because sandbox inserts are
# invisible to autovacuum and an unanalyzed table makes the planner pick a
# nested loop that says nothing about production.

if Mix.env() != :test do
  raise "refusing to benchmark outside MIX_ENV=test"
end

defmodule Alplus.AnalyticsQueryBenchmark do
  alias Alplus.Analytics.Queries
  alias Alplus.{Repo, Scope}
  alias Alplus.OrgsFixtures

  @now DateTime.utc_now()
  @repetitions 5
  @window_days 90
  @events_per_person 8
  @batch 2_000

  def run do
    Req.Test.stub(Alplus.Accounts.Hibp.Client, fn conn -> Req.Test.text(conn, "") end)

    Req.Test.stub(Alplus.Turnstile.Client, fn conn ->
      Req.Test.json(conn, %{"success" => true})
    end)

    unless Repo.config()[:hostname] in ["127.0.0.1", "localhost"] do
      raise "benchmark requires a local PostgreSQL server"
    end

    total = String.to_integer(System.get_env("EVENTS", "100000"))
    # A million-row funnel can outlast the default 120 s ownership window,
    # and the point of the run is to learn how long it takes, not to watch
    # the sandbox give up on it.
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, ownership_timeout: :infinity)

    try do
      {org, owner_scope} = OrgsFixtures.org_fixture(OrgsFixtures.scope_fixture())
      OrgsFixtures.subscribed_fixture(org)
      project = OrgsFixtures.project_fixture(owner_scope, org)
      scope = Scope.put_project(owner_scope, project.id)

      {source, _secret} =
        OrgsFixtures.source_fixture(owner_scope, org, project, %{type: :analytics})

      IO.puts("seeding #{total} events across #{@window_days} days")
      seed!(org, project, source, total)

      Repo.query!("ANALYZE product_events")
      report_size()

      measure("totals, 30d", fn -> Queries.totals(scope, Queries.range("30d", @now)) end)

      measure("list_events, 30d", fn ->
        Queries.list_events(scope, Queries.range("30d", @now), limit: 100)
      end)

      measure("time_series, 30d by day", fn ->
        Queries.time_series(scope, Queries.range("30d", @now), interval: "day")
      end)

      measure("breakdown app_version, 30d", fn ->
        Queries.breakdown(scope, Queries.range("30d", @now), "app_version",
          event_name: "onboarding_completed"
        )
      end)

      measure("funnel, 4 steps, 90d", fn ->
        Queries.funnel(
          scope,
          Queries.range("90d", @now),
          ["first_open", "onboarding_started", "onboarding_completed", "meal_logged"]
        )
      end)

      measure("funnel, 4 steps, 90d, breakdown", fn ->
        Queries.funnel(
          scope,
          Queries.range("90d", @now),
          ["first_open", "onboarding_started", "onboarding_completed", "meal_logged"],
          breakdown: "app_version"
        )
      end)

      measure("retention, daily, 90d", fn ->
        Queries.retention(scope, Queries.range("90d", @now), "meal_logged", "meal_logged")
      end)

      measure("funnel, 4 steps, 90d, one app", fn ->
        Queries.funnel(
          scope,
          Queries.range("90d", @now),
          ["first_open", "onboarding_started", "onboarding_completed", "meal_logged"],
          source_id: source.id
        )
      end)

      measure("totals filtered by property, 30d", fn ->
        Queries.totals(scope, Queries.range("30d", @now), filters: %{"platform" => "ios"})
      end)

      measure("live_events", fn -> Queries.live_events(scope) end)
    after
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end
  end

  defp seed!(org, project, source, total) do
    people = div(total, @events_per_person)
    names = ~w(first_open onboarding_started onboarding_completed meal_logged paywall_viewed
               trial_started subscription_started insight_viewed)

    0..(people - 1)
    |> Stream.chunk_every(div(@batch, @events_per_person))
    |> Enum.each(fn chunk ->
      rows =
        Enum.flat_map(chunk, fn index ->
          day = rem(index, @window_days)
          at = DateTime.add(@now, -(@window_days - day) * 86_400, :second)

          properties = %{
            "app_version" => if(rem(index, 3) == 0, do: "1.9.0", else: "1.8.0"),
            "platform" => Enum.at(~w(ios android web), rem(index, 3)),
            "onboarding_variant" => if(rem(index, 2) == 0, do: "short", else: "long")
          }

          names
          |> Enum.with_index()
          |> Enum.map(fn {name, step} ->
            [
              Alplus.Id.generate(:product_event),
              org.id,
              project.id,
              source.id,
              "production",
              name,
              "anon_#{index}",
              DateTime.add(at, step * 600, :second),
              properties
            ]
          end)
        end)

      insert!(rows)
    end)
  end

  defp insert!(rows) do
    {placeholders, params} =
      rows
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {row, index}, {groups, params} ->
        base = index * 9

        group =
          "($#{base + 1},$#{base + 2},$#{base + 3},$#{base + 4},$#{base + 5},$#{base + 6}," <>
            "$#{base + 7},$#{base + 8},$#{base + 8},$#{base + 9})"

        {groups ++ [group], params ++ row}
      end)

    Repo.query!(
      """
      INSERT INTO product_events
        (id, org_id, project_id, source_id, environment, event_name, distinct_id,
         occurred_at, received_at, properties)
      VALUES #{Enum.join(placeholders, ", ")}
      """,
      params
    )
  end

  defp report_size do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM product_events")

    %{rows: [[total, table, indexes]]} =
      Repo.query!("""
      SELECT pg_size_pretty(pg_total_relation_size('product_events')),
             pg_size_pretty(pg_relation_size('product_events')),
             pg_size_pretty(pg_indexes_size('product_events'))
      """)

    IO.puts("\n#{count} rows, #{total} total (#{table} table, #{indexes} indexes)\n")
  end

  defp measure(label, fun) do
    fun.()

    times =
      for _repetition <- 1..@repetitions do
        {microseconds, _result} = :timer.tc(fun)
        microseconds / 1_000
      end

    sorted = Enum.sort(times)
    median = Enum.at(sorted, div(@repetitions, 2))
    worst = List.last(sorted)

    IO.puts(
      String.pad_trailing(label, 36) <>
        "median #{format(median)} ms, worst #{format(worst)} ms"
    )
  end

  defp format(value), do: :erlang.float_to_binary(value, decimals: 1)
end

Alplus.AnalyticsQueryBenchmark.run()
