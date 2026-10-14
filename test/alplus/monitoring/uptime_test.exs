defmodule Alplus.Monitoring.UptimeTest do
  use ExUnit.Case, async: true

  alias Alplus.Monitoring.Uptime

  @window_start ~U[2026-08-01 00:00:00Z]
  @window_end ~U[2026-08-01 01:00:00Z]

  test "calculates uptime from incident duration rather than check counts" do
    result =
      Uptime.calculate(@window_start, @window_end, [incident("00:10:00", "00:25:00")], [])

    assert result.monitored_microseconds == 3_600_000_000
    assert result.downtime_microseconds == 900_000_000
    assert result.uptime == 0.75
  end

  test "merges overlapping incidents before calculating downtime" do
    result =
      Uptime.calculate(
        @window_start,
        @window_end,
        [incident("00:10:00", "00:30:00"), incident("00:20:00", "00:40:00")],
        []
      )

    assert result.downtime_microseconds == 1_800_000_000
    assert result.uptime == 0.5
  end

  test "excludes paused time from uptime and downtime" do
    result =
      Uptime.calculate(
        @window_start,
        @window_end,
        [incident("00:10:00", "00:30:00")],
        [incident("00:20:00", "00:40:00")]
      )

    assert result.monitored_microseconds == 2_400_000_000
    assert result.downtime_microseconds == 600_000_000
    assert result.uptime == 0.75
  end

  test "uses the window end for an open incident" do
    result = Uptime.calculate(@window_start, @window_end, [%{started_at: at("00:30:00")}], [])

    assert result.downtime_microseconds == 1_800_000_000
    assert result.uptime == 0.5
  end

  test "returns nil uptime where the monitor was paused for the full window" do
    result = Uptime.calculate(@window_start, @window_end, [], [incident("00:00:00", "01:00:00")])

    assert result.monitored_microseconds == 0
    assert result.downtime_microseconds == 0
    assert result.uptime == nil
  end

  defp incident(start_at, end_at), do: %{started_at: at(start_at), resolved_at: at(end_at)}

  defp at(time) do
    time
    |> then(&NaiveDateTime.from_iso8601!("2026-08-01T#{&1}"))
    |> DateTime.from_naive!("Etc/UTC")
  end
end
