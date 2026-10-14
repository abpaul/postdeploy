defmodule Alplus.Monitoring.MonitorCreatorTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Billing.EntitlementError
  alias Alplus.Monitoring.{Monitor, MonitorCreator}
  alias Alplus.Scope

  test "creating a monitor reconciles the scheduler without crashing the caller" do
    previous = Application.get_env(:alplus, :monitor_scheduler_enabled?, true)
    Application.put_env(:alplus, :monitor_scheduler_enabled?, true)
    Ecto.Adapters.SQL.Sandbox.mode(Alplus.Repo, {:shared, self()})
    on_exit(fn -> Application.put_env(:alplus, :monitor_scheduler_enabled?, previous) end)

    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    assert {:ok, %{monitor: monitor}} =
             MonitorCreator.create(monitor_attrs(org, project), http_config(), scope)

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM monitors WHERE id = $1",
               [monitor.id]
             )

    assert [{_pid, _}] = Registry.lookup(Alplus.Monitoring.Registry, monitor.id)
  end

  test "creating a heartbeat monitor starts no checking worker" do
    previous = Application.get_env(:alplus, :monitor_scheduler_enabled?, true)
    Application.put_env(:alplus, :monitor_scheduler_enabled?, true)
    Ecto.Adapters.SQL.Sandbox.mode(Alplus.Repo, {:shared, self()})
    on_exit(fn -> Application.put_env(:alplus, :monitor_scheduler_enabled?, previous) end)

    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    # A heartbeat waits for the customer's ping. Asking the scheduler for a
    # checking worker made the worker crash on a check configuration that
    # cannot exist, and the crash reached the error tracker on every create.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{monitor: monitor}} =
                 MonitorCreator.create(
                   %{monitor_attrs(org, project) | type: "heartbeat", name: "Nightly backup"},
                   %{interval_seconds: 300, grace_period_seconds: 60},
                   scope
                 )

        assert [] = Registry.lookup(Alplus.Monitoring.Registry, monitor.id)
      end)

    refute log =~ "Failed to reconcile scheduler"
  end

  test "the monitor creation boundary enforces the plan interval floor before persistence" do
    {org, owner_scope} = org_fixture(scope_fixture())
    subscribed_fixture(org)
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    assert {:error, %EntitlementError{code: :interval_not_allowed}} =
             MonitorCreator.create(
               monitor_attrs(org, project),
               http_config(interval_seconds: 30),
               scope
             )

    assert %{rows: [[0]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM monitors WHERE org_id = $1 AND project_id = $2",
               [org.id, project.id]
             )
  end

  test "the monitor creation boundary enforces organisation-wide plan capacity" do
    {org, owner_scope} = org_fixture(scope_fixture())
    subscribed_fixture(org)
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    limit = Alplus.Billing.Package.limit(:uptime_monitors)

    # Seed rows directly: the count is what matters, not a running check each.
    for number <- 1..limit do
      Ash.Seed.seed!(Monitor, Map.put(monitor_attrs(org, project), :name, "Existing #{number}"))
    end

    assert {:error, %Ash.Error.Invalid{}} =
             Alplus.Monitoring.create_monitor(
               Map.put(monitor_attrs(org, project), :name, "Raw domain bypass"),
               actor: scope
             )

    assert {:error,
            %EntitlementError{
              code: :monitor_limit_reached,
              details: %{metric: :uptime_monitors, current: ^limit, limit: ^limit}
            }} = MonitorCreator.create(monitor_attrs(org, project), http_config(), scope)
  end

  defp monitor_attrs(org, project) do
    %{
      org_id: org.id,
      project_id: project.id,
      type: "http",
      name: "API"
    }
  end

  defp http_config(overrides \\ []) do
    %{
      url: "https://example.test/health",
      method: "GET",
      expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
      interval_seconds: 300,
      timeout_seconds: 10
    }
    |> Map.merge(Map.new(overrides))
  end
end
