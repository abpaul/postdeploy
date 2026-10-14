defmodule Alplus.Monitoring.SchedulerLifecycleTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.{ActiveCheckOutcome, HttpConfig, Incident, Monitor, Scheduler}
  alias Alplus.Scope

  setup do
    previous = Application.get_env(:alplus, :monitor_scheduler_enabled?, true)
    Application.put_env(:alplus, :monitor_scheduler_enabled?, true)
    Ecto.Adapters.SQL.Sandbox.mode(Alplus.Repo, {:shared, self()})

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Alplus.Repo, :manual)
      Application.put_env(:alplus, :monitor_scheduler_enabled?, previous)
    end)

    :ok
  end

  test "scheduler restart rehydrates exactly one active worker with durable counters" do
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

    assert :ok = Scheduler.rehydrate()
    assert [{first_pid, _}] = Registry.lookup(Alplus.Monitoring.Registry, monitor.id)

    assert {:ok, %{incident_id: nil}} =
             ActiveCheckOutcome.record(monitor.id, %{
               status: "down",
               status_code: 503,
               latency_ms: 10,
               error_class: "unexpected_status"
             })

    assert :ok = Scheduler.stop_monitor(monitor.id)

    Phoenix.PubSub.subscribe(Alplus.PubSub, "monitor:scheduler")
    scheduler_pid = Process.whereis(Scheduler)
    scheduler_ref = Process.monitor(scheduler_pid)
    Process.exit(scheduler_pid, :kill)
    assert_receive {:DOWN, ^scheduler_ref, :process, ^scheduler_pid, :killed}
    assert_receive {:monitor_scheduler_rehydrated, rehydrated_scheduler_pid}

    assert is_pid(rehydrated_scheduler_pid)
    refute rehydrated_scheduler_pid == scheduler_pid

    assert [{second_pid, _}] = Registry.lookup(Alplus.Monitoring.Registry, monitor.id)
    refute first_pid == second_pid

    assert {:ok, %{incident_id: incident_id}} =
             ActiveCheckOutcome.record(monitor.id, %{
               status: "down",
               status_code: 503,
               latency_ms: 10,
               error_class: "unexpected_status"
             })

    assert is_binary(incident_id)

    incident = Ash.get!(Incident, incident_id, actor: scope)

    assert incident.cause_detail == %{
             "error_class" => "unexpected_status",
             "status_code" => 503
           }

    assert :ok = Scheduler.rehydrate()
    assert [{^second_pid, _}] = Registry.lookup(Alplus.Monitoring.Registry, monitor.id)
  end

  test "a recovering monitor resolves its open incident without crashing" do
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

    assert :ok = Scheduler.rehydrate()

    down = %{status: "down", status_code: 503, latency_ms: 10, error_class: "unexpected_status"}
    up = %{status: "up", status_code: 200, latency_ms: 10, error_class: nil}

    incident_id =
      Enum.reduce_while(1..5, nil, fn _, _acc ->
        {:ok, %{incident_id: id}} = ActiveCheckOutcome.record(monitor.id, down)
        if id, do: {:halt, id}, else: {:cont, nil}
      end)

    assert is_binary(incident_id)
    assert Ash.get!(Incident, incident_id, actor: scope).status == :open

    # Recovery reloads `started_at` through a raw query, which yields a
    # NaiveDateTime. `DateTime.diff/3` rejects a naive argument, so before the
    # coercion this crashed the worker. Reaching the recovery threshold must
    # resolve the incident cleanly.
    Enum.each(1..3, fn _ -> assert {:ok, _} = ActiveCheckOutcome.record(monitor.id, up) end)

    assert Ash.get!(Incident, incident_id, actor: scope).status == :resolved
  end

  # An active monitor whose registration never happened -- a transient
  # `reconcile_monitor/1` failure, a row written outside `MonitorCreator`, a
  # worker the supervisor could not restart -- used to sit there looking active
  # in the console while checking nothing, until the next container boot. The
  # scheduler converges on a timer, so the database's `status='active'` is what
  # decides, not whoever remembered to call.
  test "the reconcile tick starts an unregistered active monitor and stops an inactive one" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    scope = Scope.put_project(scope, project.id)

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "Ticked"},
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

    # Simulate the registration never landing.
    assert :ok = Scheduler.stop_monitor(monitor.id)
    assert [] == Registry.lookup(Alplus.Monitoring.Registry, monitor.id)

    send(Process.whereis(Scheduler), :reconcile_all)
    # A call flushes the mailbox, so the tick has been handled by the time this
    # returns.
    assert :ok = Scheduler.rehydrate()

    assert [{pid, _}] = Registry.lookup(Alplus.Monitoring.Registry, monitor.id)
    assert Process.alive?(pid)

    # And the other direction: a paused monitor must not keep checking.
    Alplus.Repo.query!("UPDATE monitors SET status = 'paused' WHERE id = $1", [monitor.id])

    send(Process.whereis(Scheduler), :reconcile_all)
    assert :ok = Scheduler.rehydrate()

    assert [] == Registry.lookup(Alplus.Monitoring.Registry, monitor.id)
  end
end
