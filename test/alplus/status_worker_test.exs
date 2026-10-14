defmodule Alplus.StatusWorkerTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.Monitor
  alias Alplus.PublicPages
  alias Alplus.Status

  test "recovery publishes one public update and leaves the published incident open" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Alplus.Scope.put_project(owner_scope, project.id)
    monitor = monitor_fixture(scope, org, project)
    incident = open_incident(scope, org, project, monitor)

    {:ok, page} =
      Status.create_page(scope, %{
        org_id: org.id,
        project_id: project.id,
        public_slug: "worker-status",
        title: "Worker Status"
      })

    {:ok, component} =
      Status.create_component(scope, %{
        org_id: org.id,
        project_id: project.id,
        status_page_id: page.id,
        name: "API"
      })

    :ok = Status.link_monitor(scope, component, monitor.id)

    {:ok, _page} = Status.publish_page(scope, page)

    {:ok, status_incident} =
      Status.publish_incident(scope, %{
        org_id: org.id,
        project_id: project.id,
        status_page_id: page.id,
        incident_id: incident.id,
        title: "API outage",
        body: "We are investigating."
      })

    assert {:ok, snapshot} = Status.load_public(public_slug(scope, project.id))
    assert [%{status: "open", updates: []}] = snapshot.incidents

    resolved_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _resolved} =
             Ash.update(incident, %{resolved_at: resolved_at, duration_seconds: 60},
               action: :resolve,
               authorize?: false
             )

    assert :ok = Status.RecoveryWorker.run()
    assert :ok = Status.RecoveryWorker.run()

    assert {:ok, status_incident} =
             Ash.get(Status.StatusIncident, status_incident.id, authorize?: false)

    assert status_incident.status == "open"
    assert %DateTime{} = status_incident.recovery_posted_at

    status_incident_id = status_incident.id
    assert {:ok, snapshot} = Status.load_public(public_slug(scope, project.id))

    assert [
             %{
               id: ^status_incident_id,
               status: "open",
               updates: [%{kind: "recovery", body: body}]
             }
           ] = snapshot.incidents

    assert body =~ "Service recovered at"

    assert {:ok, nil} = Status.incident_draft(scope, status_incident.id)

    updates =
      Alplus.Repo.query!(
        "SELECT kind, body FROM status_incident_updates WHERE status_incident_id = $1",
        [status_incident.id]
      ).rows

    assert [["recovery", ^body]] = updates
  end

  test "recovery preserves an existing custom resolution draft" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Alplus.Scope.put_project(owner_scope, project.id)
    monitor = monitor_fixture(scope, org, project)
    incident = open_incident(scope, org, project, monitor)
    {_page, status_incident} = published_status_incident(scope, org, project, incident)

    assert {:ok, _resolved} =
             Ash.update(incident, %{resolved_at: DateTime.utc_now(), duration_seconds: 60},
               action: :resolve,
               authorize?: false
             )

    assert {:ok, _draft} =
             Status.save_incident_draft(scope, %{
               status_incident_id: status_incident.id,
               title: "Custom recovery",
               body: "We verified the fix and will close this incident after review."
             })

    assert :ok = Status.RecoveryWorker.run()
    assert :ok = Status.RecoveryWorker.run()
    assert {:ok, _page} = Status.resolve(public_slug(scope, project.id))

    assert {:ok, draft} = Status.incident_draft(scope, status_incident.id)
    assert draft.title == "Custom recovery"
    assert draft.body == "We verified the fix and will close this incident after review."

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM status_incident_updates WHERE status_incident_id = $1 AND kind = 'recovery'",
               [status_incident.id]
             )

    assert %{rows: [[recovery_posted_at]]} =
             Alplus.Repo.query!(
               "SELECT recovery_posted_at FROM status_incidents WHERE id = $1",
               [status_incident.id]
             )

    assert not is_nil(recovery_posted_at)
  end

  test "maintenance pauses monitors at start and resumes them at end" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Alplus.Scope.put_project(owner_scope, project.id)
    monitor = monitor_fixture(scope, org, project)

    {:ok, page} =
      Status.create_page(scope, %{
        org_id: org.id,
        project_id: project.id,
        public_slug: "maintenance-status",
        title: "Maintenance Status"
      })

    now = DateTime.utc_now()

    {:ok, maintenance} =
      Status.schedule_maintenance(
        scope,
        %{
          org_id: org.id,
          project_id: project.id,
          status_page_id: page.id,
          title: "Database work",
          starts_at: DateTime.add(now, -60, :second),
          ends_at: DateTime.add(now, 60, :second)
        },
        [monitor.id]
      )

    assert :ok = Status.MaintenanceWorker.run()
    assert {:ok, paused} = Ash.get(Monitor, monitor.id, authorize?: false)
    assert paused.status == "paused"

    # ScheduledMaintenance exposes transition actions, not a window-edit action.
    Ash.Seed.update!(maintenance, %{ends_at: DateTime.add(now, -1, :second)})

    assert :ok = Status.MaintenanceWorker.run()
    assert {:ok, active} = Ash.get(Monitor, monitor.id, authorize?: false)
    assert active.status == "active"

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM monitor_pause_intervals WHERE monitor_id = $1 AND resumed_at IS NOT NULL",
               [monitor.id]
             )
  end

  test "overlapping maintenance windows retain pause ownership until the last one ends" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Alplus.Scope.put_project(owner_scope, project.id)
    monitor = monitor_fixture(scope, org, project)

    {:ok, page} =
      Status.create_page(scope, %{
        org_id: org.id,
        project_id: project.id,
        public_slug: "maintenance-overlap",
        title: "Maintenance overlap"
      })

    now = DateTime.utc_now()

    {:ok, first} =
      Status.schedule_maintenance(
        scope,
        %{
          org_id: org.id,
          project_id: project.id,
          status_page_id: page.id,
          title: "First window",
          starts_at: DateTime.add(now, -60, :second),
          ends_at: DateTime.add(now, 3_600, :second)
        },
        [monitor.id]
      )

    assert :ok = Status.MaintenanceWorker.run()
    assert {:ok, %{status: "paused"}} = Ash.get(Monitor, monitor.id, authorize?: false)

    {:ok, second} =
      Status.schedule_maintenance(
        scope,
        %{
          org_id: org.id,
          project_id: project.id,
          status_page_id: page.id,
          title: "Second window",
          starts_at: DateTime.add(now, -30, :second),
          ends_at: DateTime.add(now, 7_200, :second)
        },
        [monitor.id]
      )

    assert :ok = Status.MaintenanceWorker.run()
    assert {:ok, %{status: "paused"}} = Ash.get(Monitor, monitor.id, authorize?: false)

    Ash.Seed.update!(first, %{ends_at: DateTime.add(now, -1, :second)})
    assert :ok = Status.MaintenanceWorker.run()

    assert {:ok, %{status: "paused"}} = Ash.get(Monitor, monitor.id, authorize?: false)

    assert %{rows: ownership_rows} =
             Alplus.Repo.query!(
               """
               SELECT maintenance_id, paused_by_maintenance
               FROM status_maintenance_monitors
               WHERE monitor_id = $1
               """,
               [monitor.id]
             )

    ownership = Map.new(ownership_rows, fn [maintenance_id, owned] -> {maintenance_id, owned} end)
    assert ownership == %{first.id => false, second.id => true}

    Ash.Seed.update!(second, %{ends_at: DateTime.add(now, -1, :second)})
    assert :ok = Status.MaintenanceWorker.run()
    assert {:ok, %{status: "active"}} = Ash.get(Monitor, monitor.id, authorize?: false)
  end

  test "cancelling a running window resumes the monitors it paused" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Alplus.Scope.put_project(owner_scope, project.id)
    monitor = monitor_fixture(scope, org, project)

    {:ok, page} =
      Status.create_page(scope, %{
        org_id: org.id,
        project_id: project.id,
        public_slug: "cancel-status",
        title: "Cancel Status"
      })

    now = DateTime.utc_now()

    {:ok, maintenance} =
      Status.schedule_maintenance(
        scope,
        %{
          org_id: org.id,
          project_id: project.id,
          status_page_id: page.id,
          title: "Database work",
          starts_at: DateTime.add(now, -60, :second),
          ends_at: DateTime.add(now, 3600, :second)
        },
        [monitor.id]
      )

    assert :ok = Status.MaintenanceWorker.run()
    assert {:ok, %{status: "paused"}} = Ash.get(Monitor, monitor.id, authorize?: false)

    # The window is still running, so its ends_at cannot self-exclude it from
    # the overlap check. Cancelling must still resume the monitor.
    assert {:ok, _cancelled} = Status.cancel_maintenance(scope, maintenance)
    assert {:ok, %{status: "active"}} = Ash.get(Monitor, monitor.id, authorize?: false)

    assert {:ok, %{status: "cancelled"}} =
             Ash.get(Alplus.Status.ScheduledMaintenance, maintenance.id, authorize?: false)

    # A cancelled window never transitions again.
    assert :ok = Status.MaintenanceWorker.run()
    assert {:ok, %{status: "active"}} = Ash.get(Monitor, monitor.id, authorize?: false)
  end

  test "cancelling a scheduled window keeps it off the public page" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Alplus.Scope.put_project(owner_scope, project.id)
    monitor = monitor_fixture(scope, org, project)

    {:ok, page} =
      Status.create_page(scope, %{
        org_id: org.id,
        project_id: project.id,
        public_slug: "cancel-scheduled",
        title: "Cancel Scheduled"
      })

    now = DateTime.utc_now()

    {:ok, maintenance} =
      Status.schedule_maintenance(
        scope,
        %{
          org_id: org.id,
          project_id: project.id,
          status_page_id: page.id,
          title: "Later work",
          starts_at: DateTime.add(now, 3600, :second),
          ends_at: DateTime.add(now, 7200, :second)
        },
        [monitor.id]
      )

    assert {:ok, _cancelled} = Status.cancel_maintenance(scope, maintenance)

    # Cancelling twice must not run the resume path again.
    assert {:error, :maintenance_not_cancellable} =
             Status.cancel_maintenance(scope, maintenance)

    assert :ok = Status.MaintenanceWorker.run()
    assert {:ok, %{status: "active"}} = Ash.get(Monitor, monitor.id, authorize?: false)
  end

  test "maintenance preserves monitors that were already paused" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Alplus.Scope.put_project(owner_scope, project.id)
    monitor = monitor_fixture(scope, org, project)
    {:ok, monitor} = Ash.update(monitor, %{status: "paused"}, action: :update, authorize?: false)

    {:ok, page} =
      Status.create_page(scope, %{
        org_id: org.id,
        project_id: project.id,
        public_slug: "already-paused",
        title: "Already paused"
      })

    now = DateTime.utc_now()

    {:ok, maintenance} =
      Status.schedule_maintenance(
        scope,
        %{
          org_id: org.id,
          project_id: project.id,
          status_page_id: page.id,
          title: "Database work",
          starts_at: DateTime.add(now, -60, :second),
          ends_at: DateTime.add(now, 60, :second)
        },
        [monitor.id]
      )

    assert :ok = Status.MaintenanceWorker.run()
    assert {:ok, still_paused} = Ash.get(Monitor, monitor.id, authorize?: false)
    assert still_paused.status == "paused"

    # ScheduledMaintenance exposes transition actions, not a window-edit action.
    Ash.Seed.update!(maintenance, %{ends_at: DateTime.add(now, -1, :second)})

    assert :ok = Status.MaintenanceWorker.run()
    assert {:ok, still_paused} = Ash.get(Monitor, monitor.id, authorize?: false)
    assert still_paused.status == "paused"
  end

  test "maintenance failure leaves the window scheduled for retry" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Alplus.Scope.put_project(owner_scope, project.id)
    monitor = monitor_fixture(scope, org, project)

    {:ok, page} =
      Status.create_page(scope, %{
        org_id: org.id,
        project_id: project.id,
        public_slug: "maintenance-retry",
        title: "Maintenance retry"
      })

    now = DateTime.utc_now()

    {:ok, maintenance} =
      Status.schedule_maintenance(
        scope,
        %{
          org_id: org.id,
          project_id: project.id,
          status_page_id: page.id,
          title: "Database work",
          starts_at: DateTime.add(now, -60, :second),
          ends_at: DateTime.add(now, 3_600, :second)
        },
        [monitor.id]
      )

    # Trial expiry is server-owned and has no writable domain action.
    Ash.Seed.update!(org, %{trial_ends_at: DateTime.add(now, -60, :second)})

    assert {:error, _reason} = Status.MaintenanceWorker.run()

    assert %{rows: [["scheduled"]]} =
             Alplus.Repo.query!(
               "SELECT status FROM status_scheduled_maintenances WHERE id = $1",
               [maintenance.id]
             )

    assert {:ok, still_active} = Ash.get(Monitor, monitor.id, authorize?: false)
    assert still_active.status == "active"
  end

  defp monitor_fixture(scope, org, project) do
    Ash.create!(
      Monitor,
      %{org_id: org.id, project_id: project.id, type: "http", name: "API"},
      action: :create,
      actor: scope
    )
  end

  defp open_incident(scope, org, project, monitor) do
    Ash.create!(
      Alplus.Monitoring.Incident,
      %{
        org_id: org.id,
        project_id: project.id,
        monitor_id: monitor.id,
        cause: "availability",
        cause_detail: %{},
        started_at: DateTime.utc_now(),
        checks_failed_count: 2
      },
      action: :open,
      actor: scope,
      authorize?: false
    )
  end

  defp published_status_incident(scope, org, project, incident) do
    {:ok, page} =
      Status.create_page(scope, %{
        org_id: org.id,
        project_id: project.id,
        public_slug: "recovery-repair",
        title: "Recovery repair"
      })

    {:ok, component} =
      Status.create_component(scope, %{
        org_id: org.id,
        project_id: project.id,
        status_page_id: page.id,
        name: "API"
      })

    :ok = Status.link_monitor(scope, component, incident.monitor_id)

    {:ok, page} = Status.publish_page(scope, page)

    {:ok, status_incident} =
      Status.publish_incident(scope, %{
        org_id: org.id,
        project_id: project.id,
        status_page_id: page.id,
        incident_id: incident.id,
        title: "API outage",
        body: "We are investigating."
      })

    {page, status_incident}
  end

  defp public_slug(scope, project_id) do
    {:ok, public_page} = PublicPages.get_for_project(scope, project_id)
    public_page.public_slug
  end
end
