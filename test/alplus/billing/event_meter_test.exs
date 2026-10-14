defmodule Alplus.Billing.EventMeterTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Billing.{EventMeter, Package}
  alias Alplus.Repo

  @now ~U[2026-08-11 12:00:00Z]

  setup do
    {org, _scope} = org_fixture(scope_fixture())
    %{org: org}
  end

  test "meters error events through one shared implementation and drops past 130%", %{org: org} do
    subscribed_fixture(org)
    limit = Package.limit(:error_events_per_month)
    ceiling = Package.event_ceiling(limit)
    seed_usage(org.id, EventMeter.month_start(DateTime.to_date(@now)), :error_events, ceiling - 1)

    accepted = EventMeter.consume(org.id, :error_events, @now)
    assert accepted.accepted?
    assert accepted.count == ceiling
    assert accepted.dropped == 0

    dropped = EventMeter.consume(org.id, :error_events, @now)
    refute dropped.accepted?
    assert dropped.count == ceiling
    assert dropped.dropped == 1

    assert EventMeter.current(org.id, @now).error_events == ceiling
    assert EventMeter.current(org.id, @now).dropped_error_events == 1
  end

  test "meters analytics events with the same atomic upsert and ceiling", %{org: org} do
    subscribed_fixture(org)
    limit = Package.limit(:analytics_events_per_month)
    ceiling = Package.event_ceiling(limit)

    seed_usage(
      org.id,
      EventMeter.month_start(DateTime.to_date(@now)),
      :analytics_events,
      ceiling - 1
    )

    accepted = EventMeter.consume(org.id, :analytics_events, @now)
    assert accepted.accepted?
    assert accepted.count == ceiling

    dropped = EventMeter.consume(org.id, :analytics_events, @now)
    refute dropped.accepted?
    assert dropped.dropped == 1

    assert EventMeter.current(org.id, @now).analytics_events == ceiling
    assert EventMeter.current(org.id, @now).dropped_analytics_events == 1
  end

  test "starts a fresh period at zero when no row exists yet", %{org: org} do
    decision = EventMeter.consume(org.id, :error_events, @now)

    assert decision.accepted?
    assert decision.count == 1
    assert decision.dropped == 0
    assert decision.period_start == EventMeter.month_start(DateTime.to_date(@now))
  end

  test "refuses an expired trial without creating a usage row", %{org: org} do
    Repo.query!("UPDATE organizations SET trial_ends_at = $1 WHERE id = $2", [
      ~U[2000-01-01 00:00:00.000000Z],
      org.id
    ])

    decision = EventMeter.consume(org.id, :analytics_events, DateTime.utc_now())

    refute decision.accepted?

    assert [[0]] =
             Repo.query!("SELECT count(*) FROM usage_periods WHERE org_id = $1", [org.id]).rows
  end

  defp seed_usage(org_id, period_start, :error_events, count) do
    Repo.query!(
      """
      INSERT INTO usage_periods
        (id, org_id, period_start, analytics_events, dropped_analytics_events, error_events, dropped_error_events, inserted_at, updated_at)
      VALUES ($1, $2, $3, 0, 0, $4, 0, now(), now())
      """,
      [Alplus.Id.generate(:usage_period), org_id, period_start, count]
    )
  end

  defp seed_usage(org_id, period_start, :analytics_events, count) do
    Repo.query!(
      """
      INSERT INTO usage_periods
        (id, org_id, period_start, analytics_events, dropped_analytics_events, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 0, now(), now())
      """,
      [Alplus.Id.generate(:usage_period), org_id, period_start, count]
    )
  end
end
