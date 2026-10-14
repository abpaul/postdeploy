defmodule Alplus.Monitoring.ReliabilityTest do
  use ExUnit.Case, async: true

  alias Alplus.Monitoring.Reliability

  @day_microseconds 86_400_000_000

  test "error budget uses pause-adjusted monitored time and exact integer durations" do
    monitored = 82_800_000_000
    downtime = 30_000_000

    days = [
      day(%{
        day: ~D[2026-08-25],
        monitored_microseconds: monitored,
        downtime_microseconds: downtime,
        check_count: 10
      })
    ]

    budget =
      Reliability.budget_from_days(0.999, days, now: ~U[2026-08-25 12:00:00Z])

    assert budget.allowed_downtime_microseconds == 82_800_000
    assert budget.spent_downtime_microseconds == downtime
    assert budget.remaining_downtime_microseconds == 52_800_000
    assert_in_delta budget.attainment, (monitored - downtime) / monitored, 0.000001
    assert_in_delta budget.burn_rate, downtime / budget.allowed_downtime_microseconds, 0.000001
    assert budget.month_end == ~D[2026-08-31]
  end

  test "objective remains absent when no target is declared" do
    refute Reliability.valid_target?(nil)
    assert Reliability.budget_from_days(nil, []) == nil
  end

  test "a 100 percent objective with zero downtime is not exhausted" do
    budget =
      Reliability.budget(
        1.0,
        %{
          monitored_microseconds: 10_000_000_000,
          downtime_microseconds: 0,
          evidence_state: :ready
        },
        now: ~U[2026-08-25 12:00:00Z]
      )

    refute budget.exhausted?
    assert budget.state == :healthy
  end

  test "insufficient evidence does not claim attainment" do
    days = [day(%{monitored_microseconds: 299_000_000, check_count: 1})]
    summary = Reliability.summary(days)
    budget = Reliability.budget_from_days(0.999, days, now: ~U[2026-08-25 12:00:00Z])

    assert summary.evidence_state == :insufficient
    assert summary.uptime == nil
    assert budget.evidence_state == :insufficient
    assert budget.attainment == nil
    assert budget.state == :insufficient
  end

  test "daily states distinguish missing, paused, incident, degraded, and healthy" do
    assert Reliability.daily_state(day(%{evidence?: false, check_count: 0})) == :missing
    assert Reliability.daily_state(day(%{pause_count: 1, monitored_microseconds: 0})) == :paused

    assert Reliability.daily_state(
             day(%{
               pause_count: 1,
               monitored_microseconds: 100,
               historical_partial?: true,
               degraded_check_count: 1
             })
           ) == :paused

    assert Reliability.daily_state(day(%{downtime_microseconds: 1_000, incident_count: 1})) ==
             :incident

    assert Reliability.daily_state(day(%{degraded_check_count: 1})) == :degraded
    assert Reliability.daily_state(day(%{check_count: 1})) == :healthy
  end

  defp day(overrides) do
    Map.merge(
      %{
        day: Date.add(Date.utc_today(), -1),
        state: :healthy,
        uptime: 1.0,
        monitored_microseconds: @day_microseconds,
        downtime_microseconds: 0,
        check_count: 1,
        incident_count: 0,
        pause_count: 0,
        degraded_check_count: 0,
        evidence?: true,
        partial?: false
      },
      overrides
    )
  end
end
