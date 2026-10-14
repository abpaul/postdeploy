defmodule Alplus.Monitoring.MonitorWorkerTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.{HttpConfig, Monitor, MonitorWorker}
  alias Alplus.Scope

  setup do
    previous = Application.get_env(:alplus, :monitor_scheduler_enabled?, true)
    Application.put_env(:alplus, :monitor_scheduler_enabled?, true)
    Ecto.Adapters.SQL.Sandbox.mode(Alplus.Repo, {:shared, self()})
    on_exit(fn -> Application.put_env(:alplus, :monitor_scheduler_enabled?, previous) end)
    :ok
  end

  test "run_now executes an http check and a paused monitor is ignored" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    scope = Scope.put_project(scope, project.id)

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "API"},
        action: :create,
        actor: scope
      )

    Ash.create!(
      HttpConfig,
      %{
        monitor_id: monitor.id,
        org_id: org.id,
        url: "http://127.0.0.1:1/",
        method: "GET",
        expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
        interval_seconds: 300,
        timeout_seconds: 1
      },
      action: :create,
      actor: scope
    )

    assert {:ok, _pid} = MonitorWorker.start_link(monitor.id)
    assert :ok = MonitorWorker.run_now(monitor.id)

    paused =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "Paused"},
        action: :create,
        actor: scope
      )

    paused = Ash.update!(paused, %{status: "paused"}, action: :update, actor: scope)
    assert :ignore = MonitorWorker.start_link(paused.id)
  end

  test "an expired trial does not start an external-check worker" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    scope = Scope.put_project(scope, project.id)

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "Expired"},
        action: :create,
        actor: scope
      )

    Ash.create!(
      HttpConfig,
      %{
        monitor_id: monitor.id,
        org_id: org.id,
        url: "https://example.test/health",
        method: "GET",
        expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
        interval_seconds: 300,
        timeout_seconds: 10
      },
      action: :create,
      actor: scope
    )

    Alplus.Repo.query!("UPDATE organizations SET trial_ends_at = $1 WHERE id = $2", [
      ~U[2000-01-01 00:00:00.000000Z],
      org.id
    ])

    assert :ignore = MonitorWorker.start_link(monitor.id)

    assert [[0]] =
             Alplus.Repo.query!("SELECT count(*) FROM monitor_checks WHERE org_id = $1", [org.id]).rows
  end

  # The default 5s `GenServer.call` timeout exited the caller while the worker
  # was still inside a check bounded by the monitor's own `timeout_seconds`.
  # The injected request sleeps past that default, so this test is
  # wall-clock bound at about six seconds.
  test "run_now waits when a scheduled check already owns the worker" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    scope = Scope.put_project(scope, project.id)
    test_pid = self()

    Application.put_env(:alplus, :monitor_check_opts,
      resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end,
      request: fn _request ->
        send(test_pid, :slow_request_started)
        Process.sleep(6_000)
        {:error, %Req.TransportError{reason: :timeout}}
      end
    )

    on_exit(fn -> Application.delete_env(:alplus, :monitor_check_opts) end)

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "Slow"},
        action: :create,
        actor: scope
      )

    Ash.create!(
      HttpConfig,
      %{
        monitor_id: monitor.id,
        org_id: org.id,
        url: "https://slow.example.test/health",
        method: "GET",
        expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
        interval_seconds: 300,
        timeout_seconds: 10
      },
      action: :create,
      actor: scope
    )

    assert {:ok, pid} = MonitorWorker.start_link(monitor.id)

    send(pid, :check)
    assert_receive :slow_request_started
    assert :ok = MonitorWorker.run_now(monitor.id)

    rows =
      Alplus.Repo.query!(
        "SELECT status, error_class FROM monitor_checks WHERE monitor_id = $1",
        [monitor.id]
      ).rows

    assert length(rows) >= 2
    assert Enum.all?(rows, &(&1 == ["down", "network_error"]))
  end
end
