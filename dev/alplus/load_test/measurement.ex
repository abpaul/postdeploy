defmodule Alplus.LoadTest.Measurement do
  @moduledoc false

  @pending_table :alplus_loadtest_pending
  @drift_table :alplus_loadtest_drifts
  @telemetry_id "alplus-loadtest-scheduler-probe"

  def run(opts, options) do
    adapter = Keyword.fetch!(options, :adapter)
    base_url = Keyword.get(options, :base_url, "in-process")
    run_id = Integer.to_string(System.unique_integer([:positive]))
    scheduler_enabled = Application.fetch_env(:alplus, :monitor_scheduler_enabled?)

    Mix.shell().info("== alplus.loadtest ==")
    Mix.shell().info("target: #{base_url}")

    Mix.shell().info(
      "monitors=#{opts.monitors} heartbeats=#{opts.heartbeats} " <>
        "ingest_requests=#{opts.ingest_requests} ingest_concurrency=#{opts.ingest_concurrency} " <>
        "observe_seconds=#{opts.observe_seconds}"
    )

    Application.put_env(:alplus, :monitor_scheduler_enabled?, true)

    try do
      try do
        seeded = seed(opts, run_id, base_url)
        run_measurements(opts, seeded, adapter, base_url)
      after
        cleanup(run_id)
      end
    after
      restore_env(:alplus, :monitor_scheduler_enabled?, scheduler_enabled)
    end
  end

  @doc false
  def handle_telemetry(
        [:alplus, :monitoring, :check, :scheduled],
        %{scheduled_at: at, delay_ms: delay},
        %{monitor_id: id},
        monitor_ids
      ) do
    if MapSet.member?(monitor_ids, id) do
      :ets.insert(@pending_table, {id, at, delay})
    end
  end

  def handle_telemetry(
        [:alplus, :monitoring, :check, :fired],
        %{fired_at: fired_at},
        %{monitor_id: id},
        monitor_ids
      ) do
    if MapSet.member?(monitor_ids, id) do
      case :ets.take(@pending_table, id) do
        [{^id, scheduled_at, delay_ms}] ->
          expected_fire_at = scheduled_at + delay_ms
          :ets.insert(@drift_table, {id, fired_at - expected_fire_at})

        [] ->
          :ok
      end
    end
  end

  defp seed(opts, run_id, base_url) do
    Mix.shell().info("\n-- seed --")
    started_at = System.monotonic_time(:millisecond)

    user =
      Ash.create!(
        Alplus.Accounts.User,
        %{
          email: "loadtest-#{run_id}@example.com",
          password: "loadtest-supersecret1",
          password_confirmation: "loadtest-supersecret1",
          turnstile_token: "test-fixture-token"
        },
        action: :register_with_password,
        authorize?: false
      )

    user = Ash.update!(user, %{}, action: :mark_confirmed, authorize?: false)
    scope = Alplus.Scope.for_user(user.id)

    org =
      Ash.create!(
        Alplus.Orgs.Organization,
        %{name: "Loadtest #{run_id}", slug: "loadtest-#{run_id}"},
        action: :create,
        actor: scope
      )

    Alplus.Repo.query!(
      "UPDATE organizations SET plan_status = 'active', plan_id = 'postdeploy' WHERE id = $1",
      [org.id]
    )

    {:ok, owner_scope} = Alplus.Orgs.build_scope(scope, org.id)

    project =
      Ash.create!(
        Alplus.Projects.Project,
        %{org_id: org.id, name: "Loadtest project", slug: "loadtest-project"},
        action: :create,
        actor: owner_scope
      )

    project_scope = Alplus.Scope.put_project(owner_scope, project.id)
    health_url = base_url <> "/health"

    monitor_ids =
      1..opts.monitors
      |> Task.async_stream(
        fn number -> create_http_monitor(project_scope, org, project, health_url, number) end,
        max_concurrency: 20,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, id} -> id end)

    if opts.heartbeats < 1 do
      raise ArgumentError, "heartbeats must be at least one"
    end

    heartbeat_tokens =
      1..opts.heartbeats
      |> Task.async_stream(
        fn number -> create_heartbeat_monitor(project_scope, org, project, number) end,
        max_concurrency: 20,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    seed_ms = System.monotonic_time(:millisecond) - started_at

    Mix.shell().info(
      "seeded #{length(monitor_ids)} http monitors + #{length(heartbeat_tokens)} heartbeat monitors " <>
        "under one org/project in #{seed_ms} ms"
    )

    %{monitor_ids: monitor_ids, heartbeat_tokens: heartbeat_tokens, seed_ms: seed_ms}
  end

  defp create_http_monitor(scope, org, project, health_url, number) do
    monitor =
      Ash.create!(
        Alplus.Monitoring.Monitor,
        %{
          org_id: org.id,
          project_id: project.id,
          type: "http",
          name: "Loadtest HTTP #{number}"
        },
        action: :create,
        actor: scope
      )

    Ash.create!(
      Alplus.Monitoring.HttpConfig,
      %{
        monitor_id: monitor.id,
        org_id: org.id,
        url: health_url,
        method: "GET",
        expected_status: %{"kind" => "range", "min" => 200, "max" => 299},
        interval_seconds: 30,
        timeout_seconds: 5
      },
      action: :create,
      actor: scope
    )

    monitor.id
  end

  defp create_heartbeat_monitor(scope, org, project, number) do
    monitor =
      Ash.create!(
        Alplus.Monitoring.Monitor,
        %{
          org_id: org.id,
          project_id: project.id,
          type: "heartbeat",
          name: "Loadtest heartbeat #{number}"
        },
        action: :create,
        actor: scope
      )

    config =
      Ash.create!(
        Alplus.Monitoring.HeartbeatConfig,
        %{
          monitor_id: monitor.id,
          org_id: org.id,
          grace_period_seconds: 60,
          interval_seconds: 300,
          timezone: "UTC",
          track_duration: false
        },
        action: :issue,
        actor: scope
      )

    {monitor.id, Ash.Resource.get_metadata(config, :heartbeat_token)}
  end

  defp run_measurements(opts, seeded, adapter, base_url) do
    Mix.shell().info("\n-- scheduler rehydration --")
    :ets.new(@pending_table, [:set, :public, :named_table])
    :ets.new(@drift_table, [:bag, :public, :named_table])

    :telemetry.attach_many(
      @telemetry_id,
      [
        [:alplus, :monitoring, :check, :scheduled],
        [:alplus, :monitoring, :check, :fired]
      ],
      &__MODULE__.handle_telemetry/4,
      MapSet.new(seeded.monitor_ids)
    )

    started_at = System.monotonic_time(:millisecond)
    :ok = Alplus.Monitoring.Scheduler.rehydrate(seeded.monitor_ids)
    rehydrate_ms = System.monotonic_time(:millisecond) - started_at

    worker_count = count_seeded_workers(seeded.monitor_ids)
    memory = :erlang.memory()

    Mix.shell().info(
      "rehydration: #{rehydrate_ms} ms for #{length(seeded.monitor_ids)} active monitors"
    )

    Mix.shell().info("MonitorSupervisor seeded workers: #{worker_count}")

    Mix.shell().info(
      "BEAM memory: total=#{mb(memory[:total])} MB processes=#{mb(memory[:processes])} MB"
    )

    Mix.shell().info("\n-- scheduler drift (observing #{opts.observe_seconds}s) --")

    if opts.observe_seconds > 0 do
      Process.sleep(opts.observe_seconds * 1_000)
    end

    :telemetry.detach(@telemetry_id)

    drifts =
      @drift_table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, drift} -> drift end)

    drift_stats = stats(drifts)

    Mix.shell().info(
      "drift samples=#{length(drifts)} mean=#{fmt(drift_stats.mean)}ms " <>
        "p50=#{drift_stats.p50}ms p95=#{drift_stats.p95}ms p99=#{drift_stats.p99}ms " <>
        "max=#{drift_stats.max}ms"
    )

    stop_monitor_workers(seeded.monitor_ids)
    Mix.shell().info("\n-- ingest load: GET /h/:token --")
    ingest_stats = run_ingest_load(opts, seeded, adapter, base_url)

    Mix.shell().info(
      "requests=#{ingest_stats.n} ok=#{ingest_stats.ok} errors=#{ingest_stats.errors} " <>
        "duration=#{fmt(ingest_stats.duration_s)}s throughput=#{fmt(ingest_stats.rps)} req/s"
    )

    Mix.shell().info(
      "latency (ms) p50=#{ingest_stats.p50} p95=#{ingest_stats.p95} " <>
        "p99=#{ingest_stats.p99} max=#{ingest_stats.max}"
    )

    result = %{
      seed_ms: seeded.seed_ms,
      rehydrate_ms: rehydrate_ms,
      process_count: worker_count,
      memory_total_mb: mb(memory[:total]),
      drift: Map.put(drift_stats, :samples, length(drifts)),
      ingest: ingest_stats
    }

    print_summary(result)
    result
  end

  defp run_ingest_load(opts, %{heartbeat_tokens: [{_id, token} | _]}, adapter, base_url) do
    Mix.shell().info("warming up (5 sequential requests)...")
    for _ <- 1..5, do: request(adapter, base_url, token)

    started_at = System.monotonic_time(:millisecond)

    results =
      1..opts.ingest_requests
      |> Task.async_stream(
        fn _ -> timed_request(adapter, base_url, token) end,
        max_concurrency: opts.ingest_concurrency,
        timeout: 20_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {{:error, reason}, nil}
      end)

    duration_ms = System.monotonic_time(:millisecond) - started_at

    {ok, errors} =
      Enum.split_with(results, fn
        {{:ok, status}, _latency} -> status in 200..299
        _other -> false
      end)

    latencies =
      results
      |> Enum.map(fn {_result, latency} -> latency end)
      |> Enum.reject(&is_nil/1)

    latency_stats = stats(latencies)

    %{
      n: length(results),
      ok: length(ok),
      errors: length(errors),
      duration_s: duration_ms / 1000,
      rps: length(results) / (max(duration_ms, 1) / 1000),
      p50: latency_stats.p50,
      p95: latency_stats.p95,
      p99: latency_stats.p99,
      max: latency_stats.max
    }
  end

  defp run_ingest_load(_opts, %{heartbeat_tokens: []}, _adapter, _base_url) do
    raise "no heartbeat monitors seeded; set --heartbeats to at least one"
  end

  defp timed_request(adapter, base_url, token) do
    started_at = System.monotonic_time(:millisecond)
    result = request(adapter, base_url, token)
    {result, System.monotonic_time(:millisecond) - started_at}
  end

  defp request(adapter, base_url, token) when is_atom(adapter),
    do: normalize_result(adapter.request(base_url, token))

  defp request(adapter, base_url, token) when is_function(adapter, 2),
    do: normalize_result(adapter.(base_url, token))

  defp normalize_result({:ok, status}) when is_integer(status), do: {:ok, status}
  defp normalize_result({:error, reason}), do: {:error, reason}

  defp normalize_result(other) do
    raise ArgumentError, "load adapter returned an invalid result: #{inspect(other)}"
  end

  defp count_seeded_workers(monitor_ids) do
    Enum.count(monitor_ids, fn monitor_id ->
      Registry.lookup(Alplus.Monitoring.Registry, monitor_id) != []
    end)
  end

  defp cleanup(run_id) do
    Mix.shell().info("\n-- cleanup --")
    :telemetry.detach(@telemetry_id)

    try do
      monitor_ids =
        Alplus.Repo.query!(
          "SELECT monitors.id FROM monitors JOIN organizations ON organizations.id = monitors.org_id " <>
            "WHERE organizations.slug = $1",
          ["loadtest-#{run_id}"]
        ).rows
        |> Enum.map(fn [id] -> id end)

      stop_monitor_workers(monitor_ids)
    after
      try do
        Alplus.Repo.transaction(fn ->
          Alplus.Repo.query!("DELETE FROM organizations WHERE slug = $1", ["loadtest-#{run_id}"])

          Alplus.Repo.query!("DELETE FROM users WHERE email = $1", [
            "loadtest-#{run_id}@example.com"
          ])
        end)
      after
        delete_table(@pending_table)
        delete_table(@drift_table)
      end
    end

    Mix.shell().info("deleted loadtest-#{run_id} rows")
  end

  defp stop_monitor_workers(monitor_ids) do
    Enum.each(monitor_ids, &Alplus.Monitoring.Scheduler.stop_monitor/1)
  end

  defp delete_table(table) do
    if :ets.whereis(table) != :undefined, do: :ets.delete(table)
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)

  defp print_summary(result) do
    Mix.shell().info("\n== summary ==")

    Mix.shell().info("""
    seed_ms=#{result.seed_ms}
    rehydrate_ms=#{result.rehydrate_ms}
    process_count=#{result.process_count}
    memory_total_mb=#{result.memory_total_mb}
    drift_mean_ms=#{fmt(result.drift.mean)}
    drift_p95_ms=#{result.drift.p95}
    ingest_rps=#{fmt(result.ingest.rps)}
    ingest_p50_ms=#{result.ingest.p50}
    ingest_p95_ms=#{result.ingest.p95}
    ingest_p99_ms=#{result.ingest.p99}
    """)
  end

  defp stats([]), do: %{mean: 0.0, p50: 0, p95: 0, p99: 0, max: 0}

  defp stats(values) do
    sorted = Enum.sort(values)
    count = length(sorted)

    %{
      mean: Enum.sum(sorted) / count,
      p50: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95),
      p99: percentile(sorted, 0.99),
      max: List.last(sorted)
    }
  end

  defp percentile(sorted, percentile) do
    count = length(sorted)
    index = max(0, min(count - 1, ceil(percentile * count) - 1))
    Enum.at(sorted, index)
  end

  defp mb(bytes) when is_integer(bytes), do: fmt(bytes / 1_048_576)
  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
end
