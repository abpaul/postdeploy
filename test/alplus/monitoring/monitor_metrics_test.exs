defmodule Alplus.Monitoring.MonitorMetricsTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.{HttpConfig, Monitor, MonitorCheck, MonitorMetrics}

  @now ~U[2026-08-25 12:00:00.000000Z]

  defp project_scope(scope, project), do: Alplus.Scope.put_project(scope, project.id)

  defp http_monitor_fixture(scope, org, project, threshold) do
    actor = project_scope(scope, project)

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "Latency"},
        action: :create,
        actor: actor
      )

    config =
      Ash.create!(
        HttpConfig,
        %{
          monitor_id: monitor.id,
          org_id: org.id,
          url: "https://example.test/health",
          method: "GET",
          expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
          interval_seconds: 300,
          timeout_seconds: 10,
          response_time_threshold_ms: threshold
        },
        action: :create,
        actor: actor
      )

    {monitor, config, actor}
  end

  defp check_fixture(org, project, monitor, attrs) do
    Ash.create!(
      MonitorCheck,
      Map.merge(
        %{org_id: org.id, project_id: project.id, monitor_id: monitor.id, status: "up"},
        attrs
      ),
      action: :record,
      authorize?: false
    )
  end

  test "continuous percentiles match deterministic fixture math" do
    assert_in_delta MonitorMetrics.percentile([10, 20, 30, 40, 50], 0.50), 30.0, 0.001
    assert_in_delta MonitorMetrics.percentile([10, 20, 30, 40, 50], 0.95), 48.0, 0.001
    assert_in_delta MonitorMetrics.percentile([10, 20, 30, 40, 50], 0.99), 49.6, 0.001

    assert MonitorMetrics.percentiles([]) == %{p50: nil, p95: nil, p99: nil}
  end

  test "histogram bins retain zero bins and reconcile to latency samples" do
    histogram = MonitorMetrics.histogram_counts([10, 60, 120, 400, 900, 2_600, 9_000, 20_000])

    assert length(histogram) == length(MonitorMetrics.histogram_bins())
    assert Enum.sum(Enum.map(histogram, & &1.count)) == 8
    assert Enum.find(histogram, &(&1.key == :over_10000)).count == 1
    assert Enum.any?(histogram, &(&1.count == 0 and is_nil(&1.value)))
  end

  test "metrics use all scoped samples, expose slow buckets, and reconcile charts" do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    {monitor, config, project_scope} = http_monitor_fixture(scope, org, project, 500)

    latency_values = [10, 20, 30, 40, 50, 600, 700, 20_000]

    Enum.each(Enum.with_index(latency_values), fn {latency, index} ->
      check_fixture(org, project, monitor, %{
        checked_at: DateTime.add(@now, -(index + 1) * 60, :second),
        status_code: if(latency == 20_000, do: 503, else: 200),
        latency_ms: latency,
        status: if(latency == 20_000, do: "down", else: "up")
      })
    end)

    check_fixture(org, project, monitor, %{
      checked_at: DateTime.add(@now, -1_200, :second),
      status: "down",
      error_class: "timeout",
      latency_ms: nil
    })

    check_fixture(org, project, monitor, %{
      checked_at: DateTime.add(@now, -1_260, :second),
      status: "down",
      error_class: "network_error",
      latency_ms: nil
    })

    assert {:ok, metrics} =
             MonitorMetrics.load(monitor, config, project_scope, "24h",
               now: @now,
               retention_days: 30
             )

    assert metrics.sample_count == 10
    assert metrics.latency_count == 8
    assert metrics.missing_latency_count == 2
    assert_in_delta metrics.percentiles.p50, 45.0, 0.001
    assert_in_delta metrics.percentiles.p95, 13_245.0, 0.001
    assert_in_delta metrics.percentiles.p99, 18_649.0, 0.001
    assert metrics.threshold_ms == 500
    assert metrics.threshold_source == :monitor_configuration
    assert Enum.any?(metrics.latency_buckets, &(&1.state == :slow))
    assert Enum.any?(metrics.histogram, &(&1.key == :over_10000 and &1.count == 1))
    assert Enum.sum(Enum.map(metrics.histogram, & &1.count)) == metrics.latency_count

    composition = metrics.response_composition
    assert Enum.sum(Enum.map(composition.items, & &1.count)) == composition.total
    assert composition.total == metrics.sample_count
    assert Enum.find(composition.items, &(&1.key == "timeout")).count == 1
    assert Enum.find(composition.items, &(&1.key == "transport")).count == 1
    assert metrics.range.truncated? == false
  end

  test "requested ranges stop at the plan retention boundary" do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    {monitor, config, project_scope} = http_monitor_fixture(scope, org, project, nil)

    check_fixture(org, project, monitor, %{
      checked_at: DateTime.add(@now, -8 * 86_400, :second),
      latency_ms: 99,
      status_code: 200
    })

    check_fixture(org, project, monitor, %{
      checked_at: DateTime.add(@now, -2 * 86_400, :second),
      latency_ms: 101,
      status_code: 200
    })

    assert {:ok, metrics} =
             MonitorMetrics.load(monitor, config, project_scope, "30d",
               now: @now,
               retention_days: 7
             )

    assert metrics.sample_count == 1
    assert metrics.min_latency_ms == 101
    assert metrics.range.truncated?
    assert metrics.range.retention_days == 7
  end

  test "an absent response threshold does not mark latency buckets slow" do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    {monitor, config, project_scope} = http_monitor_fixture(scope, org, project, nil)

    check_fixture(org, project, monitor, %{
      checked_at: DateTime.add(@now, -60, :second),
      latency_ms: 20,
      status_code: 200
    })

    assert {:ok, metrics} =
             MonitorMetrics.load(monitor, config, project_scope, "24h",
               now: @now,
               retention_days: 30
             )

    assert metrics.threshold_ms == nil
    assert Enum.all?(metrics.latency_buckets, &(&1.state != :slow))
    assert Enum.all?(metrics.latency_buckets, &(&1.slow_count == 0))
  end

  test "a scope from another tenant cannot read the monitor metrics" do
    owner_a = user_fixture()
    {org_a, scope_a} = org_fixture(Alplus.Scope.for_user(owner_a.id))
    project_a = project_fixture(scope_a, org_a)
    {monitor, config, _scope_a} = http_monitor_fixture(scope_a, org_a, project_a, 500)

    owner_b = user_fixture()
    {org_b, scope_b} = org_fixture(Alplus.Scope.for_user(owner_b.id))
    project_b = project_fixture(scope_b, org_b)
    scope_b = project_scope(scope_b, project_b)

    assert {:error, :not_found} =
             MonitorMetrics.load(monitor, config, scope_b, "24h",
               now: @now,
               retention_days: 30
             )
  end
end
