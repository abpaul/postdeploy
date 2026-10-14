defmodule Alplus.Growth.HealthCheckTest do
  use Alplus.DataCase, async: true

  alias Alplus.Growth.HealthCheck
  alias Alplus.Growth.Retention

  test "records stages once per journey and never stores a target URL" do
    journey = HealthCheck.new_journey_id()
    assert :ok = HealthCheck.record(journey, "health_check_started")
    assert :ok = HealthCheck.record(journey, "health_check_started")
    assert :ok = HealthCheck.record(journey, "health_check_result_produced")

    {:ok, rows} = Alplus.Growth.list_journey_events(authorize?: false)
    mine = Enum.filter(rows, &(&1.journey_id == journey))
    assert length(mine) == 2
    refute Enum.any?(mine, fn row -> Map.has_key?(row, :url) and row.url end)
  end

  test "prune keeps daily totals and deletes events older than 30 days" do
    journey = HealthCheck.new_journey_id()
    assert :ok = HealthCheck.record(journey, "health_check_started")

    {:ok, rows} = Alplus.Growth.list_journey_events(authorize?: false)
    [event] = Enum.filter(rows, &(&1.journey_id == journey))

    old = DateTime.add(DateTime.utc_now(), -31, :day)

    Alplus.Repo.query!(
      "UPDATE growth_journey_events SET inserted_at = $1 WHERE id = $2",
      [old, event.id]
    )

    assert :ok = Retention.prune(DateTime.utc_now())

    {:ok, remaining} = Alplus.Growth.list_journey_events(authorize?: false)
    refute Enum.any?(remaining, &(&1.id == event.id))

    %{rows: [[count]]} =
      Alplus.Repo.query!(
        "SELECT count FROM growth_health_check_daily_counts WHERE stage = $1",
        ["health_check_started"]
      )

    assert count >= 1
  end
end
