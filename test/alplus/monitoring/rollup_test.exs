defmodule Alplus.Monitoring.RollupTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.{Monitor, Rollup}
  alias Alplus.Scope

  @day ~D[2026-08-01]

  test "builds a daily result from incident duration, not check count" do
    rollup =
      Rollup.build(
        @day,
        [%{started_at: at("00:00:00"), resolved_at: at("06:00:00")}],
        [],
        2
      )

    assert rollup.check_count == 2
    assert rollup.monitored_microseconds == 86_400_000_000
    assert rollup.downtime_microseconds == 21_600_000_000
    assert rollup.uptime_ratio == 0.75
  end

  test "excludes supplied persisted pause intervals from the daily denominator" do
    rollup =
      Rollup.build(
        @day,
        [%{started_at: at("00:00:00"), resolved_at: at("12:00:00")}],
        [%{started_at: at("06:00:00"), resolved_at: at("18:00:00")}],
        12
      )

    assert rollup.monitored_microseconds == 43_200_000_000
    assert rollup.downtime_microseconds == 21_600_000_000
    assert rollup.uptime_ratio == 0.5
  end

  test "uses UTC day boundaries" do
    assert {~U[2026-08-01 00:00:00Z], ~U[2026-08-02 00:00:00Z]} = Rollup.day_window(@day)
  end

  test "finalize reads incidents through raw SQL without crashing on naive timestamps" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "API"},
        action: :create,
        actor: scope
      )

    # Inserted with raw SQL, exactly like `ActiveCheckOutcome` writes it in
    # production: Postgrex round-trips `started_at`/`resolved_at` back to
    # `Rollup`'s own `Repo.query!` reads as `NaiveDateTime`, not `DateTime`.
    Alplus.Repo.query!(
      """
      INSERT INTO incidents
        (id, org_id, project_id, monitor_id, environment, cause, cause_detail,
         status, started_at, resolved_at, duration_seconds, checks_failed_count,
         inserted_at, updated_at)
      VALUES ($1,$2,$3,$4,$5,'availability','{}','resolved',$6,$7,21600,1,$6,$7)
      """,
      [
        Alplus.Id.generate(:incident),
        org.id,
        project.id,
        monitor.id,
        monitor.environment,
        DateTime.new!(@day, ~T[00:00:00], "Etc/UTC"),
        DateTime.new!(@day, ~T[06:00:00], "Etc/UTC")
      ]
    )

    assert {:ok, rollup} = Rollup.finalize(scope, monitor.id, @day)
    assert rollup.uptime_ratio == 0.75
    assert rollup.downtime_microseconds == 21_600_000_000
  end

  defp at(time),
    do: DateTime.from_naive!(NaiveDateTime.from_iso8601!("2026-08-01T#{time}"), "Etc/UTC")
end
