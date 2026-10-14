defmodule Alplus.Observe.DeploymentCorrelationTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.{Incident, Monitor, MonitorCheck}
  alias Alplus.Observe.{DeploymentCorrelation, EventWriter, Release}
  alias Alplus.Scope

  @release_at ~U[2026-08-20 12:00:00.000000Z]
  @now ~U[2026-08-21 12:00:00.000000Z]

  defp project_scope(scope, project), do: Scope.put_project(scope, project.id)

  defp release_fixture(scope, org, project, source, attrs \\ %{}) do
    Ash.create!(
      Release,
      Map.merge(
        %{
          org_id: org.id,
          project_id: project.id,
          source_id: source.id,
          environment: source.environment,
          version: "2026.08.20.1",
          released_at: @release_at
        },
        attrs
      ),
      actor: project_scope(scope, project)
    )
  end

  defp monitor_fixture(org, project, environment \\ "production") do
    Ash.create!(
      Monitor,
      %{
        org_id: org.id,
        project_id: project.id,
        environment: environment,
        type: "http",
        name: "API"
      },
      action: :create,
      authorize?: false
    )
  end

  defp check_fixture(org, project, monitor, checked_at, latency_ms) do
    Ash.create!(
      MonitorCheck,
      %{
        org_id: org.id,
        project_id: project.id,
        monitor_id: monitor.id,
        environment: monitor.environment,
        status: "up",
        checked_at: checked_at,
        latency_ms: latency_ms,
        status_code: 200
      },
      action: :record,
      authorize?: false
    )
  end

  defp insert_hour!(org, project, source, hour, pageviews) do
    Alplus.Repo.query!(
      """
      INSERT INTO analytics_hours
        (id, org_id, project_id, source_id, environment, hour, pageviews, visitors, visits, bounces,
         duration_seconds, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $7, $7, 0, 0, now(), now())
      """,
      [
        Ecto.UUID.generate() |> Ecto.UUID.dump!(),
        org.id,
        project.id,
        source.id,
        source.environment,
        hour,
        pageviews
      ]
    )
  end

  defp event(source, event_id, received_at) do
    %{
      event_id: event_id,
      org_id: source.org_id,
      project_id: source.project_id,
      source_id: source.id,
      environment: source.environment,
      occurred_at: received_at,
      received_at: received_at,
      level: "error",
      sdk_name: "@alplus/sdk",
      sdk_version: "0.3.0",
      exception_type: "RuntimeError",
      exception_value: "boom",
      frames: [%{file: "/src/app.ts", function: "run", lineno: 1}]
    }
  end

  setup do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    {observe_source, _} = source_fixture(owner_scope, org, project, %{environment: "production"})

    %{
      org: org,
      owner_scope: owner_scope,
      project: project,
      scope: project_scope(owner_scope, project),
      observe_source: observe_source
    }
  end

  test "correlates equal windows without blending same-environment Measure Sources", %{
    org: org,
    project: project,
    scope: scope,
    observe_source: observe_source
  } do
    monitor = monitor_fixture(org, project)

    check_fixture(org, project, monitor, ~U[2026-08-20 11:15:00Z], 100)
    check_fixture(org, project, monitor, ~U[2026-08-20 11:45:00Z], 200)
    check_fixture(org, project, monitor, ~U[2026-08-20 12:15:00Z], 300)
    check_fixture(org, project, monitor, ~U[2026-08-20 12:45:00Z], 400)

    {site_a, _} = source_fixture(scope, org, project, %{type: :measure, name: "Site A"})
    {site_b, _} = source_fixture(scope, org, project, %{type: :measure, name: "Site B"})

    insert_hour!(org, project, site_a, ~U[2026-08-20 11:00:00Z], 10)
    insert_hour!(org, project, site_a, ~U[2026-08-20 11:30:00Z], 20)
    insert_hour!(org, project, site_a, ~U[2026-08-20 12:00:00Z], 30)
    insert_hour!(org, project, site_a, ~U[2026-08-20 12:30:00Z], 40)
    insert_hour!(org, project, site_b, ~U[2026-08-20 11:00:00Z], 100)
    insert_hour!(org, project, site_b, ~U[2026-08-20 11:30:00Z], 200)
    insert_hour!(org, project, site_b, ~U[2026-08-20 12:00:00Z], 300)
    insert_hour!(org, project, site_b, ~U[2026-08-20 12:30:00Z], 400)

    {:ok, _} = EventWriter.record(event(observe_source, "before-1", ~U[2026-08-20 11:15:00Z]))
    {:ok, _} = EventWriter.record(event(observe_source, "before-2", ~U[2026-08-20 11:45:00Z]))
    {:ok, _} = EventWriter.record(event(observe_source, "after-1", ~U[2026-08-20 12:15:00Z]))

    release = release_fixture(scope, org, project, observe_source)

    assert {:ok, result} =
             DeploymentCorrelation.correlate(release, scope,
               window_seconds: 3_600,
               now: @now
             )

    assert result.window.equal?
    assert result.environment == "production"
    assert result.errors.metric.before == 2
    assert result.errors.metric.after == 1

    [monitor_result] = result.monitors
    assert monitor_result.comparison.state == :ready
    assert monitor_result.comparison.direction == :worse
    assert_in_delta monitor_result.before, 195.0, 0.001
    assert_in_delta monitor_result.after, 395.0, 0.001

    assert Enum.map(result.measure_sources, & &1.resource.name) == ["Site A", "Site B"]
    assert Enum.map(result.measure_sources, & &1.before) == [30, 300]
    assert Enum.map(result.measure_sources, & &1.after) == [70, 700]
    assert Enum.all?(result.measure_sources, &(&1.comparison.state == :ready))

    assert {:ok, partial} =
             DeploymentCorrelation.correlate(release, scope,
               window_seconds: 21_600,
               now: @now
             )

    assert partial.state == :partial
    assert partial.reason == :insufficient_evidence
  end

  test "marks overlapping incidents as confounded instead of claiming a latency change", %{
    org: org,
    project: project,
    scope: scope,
    observe_source: source
  } do
    monitor = monitor_fixture(org, project)
    check_fixture(org, project, monitor, ~U[2026-08-20 11:30:00Z], 100)
    check_fixture(org, project, monitor, ~U[2026-08-20 12:30:00Z], 300)

    Ash.create!(
      Incident,
      %{
        org_id: org.id,
        project_id: project.id,
        monitor_id: monitor.id,
        environment: "production",
        cause: "availability",
        started_at: ~U[2026-08-20 11:50:00Z],
        checks_failed_count: 1
      },
      action: :open,
      authorize?: false
    )

    release = release_fixture(scope, org, project, source)

    assert {:ok, result} =
             DeploymentCorrelation.correlate(release, scope,
               window_seconds: 3_600,
               now: @now
             )

    assert result.state == :confounded
    assert result.reason == :incident_overlap
    assert [%{confounded?: true, incident_overlap?: true}] = result.monitors
  end

  test "keeps a missing Measure side unavailable instead of rendering a zero", %{
    org: org,
    project: project,
    scope: scope,
    observe_source: observe_source
  } do
    {site, _} = source_fixture(scope, org, project, %{type: :measure, name: "Partial site"})
    insert_hour!(org, project, site, ~U[2026-08-20 12:30:00Z], 50)
    release = release_fixture(scope, org, project, observe_source)

    assert {:ok, result} =
             DeploymentCorrelation.correlate(release, scope,
               window_seconds: 3_600,
               now: @now
             )

    [site_result] = result.measure_sources
    assert site_result.before == nil
    assert site_result.after == 50
    assert site_result.state == :insufficient
  end

  test "reports incomplete after windows and rejects a release from another tenant", %{
    org: org,
    project: project,
    scope: scope,
    observe_source: source
  } do
    release = release_fixture(scope, org, project, source)

    assert {:ok, result} =
             DeploymentCorrelation.correlate(release, scope,
               window_seconds: 3_600,
               now: ~U[2026-08-20 12:30:00Z]
             )

    refute result.window.equal?
    assert result.state == :unavailable
    assert result.reason == :unequal_windows
    assert result.errors.state == :unavailable

    {other_org, other_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_scope, other_org)
    {other_source, _} = source_fixture(other_scope, other_org, other_project)
    other_release = release_fixture(other_scope, other_org, other_project, other_source)

    assert DeploymentCorrelation.correlate(other_release, scope, now: @now) ==
             {:error, :not_found}
  end

  test "metric keeps missing values explicit", _context do
    assert DeploymentCorrelation.metric(nil, 4, :lower_is_better) == %{
             before: nil,
             after: 4,
             delta: nil,
             delta_percent: nil,
             direction: :unavailable,
             state: :unavailable
           }

    assert DeploymentCorrelation.metric(10, 8, :lower_is_better).direction == :better
    assert DeploymentCorrelation.metric(10, 12, :higher_is_better).direction == :better
  end
end
