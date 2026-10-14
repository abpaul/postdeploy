defmodule AlplusWeb.MonitorActivityComponentsTest do
  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Alplus.Monitoring.Monitor
  alias Alplus.Monitoring.MonitorOverview
  alias AlplusWeb.MonitorActivityComponents

  @project %{public_token: "proj_public"}

  test "renders filter bar with optional fields" do
    html =
      render_component(&MonitorActivityComponents.filter_bar/1,
        org_token: "org_tok",
        project: @project,
        environments: ["production"],
        environment: "production",
        window: "24h",
        query: "api",
        status: "down",
        type: "http",
        focus: "mon_1",
        view: "attention"
      )

    assert html =~ "monitor-filters"
  end

  test "public label helpers" do
    assert MonitorActivityComponents.row_label(%Monitor{status: "paused"}) == "Paused"

    assert MonitorActivityComponents.row_label(%Monitor{
             status: "active",
             last_known_status: "up"
           }) == "Up"

    assert MonitorActivityComponents.row_label(%Monitor{
             status: "active",
             last_known_status: "down"
           }) == "Down"

    assert MonitorActivityComponents.row_label(%Monitor{
             status: "active",
             last_known_status: "degraded"
           }) == "Degraded"

    assert MonitorActivityComponents.row_label(%Monitor{status: "active", last_known_status: nil}) ==
             "Unknown"

    assert MonitorActivityComponents.monitor_identity(%Monitor{type: "http"}) =~ "HTTP"
    assert MonitorActivityComponents.monitor_identity(%Monitor{type: "keyword"}) =~ "keyword"
    assert MonitorActivityComponents.monitor_identity(%Monitor{type: "heartbeat"}) =~ "Heartbeat"
    assert MonitorActivityComponents.monitor_identity(%Monitor{type: "tcp"}) =~ "TCP"
    assert MonitorActivityComponents.monitor_identity(%Monitor{type: "dns"}) =~ "DNS"

    assert MonitorActivityComponents.target_label(%MonitorOverview.Row{target: nil}) =~
             "unavailable"

    assert MonitorActivityComponents.target_label(%MonitorOverview.Row{target: "https://x"}) ==
             "https://x"

    assert MonitorActivityComponents.duration_words(90_000) =~ "d"
    assert MonitorActivityComponents.duration_words(3700) =~ "h"
    assert MonitorActivityComponents.duration_words(90) =~ "m"
    assert MonitorActivityComponents.duration_words(5) == "5s"

    assert MonitorActivityComponents.incident_duration_label(%{
             resolved_at: nil,
             started_at: DateTime.add(DateTime.utc_now(), -60, :second)
           }) =~ "ongoing"

    assert MonitorActivityComponents.incident_duration_label(%{
             resolved_at: DateTime.utc_now(),
             duration_seconds: 30
           }) =~ "lasted"
  end

  test "renders response time and uptime timeline" do
    monitor = %Monitor{
      id: "mon_cov",
      name: "Cov",
      type: "http",
      status: "active",
      last_known_status: "up"
    }

    row = %MonitorOverview.Row{
      monitor: monitor,
      config: nil,
      target: "https://example.test",
      interval_seconds: 60,
      latest_check: nil
    }

    now = DateTime.utc_now()

    activity = %{
      check_count: 0,
      checks: [],
      window_start: DateTime.add(now, -3600, :second),
      window_end: now,
      evidence_start: nil
    }

    html =
      render_component(&MonitorActivityComponents.response_time_panel/1,
        row: row,
        activity: activity,
        window: "24h"
      )

    assert html =~ ~s(data-display-state="empty")

    heartbeat = %{row | monitor: %{monitor | type: "heartbeat", status: "paused"}}

    html =
      render_component(&MonitorActivityComponents.monitor_row/1,
        row: heartbeat,
        activity: %{
          activity
          | check_count: 1,
            checks: [%{checked_at: now, status: "up", latency_ms: 12, status_code: 200}]
        },
        org_token: "org_tok",
        project: @project,
        window: "24h"
      )

    # One visual per row: the uptime timeline, and nothing about latency.
    assert html =~ "uptime-timeline-mon_cov"
    assert html =~ ~s(data-display-kind="ticks")
    assert length(Regex.scan(~r/data-display-kind=/, html)) == 1
    assert html =~ "Heartbeat monitor, every 1m, no check yet"
    refute html =~ "response-time-chart"
    refute html =~ "alert "

    full_html =
      render_component(&MonitorActivityComponents.response_time_panel/1,
        row: heartbeat,
        activity: %{
          activity
          | check_count: 1,
            checks: [%{checked_at: now, status: "up", latency_ms: 12, status_code: 200}]
        },
        window: "24h"
      )

    assert full_html =~ ~s(id="response-time-chart-mon_cov-table" class="sr-only hidden sm:block")
    # From `sm` up the table is assistive only; below `sm` it is a visible
    # disclosure, the dependable narrow-screen path.
    assert full_html =~ ~s(id="response-time-chart-mon_cov-table-narrow")

    down = %{row | monitor: %{monitor | last_known_status: "down"}}
    keyword = %{row | monitor: %{monitor | type: "keyword"}}
    tcp = %{row | monitor: %{monitor | type: "tcp"}}
    dns = %{row | monitor: %{monitor | type: "dns"}}

    assert MonitorActivityComponents.row_label(down.monitor) == "Down"
    assert MonitorActivityComponents.monitor_identity(keyword.monitor) =~ "keyword"
    assert MonitorActivityComponents.monitor_identity(tcp.monitor) =~ "TCP"
    assert MonitorActivityComponents.monitor_identity(dns.monitor) =~ "DNS"

    day = Date.utc_today()

    activity_30d = %{
      check_count: 2,
      checks: [
        %{checked_at: now, status: "down", latency_ms: 9, status_code: 500},
        %{
          checked_at: DateTime.add(now, -60, :second),
          status: "degraded",
          latency_ms: 40,
          status_code: 200
        }
      ],
      window_start: DateTime.add(now, -30 * 86_400, :second),
      window_end: now,
      evidence_start: DateTime.add(now, -30 * 86_400, :second),
      rollups: [
        %{day: day, monitored_microseconds: 0, uptime_ratio: nil},
        %{day: Date.add(day, -1), monitored_microseconds: 1, uptime_ratio: 1.0},
        %{day: Date.add(day, -2), monitored_microseconds: 1, uptime_ratio: 0.0},
        %{day: Date.add(day, -3), monitored_microseconds: 1, uptime_ratio: 0.5}
      ],
      pauses: [
        %{
          paused_at: DateTime.add(now, -120, :second),
          resumed_at: DateTime.add(now, -90, :second)
        }
      ],
      incidents: [%{started_at: DateTime.add(now, -80, :second), resolved_at: nil}],
      incident_count: 1
    }

    html =
      render_component(&MonitorActivityComponents.response_time_panel/1,
        row: keyword,
        activity: activity_30d,
        window: "30d"
      )

    assert html =~ "h-30 lg:h-40"
  end

  test "shared monitor timeline renders exact bucket evidence in plain language" do
    start_at = ~U[2026-02-12 14:00:00Z]

    buckets =
      for index <- 0..23 do
        state = if(index == 23, do: :down, else: :up)

        %{
          start_at: DateTime.add(start_at, index * 3_600, :second),
          end_at: DateTime.add(start_at, (index + 1) * 3_600, :second),
          state: state,
          tone: if(state == :down, do: "error", else: "live"),
          check_count: 1,
          missing_interval_count: 0
        }
      end

    html =
      render_component(&MonitorActivityComponents.monitor_timeline/1,
        id: "shared-monitor-timeline",
        buckets: buckets,
        range: "24h",
        scope: :monitor
      )

    assert html =~ "shared-monitor-timeline"
    assert html =~ "Down"
    assert html =~ "1 check"
    refute html =~ "interval_seconds"
    assert length(Regex.scan(~r/data-display-point="true"/, html)) == 24
    refute html =~ ~s(aria-label="Legend")
    refute html =~ "View data table"
  end
end
