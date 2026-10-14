defmodule Alplus.Monitoring.ReliabilityHistoryTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.{DailyRollup, Monitor, Reliability}
  alias Alplus.Scope

  test "history reads each evidence dataset once" do
    {org, owner_scope} = org_fixture(scope_fixture())
    subscribed_fixture(org)
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "Query count"},
        action: :create,
        actor: scope
      )

    query_count =
      count_repo_queries(fn ->
        assert {:ok, history} = Reliability.history(monitor, scope)
        assert length(history.days) == 90
      end)

    # The access lookup can use more than one query, plus one bounded query for
    # each evidence source. The daily classifier must not repeat those reads
    # for every history day.
    assert query_count <= 6
  end

  test "history uses durable rollup evidence and leaves the current day partial" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    monitor =
      Ash.create!(
        Monitor,
        %{
          org_id: org.id,
          project_id: project.id,
          type: "http",
          name: "API",
          slo_target: 0.999
        },
        action: :create,
        actor: scope
      )

    yesterday = Date.add(Date.utc_today(), -1)

    Ash.Seed.seed!(DailyRollup, %{
      org_id: org.id,
      project_id: project.id,
      monitor_id: monitor.id,
      day: yesterday,
      uptime_ratio: 0.999,
      monitored_microseconds: 82_800_000_000,
      downtime_microseconds: 30_000_000,
      check_count: 7
    })

    now = DateTime.new!(Date.utc_today(), ~T[12:00:00], "Etc/UTC")
    assert {:ok, history} = Reliability.history(monitor, scope, now: now)

    assert length(history.days) == 90
    assert history.target == 0.999

    assert Enum.find(history.days, &(&1.day == yesterday)) == %{
             day: yesterday,
             state: :incident,
             uptime: 0.999,
             monitored_microseconds: 82_800_000_000,
             downtime_microseconds: 30_000_000,
             check_count: 7,
             incident_count: 0,
             pause_count: 0,
             degraded_check_count: 0,
             evidence?: true,
             partial?: false,
             historical_partial?: false
           }

    today = Enum.find(history.days, &(&1.day == Date.utc_today()))
    assert today.partial?
    assert today.state == :missing
    assert history.budget.evidence_state == :ready
  end

  test "marks old rollup evidence partial when raw checks expired" do
    {org, owner_scope} = org_fixture(scope_fixture())
    subscribed_fixture(org)
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    monitor =
      Ash.create!(
        Monitor,
        %{
          org_id: org.id,
          project_id: project.id,
          type: "http",
          name: "Retention",
          slo_target: 0.99
        },
        action: :create,
        actor: scope
      )

    old_day = Date.add(Date.utc_today(), -31)

    Ash.Seed.seed!(DailyRollup, %{
      org_id: org.id,
      project_id: project.id,
      monitor_id: monitor.id,
      day: old_day,
      uptime_ratio: 1.0,
      monitored_microseconds: 82_800_000_000,
      downtime_microseconds: 0,
      check_count: 12
    })

    assert {:ok, history} = Reliability.history(monitor, scope)
    day = Enum.find(history.days, &(&1.day == old_day))
    assert day.state == :partial
    assert day.historical_partial?
    refute day.state == :healthy
  end

  test "pause evidence wins over partial retention" do
    {org, owner_scope} = org_fixture(scope_fixture())
    subscribed_fixture(org)
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "Paused", slo_target: 0.99},
        action: :create,
        actor: scope
      )

    day = Date.add(Date.utc_today(), -31)

    Ash.Seed.seed!(DailyRollup, %{
      org_id: org.id,
      project_id: project.id,
      monitor_id: monitor.id,
      day: day,
      uptime_ratio: 1.0,
      monitored_microseconds: 300_000_000,
      downtime_microseconds: 0,
      check_count: 12
    })

    insert_pause_interval(org, project, monitor, day)

    assert {:ok, history} = Reliability.history(monitor, scope)
    row = Enum.find(history.days, &(&1.day == day))
    assert row.state == :paused
    assert row.pause_count == 1
    assert row.historical_partial?
  end

  test "retention cutoff follows the package's detailed check retention" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    retention = Alplus.Billing.Package.limit(:detailed_uptime_retention_days)
    subscribed_fixture(org)

    for {age_days, partial?} <- [{retention + 1, true}, {retention - 1, false}] do
      monitor =
        Ash.create!(
          Monitor,
          %{
            org_id: org.id,
            project_id: project.id,
            type: "http",
            name: "#{age_days} days old",
            slo_target: 0.99
          },
          action: :create,
          actor: scope
        )

      day = Date.add(Date.utc_today(), -age_days)

      Ash.Seed.seed!(DailyRollup, %{
        org_id: org.id,
        project_id: project.id,
        monitor_id: monitor.id,
        day: day,
        uptime_ratio: 1.0,
        monitored_microseconds: 82_800_000_000,
        downtime_microseconds: 0,
        check_count: 12
      })

      assert {:ok, history} = Reliability.history(monitor, scope)
      row = Enum.find(history.days, &(&1.day == day))
      assert row.historical_partial? == partial?
    end
  end

  test "history refuses a monitor outside the supplied project scope" do
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

    assert {:error, :out_of_scope} =
             Reliability.history(monitor, %Scope{org_id: org.id, project_id: "project_other"})
  end

  test "history does not expose evidence to an authenticated outsider" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "Private API"},
        action: :create,
        actor: scope
      )

    day = Date.add(Date.utc_today(), -1)

    Ash.Seed.seed!(DailyRollup, %{
      org_id: org.id,
      project_id: project.id,
      monitor_id: monitor.id,
      day: day,
      uptime_ratio: 1.0,
      monitored_microseconds: 600_000_000,
      downtime_microseconds: 0,
      check_count: 1
    })

    outsider = user_fixture()
    outsider_scope = %Scope{user_id: outsider.id, org_id: org.id, project_id: project.id}

    assert {:ok, history} = Reliability.history(monitor, outsider_scope)
    refute Enum.any?(history.days, & &1.evidence?)
  end

  test "resource validation rejects SLO ratios outside the contract" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    for target <- [0, -0.1, 1.1] do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(
                 Monitor,
                 %{
                   org_id: org.id,
                   project_id: project.id,
                   type: "http",
                   name: "API",
                   slo_target: target
                 },
                 action: :create,
                 actor: scope
               )
    end
  end

  defp count_repo_queries(fun) do
    telemetry_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :telemetry.attach(
      telemetry_id,
      [:alplus, :repo, :query],
      fn _event, _measurements, _metadata, pid -> send(pid, :reliability_query) end,
      self()
    )

    try do
      fun.()
      collect_query_count()
    after
      :telemetry.detach(telemetry_id)
    end
  end

  defp insert_pause_interval(org, project, monitor, day) do
    paused_at = DateTime.new!(day, ~T[12:00:00], "Etc/UTC")
    resumed_at = DateTime.add(paused_at, 3_600, :second)

    Alplus.Repo.query!(
      """
      INSERT INTO monitor_pause_intervals
        (id, org_id, project_id, monitor_id, paused_at, resumed_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $5, $6)
      """,
      [
        Alplus.Id.generate(:monitor_pause_interval),
        org.id,
        project.id,
        monitor.id,
        paused_at,
        resumed_at
      ]
    )
  end

  defp collect_query_count(count \\ 0) do
    receive do
      :reliability_query -> collect_query_count(count + 1)
    after
      100 -> count
    end
  end
end
