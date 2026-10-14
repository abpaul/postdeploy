defmodule Alplus.Monitoring.SchedulerBootTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.{HttpConfig, Monitor, Scheduler}
  alias Alplus.Scope

  # The test process owns the connection itself so it can flip the sandbox
  # between manual (database not answering) and shared (database back).
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Alplus.Repo)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Alplus.Repo, :manual) end)
    Alplus.DataCase.stub_external_clients()
    :ok
  end

  # Rehydration used to run inside `init/1`. An unreachable database then
  # failed application boot, or held every child declared after the scheduler
  # (Oban, PubSub, the endpoint) until the query returned. The scheduler must
  # start regardless and converge once the database answers.
  test "the scheduler starts with the monitors table unreadable and converges later" do
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
        url: "https://example.test/health",
        method: "GET",
        expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
        interval_seconds: 300,
        timeout_seconds: 10
      },
      action: :create,
      actor: scope
    )

    Phoenix.PubSub.subscribe(Alplus.PubSub, "monitor:scheduler")

    # In manual sandbox mode a process without an allowance cannot query,
    # which stands in for a database that is not answering at boot.
    {pid, log} =
      with_log(fn ->
        {:ok, pid} = Scheduler.start_link(name: :"#{__MODULE__}.Scheduler")
        assert_receive {:monitor_scheduler_rehydrated, ^pid}, 1_000
        pid
      end)

    assert Process.alive?(pid)
    assert log =~ "monitor scheduler rehydrate failed"
    assert [] = Registry.lookup(Alplus.Monitoring.Registry, monitor.id)

    # The database answers again: the next reconcile tick converges.
    Ecto.Adapters.SQL.Sandbox.mode(Alplus.Repo, {:shared, self()})
    send(pid, :reconcile_all)
    :sys.get_state(pid)

    assert [{worker, _}] = Registry.lookup(Alplus.Monitoring.Registry, monitor.id)
    DynamicSupervisor.terminate_child(Alplus.Monitoring.MonitorSupervisor, worker)
    GenServer.stop(pid)
  end

  test "the scheduler skips boot rehydration when disabled" do
    previous =
      Application.fetch_env(:alplus, :monitor_scheduler_boot_rehydrate_enabled?)

    Application.put_env(:alplus, :monitor_scheduler_boot_rehydrate_enabled?, false)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:alplus, :monitor_scheduler_boot_rehydrate_enabled?, value)

        :error ->
          Application.delete_env(:alplus, :monitor_scheduler_boot_rehydrate_enabled?)
      end
    end)

    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    scope = Scope.put_project(scope, project.id)

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "Deferred"},
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

    name = Module.concat(__MODULE__, DeferredScheduler)
    {:ok, pid} = Scheduler.start_link(name: name)

    on_exit(fn ->
      if Process.whereis(name), do: GenServer.stop(name)
    end)

    :sys.get_state(pid)

    assert [] = Registry.lookup(Alplus.Monitoring.Registry, monitor.id)
  end
end
