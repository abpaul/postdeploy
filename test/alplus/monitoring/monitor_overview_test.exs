defmodule Alplus.Monitoring.MonitorOverviewTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.{Monitor, MonitorOverview}

  test "activity query count stays bounded as the visible page grows" do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    small_project = project_fixture(scope, org, %{name: "Small fleet"})
    large_project = project_fixture(scope, org, %{name: "Large fleet"})

    create_monitors(scope, org, small_project, 1)
    create_monitors(scope, org, large_project, 20)

    small_scope = Alplus.Scope.put_project(scope, small_project.id)
    large_scope = Alplus.Scope.put_project(scope, large_project.id)

    small_queries =
      count_repo_queries(fn ->
        overview = MonitorOverview.load!(small_project, small_scope, filters())
        assert length(overview.rows) == 1
      end)

    large_queries =
      count_repo_queries(fn ->
        overview = MonitorOverview.load!(large_project, large_scope, filters())
        assert length(overview.rows) == 20
      end)

    assert small_queries > 0
    # Relationship loads and the keyset count may add a small fixed number of
    # reads, but the page must not add one query per visible monitor.
    assert large_queries <= small_queries + 8
  end

  test "a monitor deleted while its detail page loads yields an empty activity" do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    project_scope = Alplus.Scope.put_project(scope, project.id)

    [monitor] = create_monitors(scope, org, project, 1)
    Ash.destroy!(monitor, action: :destroy, actor: project_scope)

    assert {row, activity} = MonitorOverview.activity_for(monitor, project_scope, "24h")
    assert row.monitor.id == monitor.id
    assert activity.check_count == 0
    assert activity.uptime == nil
  end

  defp create_monitors(scope, org, project, count) do
    project_scope = Alplus.Scope.put_project(scope, project.id)

    for index <- 1..count do
      Ash.create!(
        Monitor,
        %{
          org_id: org.id,
          project_id: project.id,
          type: "http",
          name: "Monitor #{index}"
        },
        action: :create,
        actor: project_scope
      )
    end
  end

  defp filters do
    %{environment: nil, window: "24h", query: nil, status: nil, type: nil, cursor: nil}
  end

  defp count_repo_queries(fun) do
    telemetry_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :telemetry.attach(
      telemetry_id,
      [:alplus, :repo, :query],
      fn _event, _measurements, _metadata, pid -> send(pid, :monitor_overview_query) end,
      self()
    )

    try do
      fun.()
      collect_queries()
    after
      :telemetry.detach(telemetry_id)
    end
  end

  defp collect_queries(count \\ 0) do
    receive do
      :monitor_overview_query -> collect_queries(count + 1)
    after
      100 -> count
    end
  end
end
