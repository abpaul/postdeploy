defmodule Mix.Tasks.Alplus.LoadtestTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.{HttpConfig, Monitor, Scheduler}
  alias Alplus.Scope

  test "runs repeated in-process measurements without a listener or leaked rows" do
    endpoint_config = Application.fetch_env(:alplus, AlplusWeb.Endpoint)
    serve_endpoints = Application.fetch_env(:phoenix, :serve_endpoints)

    first = run_measurement()
    assert %{n: 1, ok: 1, errors: 0} = first.ingest
    assert first.process_count > 0
    assert_scheduler_setting(false)
    assert_no_seeded_rows()

    second = run_measurement()
    assert %{n: 1, ok: 1, errors: 0} = second.ingest
    assert second.process_count == first.process_count
    assert Map.keys(first) == Map.keys(second)
    assert Map.keys(first.ingest) == Map.keys(second.ingest)
    assert_scheduler_setting(false)
    assert_no_seeded_rows()

    assert Application.fetch_env(:alplus, AlplusWeb.Endpoint) == endpoint_config
    assert Application.fetch_env(:phoenix, :serve_endpoints) == serve_endpoints
  end

  test "removes seeded rows when the request adapter raises" do
    adapter = fn _base_url, _token -> raise "forced measurement failure" end

    assert_raise RuntimeError, "forced measurement failure", fn ->
      Alplus.LoadTest.Measurement.run(measurement_options(),
        adapter: adapter,
        base_url: "in-process"
      )
    end

    assert_no_seeded_rows()
    assert_scheduler_setting(false)

    assert %{rows: [[0]]} =
             Alplus.Repo.query!("""
             SELECT count(*)
             FROM projects AS p
             JOIN organizations AS o ON o.id = p.org_id
             WHERE o.slug LIKE 'loadtest-%'
             """)
  end

  test "removes every row created before a partial seed failure" do
    assert_raise ArgumentError, "heartbeats must be at least one", fn ->
      Alplus.LoadTest.Measurement.run(
        %{measurement_options() | heartbeats: 0},
        adapter: Alplus.LoadTest.Adapter.InProcess,
        base_url: "in-process"
      )
    end

    assert_scheduler_setting(false)
    assert_no_seeded_rows()

    assert %{rows: [[0]]} =
             Alplus.Repo.query!("""
             SELECT count(*)
             FROM projects AS p
             JOIN organizations AS o ON o.id = p.org_id
             WHERE o.slug LIKE 'loadtest-%'
             """)

    assert %{rows: [[0]]} =
             Alplus.Repo.query!("""
             SELECT count(*)
             FROM memberships AS m
             JOIN organizations AS o ON o.id = m.org_id
             WHERE o.slug LIKE 'loadtest-%'
             """)

    assert %{rows: [[0]]} =
             Alplus.Repo.query!("""
             SELECT count(*)
             FROM monitors AS m
             JOIN organizations AS o ON o.id = m.org_id
             WHERE o.slug LIKE 'loadtest-%'
             """)

    assert %{rows: [[0]]} =
             Alplus.Repo.query!("""
             SELECT count(*)
             FROM monitor_http_configs AS c
             JOIN organizations AS o ON o.id = c.org_id
             WHERE o.slug LIKE 'loadtest-%'
             """)

    assert %{rows: [[0]]} =
             Alplus.Repo.query!("""
             SELECT count(*)
             FROM monitor_heartbeat_configs AS c
             JOIN organizations AS o ON o.id = c.org_id
             WHERE o.slug LIKE 'loadtest-%'
             """)
  end

  test "preserves monitor workers that existed before the measurement" do
    previous = Application.get_env(:alplus, :monitor_scheduler_enabled?, true)
    Application.put_env(:alplus, :monitor_scheduler_enabled?, true)

    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    scope = Scope.put_project(scope, project.id)

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "Baseline"},
        action: :create,
        actor: scope
      )

    Ash.create!(
      HttpConfig,
      %{
        monitor_id: monitor.id,
        org_id: org.id,
        url: "https://example.test/health",
        method: "GET",
        expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
        interval_seconds: 300,
        timeout_seconds: 10
      },
      action: :create,
      actor: scope
    )

    on_exit(fn ->
      Scheduler.stop_monitor(monitor.id)
      Application.put_env(:alplus, :monitor_scheduler_enabled?, previous)
    end)

    assert {:ok, _pid} = Scheduler.reconcile_monitor(monitor.id)
    assert [{baseline_pid, _}] = Registry.lookup(Alplus.Monitoring.Registry, monitor.id)

    result = run_measurement()

    assert %{n: 1, ok: 1, errors: 0} = result.ingest
    assert [{^baseline_pid, _}] = Registry.lookup(Alplus.Monitoring.Registry, monitor.id)
  end

  test "does not start a pre-existing active monitor without a worker" do
    previous = Application.get_env(:alplus, :monitor_scheduler_enabled?, true)
    Application.put_env(:alplus, :monitor_scheduler_enabled?, false)

    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    scope = Scope.put_project(scope, project.id)

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "Unregistered"},
        action: :create,
        actor: scope
      )

    Ash.create!(
      HttpConfig,
      %{
        monitor_id: monitor.id,
        org_id: org.id,
        url: "https://example.test/health",
        method: "GET",
        expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
        interval_seconds: 300,
        timeout_seconds: 10
      },
      action: :create,
      actor: scope
    )

    on_exit(fn -> Application.put_env(:alplus, :monitor_scheduler_enabled?, previous) end)

    assert [] = Registry.lookup(Alplus.Monitoring.Registry, monitor.id)
    result = run_measurement()

    assert %{n: 1, ok: 1, errors: 0} = result.ingest
    assert [] = Registry.lookup(Alplus.Monitoring.Registry, monitor.id)
  end

  test "rejects runtime reuse without changing runtime configuration" do
    endpoint_config = Application.fetch_env(:alplus, AlplusWeb.Endpoint)
    serve_endpoints = Application.fetch_env(:phoenix, :serve_endpoints)
    log_level = Logger.level()

    boot_rehydrate_enabled =
      Application.fetch_env(:alplus, :monitor_scheduler_boot_rehydrate_enabled?)

    reconcile_interval = Application.fetch_env(:alplus, :monitor_reconcile_interval_ms)

    assert_raise Mix.Error, ~r/must run in a fresh Mix process/, fn ->
      Alplus.LoadTest.Runtime.run(fn _base_url -> flunk("runtime callback must not run") end)
    end

    assert Application.fetch_env(:alplus, AlplusWeb.Endpoint) == endpoint_config
    assert Application.fetch_env(:phoenix, :serve_endpoints) == serve_endpoints
    assert Logger.level() == log_level

    assert Application.fetch_env(:alplus, :monitor_scheduler_boot_rehydrate_enabled?) ==
             boot_rehydrate_enabled

    assert Application.fetch_env(:alplus, :monitor_reconcile_interval_ms) == reconcile_interval
  end

  defp run_measurement do
    Alplus.LoadTest.Measurement.run(measurement_options(),
      adapter: Alplus.LoadTest.Adapter.InProcess,
      base_url: "in-process"
    )
  end

  defp measurement_options do
    %{
      monitors: 1,
      heartbeats: 1,
      ingest_requests: 1,
      ingest_concurrency: 1,
      observe_seconds: 0
    }
  end

  defp assert_no_seeded_rows do
    assert %{rows: [[0]]} =
             Alplus.Repo.query!("SELECT count(*) FROM organizations WHERE slug LIKE 'loadtest-%'")

    assert %{rows: [[0]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM users WHERE email LIKE 'loadtest-%@example.com'"
             )
  end

  defp assert_scheduler_setting(value) do
    assert Application.fetch_env(:alplus, :monitor_scheduler_enabled?) == {:ok, value}
  end
end
