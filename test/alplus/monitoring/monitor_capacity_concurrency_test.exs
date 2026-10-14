defmodule Alplus.Monitoring.MonitorCapacityConcurrencyTest do
  @moduledoc """
  Monitor capacity under real concurrency, through `MonitorCreator.create/3`
  — the public creation boundary the console and the API both call.

  Warning: these tests commit rows. Read `Alplus.ConcurrencyCase` first.
  """

  # Not async: these tests run outside the Ecto sandbox on real connections.
  use Alplus.ConcurrencyCase, async: false

  alias Alplus.Monitoring.{Monitor, MonitorCreator}
  alias Alplus.Scope

  test "two concurrent creates cannot both take the last monitor slot" do
    scope = scope_fixture()
    {org, owner_scope} = org_fixture(scope)
    subscribed_fixture(org)
    # `delete_after_test` stops every monitor before it deletes the rows those
    # monitors check.
    delete_after_test([org.id], [scope.user_id])

    project = project_fixture(owner_scope, org)
    actor = Scope.put_project(owner_scope, project.id)

    limit = Alplus.Billing.Package.limit(:uptime_monitors)

    # Seed one fewer than the limit, leaving one slot.
    for number <- 1..(limit - 1) do
      Ash.Seed.seed!(Monitor, Map.put(monitor_attrs(org, project), :name, "Existing #{number}"))
    end

    results =
      race_for_org(org.id, 2, fn index ->
        MonitorCreator.create(
          Map.put(monitor_attrs(org, project), :name, "Race #{index}"),
          http_config(),
          actor
        )
      end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    assert monitor_count(org.id) == limit
  end

  defp monitor_attrs(org, project) do
    %{org_id: org.id, project_id: project.id, type: "http", name: "API"}
  end

  defp http_config do
    %{
      url: "https://example.test/health",
      method: "GET",
      expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
      interval_seconds: 300,
      timeout_seconds: 10
    }
  end

  defp monitor_count(org_id) do
    %{rows: [[count]]} =
      Alplus.Repo.query!("SELECT count(*) FROM monitors WHERE org_id = $1", [org_id])

    count
  end
end
