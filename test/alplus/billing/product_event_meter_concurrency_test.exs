defmodule Alplus.Billing.ProductEventMeterConcurrencyTest do
  @moduledoc """
  The monthly event ceiling under real concurrency.

  The batch meter takes a row lock and then decides how many of the batch
  fit. Without the lock two simultaneous ingest requests each read the same
  pre-count and each accept a full batch, so the organization writes past its
  own ceiling and the customer is billed for events PostDeploy promised to
  drop.

  Warning: these tests commit rows. Read `Alplus.ConcurrencyCase` first.
  """

  # Not async: these tests run outside the Ecto sandbox on real connections.
  use Alplus.ConcurrencyCase, async: false

  alias Alplus.Billing.{EventMeter, Package}
  alias Alplus.Repo

  test "two concurrent batches cannot both cross the ceiling" do
    scope = scope_fixture()
    {org, _owner_scope} = org_fixture(scope)
    delete_after_test([org.id], [scope.user_id])
    subscribed_fixture(org)

    ceiling = Package.event_ceiling(Package.limit(:product_events_per_month))
    now = DateTime.utc_now()

    # Seat the period ten events below the ceiling. Two batches of ten each
    # want twenty; together they may take exactly ten.
    seat_period(org.id, now, ceiling - 10)

    results =
      race_for_usage_period(org.id, period_start(now), 2, fn _index ->
        EventMeter.consume(org.id, :product_events, now, 10)
      end)

    accepted = results |> Enum.map(& &1.accepted) |> Enum.sum()
    dropped = results |> Enum.map(& &1.dropped) |> Enum.sum()

    assert accepted == 10
    assert dropped == 10
    assert period_count(org.id, now) == ceiling
  end

  test "a batch that fits entirely is accepted whole" do
    scope = scope_fixture()
    {org, _owner_scope} = org_fixture(scope)
    delete_after_test([org.id], [scope.user_id])
    subscribed_fixture(org)

    now = DateTime.utc_now()
    seat_period(org.id, now, 0)

    results =
      race_for_usage_period(org.id, period_start(now), 2, fn _index ->
        EventMeter.consume(org.id, :product_events, now, 25)
      end)

    assert Enum.all?(results, &(&1.accepted == 25))
    assert period_count(org.id, now) == 50
  end

  defp period_start(now), do: EventMeter.month_start(DateTime.to_date(now))

  defp seat_period(org_id, now, count) do
    Repo.query!(
      """
      INSERT INTO usage_periods (id, org_id, period_start, product_events, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, now(), now())
      ON CONFLICT (org_id, period_start) DO UPDATE SET product_events = EXCLUDED.product_events
      """,
      [
        Alplus.Id.generate(:usage_period),
        org_id,
        EventMeter.month_start(DateTime.to_date(now)),
        count
      ]
    )
  end

  defp period_count(org_id, now) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT product_events FROM usage_periods WHERE org_id = $1 AND period_start = $2",
        [org_id, EventMeter.month_start(DateTime.to_date(now))]
      )

    count
  end
end
