defmodule Alplus.StatusServiceOverviewTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.Monitor
  alias Alplus.Repo
  alias Alplus.Scope
  alias Alplus.Status
  alias Alplus.Status.{MaintenanceMonitor, StatusComponentMonitor}

  setup do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    public_slug = "overview-#{System.unique_integer([:positive])}"

    {:ok, page} =
      Status.create_page(scope, %{
        org_id: org.id,
        project_id: project.id,
        public_slug: public_slug,
        title: "Overview"
      })

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

    {:ok, service} =
      Status.create_service(scope, %{
        org_id: org.id,
        project_id: project.id,
        status_page_id: page.id,
        name: "API",
        description: "Public API gateway",
        monitor_ids: [monitor.id]
      })

    {:ok,
     owner: owner,
     org: org,
     owner_scope: owner_scope,
     project: project,
     scope: scope,
     page: page,
     public_slug: public_slug,
     monitor: monitor,
     service: service}
  end

  test "composes monitor observations and only exposes an unambiguous objective", context do
    Ash.Seed.update!(context.monitor, %{last_known_status: "up"})

    assert {:ok, [service]} =
             Status.service_overview(context.scope, context.page, reliability?: true)

    assert service.id == context.service.id
    assert service.description == "Public API gateway"
    assert service.state == :operational
    assert service.monitor_ids == [context.monitor.id]
    assert [%{id: monitor_id}] = service.monitors
    assert monitor_id == context.monitor.id
    assert service.reliability.target == 0.999
    assert length(service.reliability.days) == 90

    second_monitor =
      Ash.create!(
        Monitor,
        %{
          org_id: context.org.id,
          project_id: context.project.id,
          type: "http",
          name: "Worker"
        },
        action: :create,
        actor: context.scope
      )

    Ash.Seed.update!(second_monitor, %{last_known_status: "up"})

    assert :ok =
             Status.connect_service_monitors(
               context.scope,
               context.service,
               [context.monitor.id, second_monitor.id]
             )

    assert {:ok, service} =
             Status.service(context.scope, context.page, context.service.id, reliability?: true)

    assert service.state == :operational
    assert length(service.monitors) == 2
    assert is_nil(service.reliability)

    assert {:ok, _empty_service} =
             Status.create_service(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               status_page_id: context.page.id,
               name: "Background jobs",
               monitor_ids: []
             })

    assert {:ok, [_service, empty_service]} =
             Status.service_overview(context.scope, context.page)

    assert empty_service.state == :degraded
    assert empty_service.monitors == []
  end

  test "a paused monitor remains degraded outside an active maintenance window", context do
    Ash.Seed.update!(context.monitor, %{status: "paused", last_known_status: "up"})

    assert {:ok, [service]} = Status.service_overview(context.scope, context.page)
    assert service.state == :degraded
  end

  test "public service output includes the customer-facing description", context do
    Ash.Seed.update!(context.monitor, %{last_known_status: "up"})
    assert {:ok, _page} = Status.publish_page(context.scope, context.page)
    assert {:ok, snapshot} = Status.load_public(context.public_slug)
    assert [%{name: "API", description: "Public API gateway"}] = snapshot.services
  end

  test "maintenance and published incidents take precedence over observations", context do
    Ash.Seed.update!(context.monitor, %{last_known_status: "up"})
    now = DateTime.utc_now()

    assert {:ok, _maintenance} =
             Status.schedule_maintenance(
               context.scope,
               %{
                 status_page_id: context.page.id,
                 title: "API maintenance",
                 starts_at: DateTime.add(now, -60, :second),
                 ends_at: DateTime.add(now, 60, :second)
               },
               [context.monitor.id]
             )

    assert {:ok, [service]} = Status.service_overview(context.scope, context.page)
    assert service.state == :maintenance

    assert {:ok, incident} =
             Status.publish_incident(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               status_page_id: context.page.id,
               service_ids: [context.service.id],
               service_states: %{context.service.id => "outage"},
               title: "API outage",
               body: "We are investigating."
             })

    assert {:ok, [service]} = Status.service_overview(context.scope, context.page)
    assert service.state == :down

    assert {:ok, _resolved} = Status.resolve_incident(context.scope, incident)
    assert {:ok, [service]} = Status.service_overview(context.scope, context.page)
    assert service.state == :maintenance
  end

  test "service and incident reads are project scoped and members cannot mutate them", context do
    member = user_fixture()

    member_scope =
      member_fixture(context.owner_scope, context.org, member)
      |> Scope.put_project(context.project.id)

    assert {:ok, _service} =
             Status.service(member_scope, context.page, context.service.id)

    assert {:error, _reason} =
             Status.update_service(member_scope, context.service, %{name: "Renamed"})

    assert {:error, _reason} =
             Status.publish_incident(member_scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               status_page_id: context.page.id,
               service_ids: [context.service.id],
               title: "Unauthorized outage",
               body: "This must not publish."
             })

    {other_org, other_owner_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_owner_scope, other_org)
    other_scope = Scope.put_project(other_owner_scope, other_project.id)

    {:ok, other_page} =
      Status.create_page(other_scope, %{
        org_id: other_org.id,
        project_id: other_project.id,
        public_slug: "other-overview-#{System.unique_integer([:positive])}",
        title: "Other overview"
      })

    {:ok, other_service} =
      Status.create_service(other_scope, %{
        org_id: other_org.id,
        project_id: other_project.id,
        status_page_id: other_page.id,
        name: "Other API",
        monitor_ids: []
      })

    assert {:error, :not_found} =
             Status.service(context.scope, context.page, other_service.id)

    assert {:error, :not_found} =
             Status.service_overview(context.scope, other_page)
  end

  test "cross-tenant monitor links return not found and preserve scoped links", context do
    {other_org, other_owner_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_owner_scope, other_org)
    other_scope = Scope.put_project(other_owner_scope, other_project.id)

    other_org_monitor =
      Ash.create!(
        Monitor,
        %{org_id: other_org.id, project_id: other_project.id, type: "http", name: "Other org"},
        action: :create,
        actor: other_scope
      )

    sibling_project = project_fixture(context.owner_scope, context.org)
    sibling_scope = Scope.put_project(context.owner_scope, sibling_project.id)

    sibling_monitor =
      Ash.create!(
        Monitor,
        %{
          org_id: context.org.id,
          project_id: sibling_project.id,
          type: "http",
          name: "Sibling project"
        },
        action: :create,
        actor: sibling_scope
      )

    assert {:error, :not_found} =
             Status.connect_service_monitors(context.scope, context.service, [
               other_org_monitor.id
             ])

    assert {:error, :not_found} =
             Status.connect_service_monitors(context.scope, context.service, [sibling_monitor.id])

    assert {:ok, service} = Status.service(context.scope, context.page, context.service.id)
    assert service.monitor_ids == [context.monitor.id]
  end

  test "members cannot link or unlink Status monitor relationships", context do
    member_scope =
      member_fixture(context.owner_scope, context.org, user_fixture())
      |> Scope.put_project(context.project.id)

    replacement_monitor =
      Ash.create!(
        Monitor,
        %{
          org_id: context.org.id,
          project_id: context.project.id,
          type: "http",
          name: "Replacement"
        },
        action: :create,
        actor: context.scope
      )

    component_link_attrs = %{
      status_component_id: context.service.id,
      monitor_id: replacement_monitor.id,
      org_id: context.org.id,
      project_id: context.project.id
    }

    assert {:error, _} =
             Ash.create(StatusComponentMonitor, component_link_attrs,
               action: :link,
               actor: member_scope
             )

    assert {:ok, [component_link]} = Ash.read(StatusComponentMonitor, actor: context.scope)
    assert component_link.monitor_id == context.monitor.id
    assert {:error, _} = Ash.destroy(component_link, action: :unlink, actor: member_scope)

    assert {:ok, service} = Status.service(context.scope, context.page, context.service.id)
    assert service.monitor_ids == [context.monitor.id]

    now = DateTime.utc_now()

    assert {:ok, maintenance} =
             Status.schedule_maintenance(
               context.scope,
               maintenance_attrs(context.page.id, "Member denial", now),
               [context.monitor.id]
             )

    assert {:error, _} =
             Ash.create(
               MaintenanceMonitor,
               %{
                 maintenance_id: maintenance.id,
                 monitor_id: context.monitor.id,
                 org_id: context.org.id,
                 project_id: context.project.id
               },
               action: :link,
               actor: member_scope
             )

    assert {:ok, [maintenance_link]} = Ash.read(MaintenanceMonitor, actor: context.scope)

    assert maintenance_link.maintenance_id == maintenance.id
    assert {:error, _} = Ash.destroy(maintenance_link, action: :unlink, actor: member_scope)

    assert {:ok, [still_linked]} = Ash.read(MaintenanceMonitor, actor: context.scope)
    assert still_linked.maintenance_id == maintenance.id
  end

  test "component-monitor reads filter links from another project", context do
    sibling_project = project_fixture(context.owner_scope, context.org)
    sibling_scope = Scope.put_project(context.owner_scope, sibling_project.id)

    {:ok, sibling_page} =
      Status.create_page(sibling_scope, %{
        org_id: context.org.id,
        project_id: sibling_project.id,
        public_slug: "sibling-links-#{System.unique_integer([:positive])}",
        title: "Sibling links"
      })

    sibling_monitor =
      Ash.create!(
        Monitor,
        %{
          org_id: context.org.id,
          project_id: sibling_project.id,
          type: "http",
          name: "Sibling"
        },
        action: :create,
        actor: sibling_scope
      )

    {:ok, sibling_service} =
      Status.create_service(sibling_scope, %{
        org_id: context.org.id,
        project_id: sibling_project.id,
        status_page_id: sibling_page.id,
        name: "Sibling",
        monitor_ids: [sibling_monitor.id]
      })

    assert {:ok, links} = Ash.read(StatusComponentMonitor, actor: context.scope)
    assert Enum.any?(links, &(&1.status_component_id == context.service.id))
    refute Enum.any?(links, &(&1.status_component_id == sibling_service.id))

    now = DateTime.utc_now()

    assert {:ok, current_maintenance} =
             Status.schedule_maintenance(
               context.scope,
               maintenance_attrs(context.page.id, "Current maintenance", now),
               [context.monitor.id]
             )

    assert {:ok, sibling_maintenance} =
             Status.schedule_maintenance(
               sibling_scope,
               maintenance_attrs(sibling_page.id, "Sibling maintenance", now),
               [sibling_monitor.id]
             )

    assert {:ok, maintenance_links} = Ash.read(MaintenanceMonitor, actor: context.scope)
    assert Enum.any?(maintenance_links, &(&1.maintenance_id == current_maintenance.id))
    refute Enum.any?(maintenance_links, &(&1.maintenance_id == sibling_maintenance.id))
  end

  test "cross-tenant maintenance links return not found and create no window", context do
    {other_org, other_owner_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_owner_scope, other_org)
    other_scope = Scope.put_project(other_owner_scope, other_project.id)

    other_monitor =
      Ash.create!(
        Monitor,
        %{
          org_id: other_org.id,
          project_id: other_project.id,
          type: "http",
          name: "Other monitor"
        },
        action: :create,
        actor: other_scope
      )

    sibling_project = project_fixture(context.owner_scope, context.org)
    sibling_scope = Scope.put_project(context.owner_scope, sibling_project.id)

    sibling_monitor =
      Ash.create!(
        Monitor,
        %{
          org_id: context.org.id,
          project_id: sibling_project.id,
          type: "http",
          name: "Sibling maintenance"
        },
        action: :create,
        actor: sibling_scope
      )

    now = DateTime.utc_now()

    assert {:error, :not_found} =
             Status.schedule_maintenance(
               context.scope,
               %{
                 status_page_id: context.page.id,
                 title: "Cross tenant maintenance",
                 starts_at: DateTime.add(now, 60, :second),
                 ends_at: DateTime.add(now, 120, :second)
               },
               [other_monitor.id]
             )

    assert {:error, :not_found} =
             Status.schedule_maintenance(
               context.scope,
               %{
                 status_page_id: context.page.id,
                 title: "Cross project maintenance",
                 starts_at: DateTime.add(now, 60, :second),
                 ends_at: DateTime.add(now, 120, :second)
               },
               [sibling_monitor.id]
             )

    assert {:ok, []} = Status.list_maintenances(context.scope, context.page)
  end

  test "database relationship constraints reject mismatched tenants", context do
    {other_org, other_owner_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_owner_scope, other_org)
    other_scope = Scope.put_project(other_owner_scope, other_project.id)

    other_monitor =
      Ash.create!(
        Monitor,
        %{org_id: other_org.id, project_id: other_project.id, type: "http", name: "Other"},
        action: :create,
        actor: other_scope
      )

    {:ok, other_page} =
      Status.create_page(other_scope, %{
        org_id: other_org.id,
        project_id: other_project.id,
        public_slug: "constraint-#{System.unique_integer([:positive])}",
        title: "Other"
      })

    {:ok, other_service} =
      Status.create_service(other_scope, %{
        org_id: other_org.id,
        project_id: other_project.id,
        status_page_id: other_page.id,
        name: "Other",
        monitor_ids: []
      })

    now = DateTime.utc_now()

    {:ok, maintenance} =
      Status.schedule_maintenance(
        context.scope,
        maintenance_attrs(context.page.id, "Current", now),
        [context.monitor.id]
      )

    {:ok, other_maintenance} =
      Status.schedule_maintenance(
        other_scope,
        maintenance_attrs(other_page.id, "Other", now),
        [other_monitor.id]
      )

    assert_tenant_constraint(
      "INSERT INTO status_component_monitors (status_component_id, monitor_id, org_id, project_id) VALUES ($1, $2, $3, $4)",
      [context.service.id, other_monitor.id, context.org.id, context.project.id],
      "status_component_monitors_monitor_tenant_fkey"
    )

    assert_tenant_constraint(
      "INSERT INTO status_component_monitors (status_component_id, monitor_id, org_id, project_id) VALUES ($1, $2, $3, $4)",
      [other_service.id, context.monitor.id, context.org.id, context.project.id],
      "status_component_monitors_component_tenant_fkey"
    )

    assert_tenant_constraint(
      "INSERT INTO status_maintenance_monitors (maintenance_id, monitor_id, org_id, project_id) VALUES ($1, $2, $3, $4)",
      [maintenance.id, other_monitor.id, context.org.id, context.project.id],
      "status_maintenance_monitors_monitor_tenant_fkey"
    )

    assert_tenant_constraint(
      "INSERT INTO status_maintenance_monitors (maintenance_id, monitor_id, org_id, project_id) VALUES ($1, $2, $3, $4)",
      [other_maintenance.id, context.monitor.id, context.org.id, context.project.id],
      "status_maintenance_monitors_maintenance_tenant_fkey"
    )
  end

  test "parent deletion cascades Status relationship rows", context do
    assert :ok = Status.delete_service(context.scope, context.service)

    assert relationship_count(
             "status_component_monitors",
             "status_component_id",
             context.service.id
           ) == 0

    monitor_component =
      Ash.create!(
        Monitor,
        %{
          org_id: context.org.id,
          project_id: context.project.id,
          type: "http",
          name: "Monitor parent"
        },
        action: :create,
        actor: context.scope
      )

    {:ok, monitor_service} =
      Status.create_service(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        name: "Monitor parent",
        monitor_ids: [monitor_component.id]
      })

    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               "DELETE FROM monitors WHERE id = $1 AND org_id = $2 AND project_id = $3",
               [monitor_component.id, context.org.id, context.project.id]
             )

    assert relationship_count(
             "status_component_monitors",
             "status_component_id",
             monitor_service.id
           ) ==
             0

    maintenance_monitor_parent =
      Ash.create!(
        Monitor,
        %{
          org_id: context.org.id,
          project_id: context.project.id,
          type: "http",
          name: "Maintenance monitor parent"
        },
        action: :create,
        actor: context.scope
      )

    now = DateTime.utc_now()

    {:ok, monitor_maintenance} =
      Status.schedule_maintenance(
        context.scope,
        maintenance_attrs(context.page.id, "Monitor cascade", now),
        [maintenance_monitor_parent.id]
      )

    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               "DELETE FROM monitors WHERE id = $1 AND org_id = $2 AND project_id = $3",
               [maintenance_monitor_parent.id, context.org.id, context.project.id]
             )

    assert relationship_count(
             "status_maintenance_monitors",
             "maintenance_id",
             monitor_maintenance.id
           ) == 0

    maintenance_monitor =
      Ash.create!(
        Monitor,
        %{
          org_id: context.org.id,
          project_id: context.project.id,
          type: "http",
          name: "Maintenance parent"
        },
        action: :create,
        actor: context.scope
      )

    {:ok, maintenance} =
      Status.schedule_maintenance(
        context.scope,
        maintenance_attrs(context.page.id, "Cascade", now),
        [maintenance_monitor.id]
      )

    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               "DELETE FROM status_scheduled_maintenances WHERE id = $1 AND org_id = $2 AND project_id = $3",
               [maintenance.id, context.org.id, context.project.id]
             )

    assert relationship_count("status_maintenance_monitors", "maintenance_id", maintenance.id) ==
             0
  end

  test "members cannot read private incidents by guessed id or operator listing", context do
    assert {:ok, private_incident} =
             Status.create_incident_draft(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               status_page_id: context.page.id,
               monitor_id: context.monitor.id
             })

    member = user_fixture()

    member_scope =
      member_fixture(context.owner_scope, context.org, member)
      |> Scope.put_project(context.project.id)

    assert {:error, :not_found} =
             Status.incident_overview(member_scope, private_incident.id)

    assert {:ok, incidents} =
             Status.list_incidents(member_scope, context.page.id, operator?: true)

    refute Enum.any?(incidents, &(&1.id == private_incident.id))
  end

  defp maintenance_attrs(page_id, title, now) do
    %{
      status_page_id: page_id,
      title: title,
      starts_at: DateTime.add(now, 60, :second),
      ends_at: DateTime.add(now, 120, :second)
    }
  end

  defp assert_tenant_constraint(sql, params, constraint) do
    assert {:error, %Postgrex.Error{postgres: %{constraint: ^constraint}}} =
             Repo.query(sql, params)
  end

  defp relationship_count(table, column, id) do
    {:ok, %{rows: [[count]]}} =
      Repo.query("SELECT count(*) FROM #{table} WHERE #{column} = $1", [id])

    count
  end
end
