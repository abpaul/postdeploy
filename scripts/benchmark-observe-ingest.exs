#!/usr/bin/env elixir

# Run with:
#
#     MIX_ENV=test mix run --no-start scripts/benchmark-observe-ingest.exs
#
# Add --profile to count calls in one warm 50-event batch with cprof.
# Do not use the profiled sample for latency comparisons.
#
# The script uses the real parser, writer, Postgres, source-map decoder, and
# symbolicator. It uses the test payload store, rolls back every sample, and
# reports wall-clock median and p95 values in milliseconds. Samples run
# sequentially. Cold means an empty decoded-map cache, not a cold database.
# Timing excludes fixture setup, result verification, and the sandbox rollback.
# It excludes HTTP authentication and real S3 latency. Run against local Postgres.
# Allow about 60 seconds. The sandbox rolls back the fixture and all samples.

defmodule Alplus.ObserveIngestBenchmark do
  alias Alplus.Observe.{Ingest, Release, ReleaseArtifact, Symbolicator}
  alias Alplus.OrgsFixtures
  alias Alplus.Repo
  alias Alplus.Scope

  @repetitions 15
  @source_name "webpack://benchmark/src/application.ts"
  @source_lines 1_000
  @frame_count 8
  @original_lines [1, 125, 250, 375, 500, 625, 750, 1000]

  def run do
    Req.Test.stub(Alplus.Accounts.Hibp.Client, fn conn -> Req.Test.text(conn, "") end)

    Req.Test.stub(Alplus.Turnstile.Client, fn conn ->
      Req.Test.json(conn, %{"success" => true})
    end)

    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    try do
      source = create_fixture()
      # Warm compiled paths before either cache condition.
      warm_up(source)

      if "--profile" in System.argv() do
        :cprof.start()
        measure(source, 50, :warm, 1) |> IO.inspect(label: "profile sample")
        :cprof.pause()
        IO.inspect(:cprof.analyse(Alplus.Observe.SourceMap), label: "source map calls")
        IO.inspect(:cprof.analyse(Regex), label: "regex calls")
        :cprof.stop()
      else
        samples =
          for item_count <- [1, 50], cache <- [:cold, :warm], into: %{} do
            {{item_count, cache}, measure(source, item_count, cache, @repetitions)}
          end

        print_report(samples)
      end
    after
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
      Application.delete_env(:alplus, :observe_payload_store_test_pid)
      Application.delete_env(:alplus, :observe_payload_store_test_gets)
    end
  end

  defp create_fixture do
    {org, owner_scope} = OrgsFixtures.org_fixture(OrgsFixtures.scope_fixture())
    project = OrgsFixtures.project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)
    {source, _secret} = OrgsFixtures.source_fixture(owner_scope, org, project)

    release =
      Ash.create!(
        Release,
        %{
          org_id: org.id,
          project_id: project.id,
          source_id: source.id,
          environment: source.environment,
          version: "benchmark-2026-09-06",
          commit_sha: String.duplicate("a", 40),
          released_at: DateTime.utc_now()
        },
        action: :create,
        authorize?: false
      )

    raw = source_map()
    storage_key = "artifacts/#{project.id}/#{release.id}/app-012345.js.map"
    sha256 = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

    Ash.create!(
      ReleaseArtifact,
      %{
        org_id: org.id,
        project_id: project.id,
        release_id: release.id,
        name: "app-012345.js.map",
        type: "source_map",
        storage_key: storage_key,
        sha256: sha256,
        byte_size: byte_size(raw)
      },
      action: :create,
      actor: scope
    )

    Application.put_env(:alplus, :observe_payload_store_test_pid, self())
    Application.put_env(:alplus, :observe_payload_store_test_gets, %{storage_key => {:ok, raw}})
    source
  end

  defp measure(source, item_count, cache, repetitions) do
    values =
      for _ <- 1..repetitions do
        if cache == :cold, do: clear_map_cache()
        item_ids = unique_ids(item_count)
        raw_envelope = item_ids |> envelope() |> Jason.encode!()

        {:error, {:sample, metrics}} =
          Repo.transaction(fn ->
            Process.put(:benchmark_queries, 0)
            Process.put(:benchmark_artifact_queries, 0)
            Process.put(:benchmark_db_time, 0)
            {:reductions, before_reductions} = Process.info(self(), :reductions)

            {elapsed, {:ok, summary}} =
              :timer.tc(fn ->
                {:ok, parsed, 0} = Ingest.parse(raw_envelope)
                Ingest.write_items(parsed, source, 0)
              end)

            {:reductions, after_reductions} = Process.info(self(), :reductions)

            metrics =
              {elapsed / 1_000, Process.get(:benchmark_queries),
               Process.get(:benchmark_artifact_queries), after_reductions - before_reductions,
               System.convert_time_unit(Process.get(:benchmark_db_time), :native, :microsecond) /
                 1_000}

            if summary.dropped != 0, do: raise("sample dropped items: #{inspect(summary)}")
            assert_persisted(item_ids, source)
            Repo.rollback({:sample, metrics})
          end)

        metrics
      end

    summarize(values)
  end

  defp warm_up(source) do
    clear_map_cache()
    measure(source, 1, :cold, 1)
    unless :ets.info(Symbolicator, :size) > 0, do: raise("warm-up did not decode the source map")
  end

  defp assert_persisted(item_ids, source) do
    %{rows: rows} =
      Repo.query!(
        "SELECT event_id, frames, causes, source_id, project_id FROM error_events WHERE event_id = ANY($1)",
        [item_ids]
      )

    if length(rows) != length(item_ids),
      do: raise("expected #{length(item_ids)} persisted rows, got #{length(rows)}")

    Enum.each(rows, fn [_event_id, frames, causes, source_id, project_id] ->
      if source_id != source.id or project_id != source.project_id,
        do: raise("persisted row escaped its source scope")

      if length(causes) != 2, do: raise("nested causes were not persisted")

      for stack <- [frames | Enum.map(causes, & &1["frames"])] do
        if length(stack) != @frame_count, do: raise("frame count changed")

        Enum.zip(stack, @original_lines)
        |> Enum.each(fn {frame, line} ->
          if frame["file"] != @source_name or frame["lineno"] != line or
               frame["context_line"] != "source line #{line}" do
            raise "frame was not remapped: #{inspect(frame)}"
          end
        end)
      end
    end)
  end

  defp envelope(item_ids) do
    %{
      header: %{key: nil, sdk: %{name: "benchmark", version: "1.0", platform: nil}, sent_at: nil},
      items: Enum.map(item_ids, &item/1)
    }
  end

  defp item(event_id) do
    %{
      id: event_id,
      type: "exception",
      timestamp: "2026-09-06T10:00:00.000000Z",
      level: "error",
      release: "benchmark-2026-09-06",
      environment: nil,
      message: nil,
      fingerprint: nil,
      breadcrumbs: nil,
      contexts: nil,
      tags: nil,
      user: nil,
      mechanism: nil,
      exception: %{type: "Error", value: "boom", stacktrace: %{frames: frames()}, cause: cause(1)}
    }
  end

  defp cause(depth) when depth <= 2,
    do: %{
      type: "Cause#{depth}",
      value: "wrapped",
      stacktrace: %{frames: frames()},
      cause: cause(depth + 1)
    }

  defp cause(_depth), do: nil

  defp frames do
    for index <- 0..(@frame_count - 1) do
      %{
        file: "https://cdn.example/app-012345.js",
        function: "fn#{index}",
        lineno: 1,
        colno: 1 + index * 4,
        in_app: false,
        pre_context: nil,
        context_line: nil,
        post_context: nil
      }
    end
  end

  defp source_map do
    lines = for line <- 1..@source_lines, do: "source line #{line}"
    original_lines = @original_lines

    mappings =
      original_lines
      |> Enum.with_index()
      |> Enum.map(fn {line, index} ->
        generated_delta = if index == 0, do: 0, else: 4

        original_delta =
          if index == 0, do: line - 1, else: line - Enum.at(original_lines, index - 1)

        if index == 0,
          do: "AAAA",
          else: vlq(generated_delta) <> vlq(0) <> vlq(original_delta) <> vlq(0)
      end)
      |> Enum.join(",")

    Jason.encode!(%{
      "version" => 3,
      "sources" => [@source_name],
      "names" => [],
      "mappings" => mappings,
      "sourcesContent" => [Enum.join(lines, "\n")]
    })
  end

  defp vlq(value) do
    value = if value < 0, do: -value * 2 + 1, else: value * 2
    encode_vlq(value, "")
  end

  defp encode_vlq(value, acc) do
    digit = Bitwise.band(value, 31)
    value = Bitwise.bsr(value, 5)
    digit = if value > 0, do: Bitwise.bor(digit, 32), else: digit
    char = Enum.at(~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", digit)
    if value > 0, do: encode_vlq(value, <<acc::binary, char>>), else: <<acc::binary, char>>
  end

  defp unique_ids(count) do
    for _ <- 1..count do
      suffix =
        System.unique_integer([:positive])
        |> rem(16 ** 12)
        |> Integer.to_string(16)
        |> String.downcase()
        |> String.pad_leading(12, "0")

      "err_0198f0a1-7c01-7000-8000-#{suffix}"
    end
  end

  defp clear_map_cache, do: :ets.delete_all_objects(Symbolicator)

  defp summarize(values) do
    times = Enum.map(values, &elem(&1, 0)) |> Enum.sort()
    query_counts = Enum.map(values, &elem(&1, 1))
    artifact_query_counts = Enum.map(values, &elem(&1, 2))

    %{
      median_ms: percentile(times, 0.5),
      p95_ms: percentile(times, 0.95),
      reductions: values |> Enum.map(&elem(&1, 3)) |> Enum.sort() |> percentile(0.5),
      db_ms: values |> Enum.map(&elem(&1, 4)) |> Enum.sort() |> percentile(0.5),
      queries: Enum.sum(query_counts) / length(values),
      artifact_queries: Enum.sum(artifact_query_counts) / length(values)
    }
  end

  defp percentile(values, fraction),
    do: Enum.at(values, max(ceil(length(values) * fraction) - 1, 0))

  defp print_report(samples) do
    IO.puts("Observe ingest benchmark, #{@repetitions} repetitions, all samples rolled back")

    for {{count, cache}, metrics} <- samples do
      IO.puts(
        "items=#{count} cache=#{cache} median_ms=#{Float.round(metrics.median_ms, 3)} p95_ms=#{Float.round(metrics.p95_ms, 3)} reductions=#{metrics.reductions} db_ms=#{Float.round(metrics.db_ms, 3)} avg_repo_queries=#{Float.round(metrics.queries, 1)} avg_artifact_index_queries=#{Float.round(metrics.artifact_queries, 1)}"
      )
    end
  end

  def handle_query([:alplus, :repo, :query], measurements, metadata, _config) do
    Process.put(:benchmark_queries, Process.get(:benchmark_queries, 0) + 1)

    Process.put(
      :benchmark_db_time,
      Process.get(:benchmark_db_time, 0) + (measurements[:query_time] || 0)
    )

    query = metadata[:query] || ""

    if String.contains?(query, "release_artifacts"),
      do:
        Process.put(:benchmark_artifact_queries, Process.get(:benchmark_artifact_queries, 0) + 1)
  end
end

unless Mix.env() == :test, do: raise("Run with MIX_ENV=test")
Mix.Task.run("app.config")
Logger.configure(level: :warning)
config = Application.fetch_env!(:alplus, Alplus.Repo)

unless config[:hostname] in ["127.0.0.1", "localhost"] and
         config[:pool] == Ecto.Adapters.SQL.Sandbox do
  raise "Use the local test database with the SQL sandbox"
end

{:ok, _} = Application.ensure_all_started(:alplus)

:telemetry.attach(
  {Alplus.ObserveIngestBenchmark, self()},
  [:alplus, :repo, :query],
  &Alplus.ObserveIngestBenchmark.handle_query/4,
  nil
)

Alplus.ObserveIngestBenchmark.run()
