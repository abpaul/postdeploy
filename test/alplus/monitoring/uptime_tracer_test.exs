defmodule Alplus.Monitoring.UptimeTracerTest do
  use ExUnit.Case, async: true

  alias Alplus.Monitoring.UptimeTracer

  @start ~U[2026-01-01 00:00:00Z]

  defp check(at, status, attrs \\ %{}) do
    Map.merge(%{checked_at: at, status: status}, Map.new(attrs))
  end

  test "aligns buckets to the monitor interval instead of dividing the window" do
    trace =
      UptimeTracer.trace(
        [check(~U[2026-01-01 00:02:10Z], "up")],
        ~U[2026-01-01 00:01:30Z],
        ~U[2026-01-01 00:03:30Z],
        60
      )

    assert Enum.map(trace.buckets, & &1.start_at) == [
             ~U[2026-01-01 00:01:00Z],
             ~U[2026-01-01 00:02:00Z],
             ~U[2026-01-01 00:03:00Z]
           ]

    assert Enum.map(trace.buckets, & &1.state) == [:missing, :up, :missing]
    assert trace.state == :partial
    assert trace.range.aligned_start == "2026-01-01 00:01 UTC"
  end

  test "returns an explicit empty state when the range has no evidence" do
    trace = UptimeTracer.trace([], @start, DateTime.add(@start, 180, :second), 60)

    assert trace.state == :empty
    assert trace.buckets == []
    assert trace.table_rows == []
    assert trace.summary == "No uptime evidence yet"
  end

  test "keeps a missing interval separate from a down interval" do
    trace =
      UptimeTracer.trace(
        [
          check(~U[2026-01-01 00:00:10Z], "up"),
          check(~U[2026-01-01 00:02:10Z], "down")
        ],
        @start,
        DateTime.add(@start, 180, :second),
        60
      )

    assert Enum.map(trace.buckets, & &1.state) == [:up, :missing, :down]
    assert trace.counts[:missing] == 1
    assert trace.counts[:down] == 1
  end

  test "keeps dense checks in one bucket without inventing samples" do
    trace =
      UptimeTracer.trace(
        [
          check(~U[2026-01-01 00:00:05Z], "up"),
          check(~U[2026-01-01 00:00:20Z], "up"),
          check(~U[2026-01-01 00:00:40Z], "up")
        ],
        @start,
        DateTime.add(@start, 120, :second),
        60
      )

    assert length(trace.buckets) == 2
    assert hd(trace.buckets).state == :up
    assert hd(trace.buckets).check_count == 3
    assert Enum.at(trace.buckets, 1).state == :missing
  end

  test "keeps complete evidence older than the former 120 sample cap" do
    checks =
      for index <- 0..120 do
        check(DateTime.add(@start, index * 60, :second), "up")
      end

    trace = UptimeTracer.trace(checks, @start, DateTime.add(@start, 121 * 60, :second), 60)

    assert length(trace.buckets) == 121
    assert Enum.all?(trace.buckets, &(&1.state == :up))
    assert Enum.at(trace.buckets, 120).check_count == 1
    assert trace.counts[:missing] in [nil, 0]
  end

  test "coarsened evidence reports effective width and missing base intervals" do
    trace =
      UptimeTracer.trace(
        [],
        @start,
        DateTime.add(@start, 300, :second),
        300,
        base_interval_seconds: 60,
        bucket_evidence: [
          %{
            start_at: @start,
            state: :partial,
            check_count: 2,
            base_interval_seconds: 60,
            interval_seconds: 300,
            expected_interval_count: 5,
            covered_interval_count: 2,
            missing_interval_count: 3,
            state_counts: %{up: 2, down: 0, slow: 0, anomaly: 0}
          }
        ]
      )

    [bucket] = trace.buckets
    [row] = trace.table_rows

    assert bucket.state == :partial
    assert bucket.partial?
    assert bucket.interval_seconds == 300
    assert bucket.base_interval_seconds == 60
    assert bucket.check_count == 2
    assert bucket.missing_interval_count == 3
    assert trace.coverage_ratio == 2 / 5
    assert Enum.at(row.cells, 4) == "5 minutes"
    assert Enum.at(row.cells, 5) == "2 of 5 monitor intervals covered"
    assert Enum.at(row.cells, 6) == "3"
    assert bucket.aria_label =~ "3 missing"
  end

  test "coarsening keeps the effective width on the monitor interval grid" do
    window_end = DateTime.add(@start, 90 * 86_400, :second)
    display_interval = UptimeTracer.display_interval_seconds(@start, window_end, 60)

    assert display_interval == 5_400
    assert rem(display_interval, 60) == 0

    trace =
      UptimeTracer.trace(
        [],
        @start,
        window_end,
        display_interval,
        base_interval_seconds: 60,
        bucket_evidence: [
          %{
            start_at: @start,
            state: :up,
            check_count: 90,
            base_interval_seconds: 60,
            interval_seconds: display_interval,
            expected_interval_count: 90,
            covered_interval_count: 90,
            missing_interval_count: 0,
            state_counts: %{up: 90, down: 0, slow: 0, anomaly: 0}
          }
        ]
      )

    assert length(trace.buckets) == 1_440
    assert hd(trace.buckets).interval_seconds == display_interval
    assert hd(trace.buckets).check_count == 90
  end

  test "offset 24-hour ranges stay within the 1,440 bucket bound" do
    window_start = DateTime.add(@start, 1, :second)
    window_end = DateTime.add(window_start, 86_400, :second)
    display_interval = UptimeTracer.display_interval_seconds(window_start, window_end, 60)

    trace = UptimeTracer.trace([], window_start, window_end, 60)

    assert display_interval == 120
    assert trace.interval_seconds == display_interval
    assert length(trace.buckets) <= 1_440
  end

  test "marks slow and anomalous evidence explicitly" do
    trace =
      UptimeTracer.trace(
        [
          check(~U[2026-01-01 00:00:05Z], "degraded"),
          check(~U[2026-01-01 00:01:05Z], "up", detail: %{"anomaly" => true})
        ],
        @start,
        DateTime.add(@start, 120, :second),
        60
      )

    assert Enum.map(trace.buckets, & &1.state) == [:slow, :anomaly]
    assert trace.state == :anomaly
  end

  test "an open incident over a bucket with no checks is no data, not downtime" do
    trace =
      UptimeTracer.trace(
        [],
        @start,
        DateTime.add(@start, 120, :second),
        60,
        incidents: [%{started_at: @start, resolved_at: DateTime.add(@start, 60, :second)}],
        pauses: [%{paused_at: DateTime.add(@start, 60, :second), resumed_at: nil}]
      )

    assert Enum.map(trace.buckets, & &1.state) == [:missing, :paused]
  end

  test "a heartbeat's missing ping under an open incident is the failure" do
    trace =
      UptimeTracer.trace(
        [],
        @start,
        DateTime.add(@start, 120, :second),
        60,
        incidents: [%{started_at: @start, resolved_at: DateTime.add(@start, 60, :second)}],
        pauses: [%{paused_at: DateTime.add(@start, 60, :second), resumed_at: nil}],
        missing_is_failure: true
      )

    assert Enum.map(trace.buckets, & &1.state) == [:down, :paused]
  end

  test "an observed failure under an incident stays down, and the bucket in progress says so" do
    trace =
      UptimeTracer.trace(
        [check(~U[2026-01-01 00:00:10Z], "down")],
        @start,
        DateTime.add(@start, 120, :second),
        60,
        incidents: [%{started_at: @start, resolved_at: nil}],
        now: DateTime.add(@start, 70, :second)
      )

    [first, second] = trace.buckets
    assert first.state == :down
    refute first.in_progress?
    assert second.state == :missing
    assert second.in_progress?
    assert second.aria_label =~ "in progress"
  end

  test "rejects records from another tenant or monitor" do
    check =
      check(~U[2026-01-01 00:00:05Z], "up",
        org_id: "org_other",
        project_id: "project_a",
        monitor_id: "monitor_a"
      )

    assert_raise ArgumentError, ~r/org_id/, fn ->
      UptimeTracer.trace(
        [check],
        @start,
        DateTime.add(@start, 60, :second),
        60,
        scope: %{org_id: "org_a", project_id: "project_a", monitor_id: "monitor_a"}
      )
    end

    assert :ok =
             UptimeTracer.validate_scope!(
               [%{org_id: "org_a", project_id: "project_a", monitor_id: "monitor_a"}],
               %{
                 org_id: "org_a",
                 project_id: "project_a",
                 monitor_id: "monitor_a"
               }
             )
  end

  test "emits table rows from the same interval values as the visual buckets" do
    trace =
      UptimeTracer.trace(
        [check(~U[2026-01-01 00:00:05Z], "up")],
        @start,
        DateTime.add(@start, 60, :second),
        60
      )

    [bucket] = trace.buckets
    [row] = trace.table_rows

    assert Enum.at(row.cells, 0) == Calendar.strftime(bucket.start_at, "%Y-%m-%d %H:%M UTC")
    assert Enum.at(row.cells, 2) == "Up"
    assert Enum.at(row.cells, 3) == "1"
  end

  test "dashboard timeline bounds are exact UTC hourly and daily buckets" do
    now = ~U[2026-02-12 14:37:52Z]

    assert {~U[2026-02-11 15:00:00Z], ~U[2026-02-12 15:00:00Z], 3_600, 24} =
             UptimeTracer.timeline_bounds("24h", now)

    assert {~U[2026-02-06 00:00:00Z], ~U[2026-02-13 00:00:00Z], 86_400, 7} =
             UptimeTracer.timeline_bounds("7d", now)

    assert {~U[2026-01-14 00:00:00Z], ~U[2026-02-13 00:00:00Z], 86_400, 30} =
             UptimeTracer.timeline_bounds("30d", now)
  end
end
