defmodule AlplusWeb.MonitorMetricsComponentsTest do
  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Alplus.Monitoring.MonitorMetrics
  alias AlplusWeb.MonitorMetricsComponents

  @start ~U[2026-08-25 11:00:00Z]
  @range_end ~U[2026-08-25 12:00:00Z]

  defp metrics(overrides \\ []) do
    bucket = %{
      id: "latency-1",
      start_at: @start,
      end_at: @range_end,
      sample_count: 2,
      latency_count: 2,
      missing_latency_count: 0,
      min_latency_ms: 100,
      max_latency_ms: 700,
      p50_ms: 400,
      p95_ms: 670,
      p99_ms: 697,
      slow_count: 1,
      state: :slow,
      tone: "late",
      value: 400,
      height: 57,
      label: "Slow",
      tooltip: "11:00 UTC, 2 samples",
      aria_label: "11:00 UTC, 2 samples",
      table_cells: ["11:00 UTC", "12:00 UTC", "2", "400 ms", "670 ms", "Slow"]
    }

    struct!(
      MonitorMetrics,
      Keyword.merge(
        [
          monitor_id: "mon_test",
          org_id: "org_test",
          project_id: "project_test",
          window: "24h",
          range: %{
            start: DateTime.to_iso8601(@start),
            end: DateTime.to_iso8601(@range_end),
            bucket_seconds: 3_600
          },
          state: :ready,
          latency_state: :ready,
          threshold_ms: 500,
          threshold_source: :monitor_configuration,
          sample_count: 2,
          latency_count: 2,
          missing_latency_count: 0,
          missing_bucket_count: 0,
          min_latency_ms: 100,
          max_latency_ms: 700,
          percentiles: %{p50: 400, p95: 670, p99: 697},
          latency_buckets: [bucket],
          percentile_series: [
            %{
              start_at: @start,
              sample_count: 2,
              p50_ms: 400,
              p95_ms: 670,
              p99_ms: 697
            }
          ],
          percentile_paths: %{p50: "M0,10", p95: "M0,8", p99: "M0,7"},
          histogram: [
            %{
              id: "latency-histogram-under-50",
              key: :under_50,
              label: "0 to 49 ms",
              count: 1,
              value: 1,
              height: 100,
              tone: "live",
              tooltip: "0 to 49 ms, 1 samples",
              aria_label: "0 to 49 ms, 1 samples",
              table_cells: ["0 to 49 ms", "1"]
            }
          ],
          histogram_markers: [
            %{id: "latency-marker-p95", label: "p95", value: 670}
          ],
          response_composition: %{
            state: :ready,
            total: 2,
            items: [
              %{
                id: "response-composition-2xx",
                key: "2xx",
                label: "2xx responses",
                count: 2,
                value: 2,
                width: 100,
                tone: "live",
                tooltip: "2xx responses, 2 of 2 samples",
                aria_label: "2xx responses, 2 of 2 samples",
                table_cells: ["2xx responses", "2", "100.0%"]
              }
            ]
          },
          annotations: [%{id: "incident_1", label: "Incident, 2026-08-25"}],
          error: nil
        ],
        overrides
      )
    )
  end

  test "renders only the four useful latency readings" do
    html =
      render_component(&MonitorMetricsComponents.latency_analysis/1,
        metrics: metrics()
      )

    assert html =~ ~s(id="monitor-latency-summary")
    assert html =~ ~s(id="latency-sample-count")
    assert html =~ ~s(id="latency-p50-value")
    assert html =~ ~s(id="latency-p95-value")
    assert html =~ ~s(id="latency-p99-value")
    refute html =~ "latency-analysis-disclosure"
    refute html =~ "latency-histogram"
    refute html =~ "response-composition"
    refute html =~ "latency-range-stats"
    refute html =~ "latency-retention-notice"
  end

  test "renders one neutral empty latency state without zero readings" do
    html =
      render_component(&MonitorMetricsComponents.latency_analysis/1,
        metrics:
          metrics(
            state: :partial,
            latency_state: :missing,
            sample_count: 2,
            latency_count: 0,
            missing_latency_count: 2,
            percentiles: %{p50: nil, p95: nil, p99: nil}
          )
      )

    assert html =~ ~s(id="latency-empty-state")
    refute html =~ ~s(id="monitor-latency-summary")
    refute html =~ "0 ms"
  end

  test "renders a latency error with one retry control" do
    html =
      render_component(&MonitorMetricsComponents.latency_analysis/1,
        metrics: MonitorMetrics.error("Latency data unavailable", :database)
      )

    assert html =~ ~s(id="monitor-latency-error")
    assert html =~ ~s(id="monitor-latency-retry")
    refute html =~ ~s(id="monitor-latency-summary")
  end
end
