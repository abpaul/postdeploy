defmodule Alplus.StatusIssue71Test do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  require Ash.Query

  alias Alplus.Audit.AuditLog
  alias Alplus.Monitoring.Monitor
  alias Alplus.Measure.PublicCache
  alias Alplus.PublicPages
  alias Alplus.Scope
  alias Alplus.Status

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    {:ok, page} =
      Status.create_page(scope, %{
        org_id: org.id,
        project_id: project.id,
        public_slug: "issue-71",
        title: "Issue 71"
      })

    {:ok, public_page} = PublicPages.get_for_project(scope, project.id)
    %{org: org, project: project, scope: scope, page: page, public_page: public_page}
  end

  test "a page cannot publish without a configured service", context do
    assert {:error, error} = Status.publish_page(context.scope, context.page)
    assert inspect(error) =~ "service"
  end

  test "a page cannot publish a service without a connected monitor", context do
    assert {:ok, _service} =
             Status.create_component(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               status_page_id: context.page.id,
               name: "API"
             })

    assert {:error, :service_required} = Status.publish_page(context.scope, context.page)
    assert {:error, :not_found} = Status.load_public(context.public_page.public_slug)
  end

  test "hiding the last monitor from a service returns a normal result", context do
    monitor = monitor_fixture(context, "API")

    assert :ok = Status.set_monitor_visibility(context.scope, context.page, monitor.id, true)
    assert :ok = Status.set_monitor_visibility(context.scope, context.page, monitor.id, false)
  end

  test "monitor failure creates a private customer incident draft", context do
    monitor = monitor_fixture(context, "API")

    assert {:ok, draft} =
             Status.create_incident_draft(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               status_page_id: context.page.id,
               monitor_id: monitor.id
             })

    assert Map.get(draft, :published_at) == nil
    assert Map.get(draft, :private?) == true
  end

  test "one incident can affect several services and resolve with its final update", context do
    first_monitor = monitor_fixture(context, "API")
    second_monitor = monitor_fixture(context, "Web")

    {:ok, first_service} =
      Status.create_service(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        name: "API",
        monitor_ids: [first_monitor.id]
      })

    {:ok, second_service} =
      Status.create_service(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        name: "Web",
        monitor_ids: [second_monitor.id]
      })

    {:ok, incident} =
      Status.create_incident(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        service_ids: [first_service.id, second_service.id],
        title: "Service disruption",
        body: "We are investigating.",
        stage: "identified"
      })

    assert Map.get(incident, :stage) == "identified"

    assert {:ok, resolved} =
             Status.publish_resolved_update(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               status_incident_id: incident.id,
               body: "The service is operating normally again."
             })

    assert Map.get(resolved, :status) == "closed"
  end

  test "public snapshot separates announcements and applies incident service state", context do
    monitor = monitor_fixture(context, "API")

    {:ok, service} =
      Status.create_service(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        name: "API",
        monitor_ids: [monitor.id]
      })

    {:ok, _page} = Status.publish_page(context.scope, context.page)

    {:ok, _announcement} =
      Status.publish_announcement(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        title: "Planned change",
        body: "We will update the service soon."
      })

    {:ok, _incident} =
      Status.create_incident(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        service_ids: [service.id],
        title: "API outage",
        body: "We are investigating.",
        next_update_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    assert [%{title: "Planned change"}] = snapshot.announcements
    assert [%{name: "API", status: :down}] = snapshot.services

    assert [%{affected_services: [%{name: "API"}], next_update_at: %DateTime{}}] =
             snapshot.incidents
  end

  test "existing services keep their order, public URL, publication, and incident history",
       context do
    first_monitor = monitor_fixture(context, "API monitor")
    second_monitor = monitor_fixture(context, "Web monitor")

    {:ok, first_service} =
      Status.create_service(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        name: "API",
        monitor_ids: [first_monitor.id]
      })

    {:ok, _second_service} =
      Status.create_service(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        name: "Web",
        monitor_ids: [second_monitor.id]
      })

    {:ok, published_page} = Status.publish_page(context.scope, context.page)

    {:ok, incident} =
      Status.create_incident(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        service_ids: [first_service.id],
        title: "API incident",
        body: "Investigating the API."
      })

    {:ok, _update} =
      Status.publish_incident_update(context.scope, %{
        status_incident_id: incident.id,
        body: "The API is recovering."
      })

    {:ok, _resolved} =
      Status.publish_resolved_update(context.scope, %{
        status_incident_id: incident.id,
        body: "The API recovered."
      })

    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    assert snapshot.page.id == published_page.id
    assert snapshot.public_page.public_slug == "issue-71"
    assert Enum.map(snapshot.services, &{&1.name, &1.position}) == [{"API", 0}, {"Web", 1}]

    assert [
             %{
               title: "API incident",
               body: "Investigating the API.",
               status: "closed",
               updates: updates
             }
           ] =
             snapshot.incidents

    assert Enum.map(updates, & &1.body) == ["The API is recovering.", "The API recovered."]
  end

  test "announcements expire and can be removed without an incident", context do
    monitor = monitor_fixture(context, "API monitor")

    {:ok, _service} =
      Status.create_service(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        name: "API",
        monitor_ids: [monitor.id]
      })

    {:ok, _page} = Status.publish_page(context.scope, context.page)

    {:ok, expiring} =
      Status.publish_announcement(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        title: "Expiring notice",
        body: "Temporary notice",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    expiring_id = expiring.id
    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    assert [%{id: ^expiring_id}] = snapshot.announcements

    now = DateTime.utc_now()

    Ash.Seed.update!(expiring, %{
      published_at: DateTime.add(now, -120, :second),
      expires_at: DateTime.add(now, -60, :second)
    })

    PublicCache.clear()

    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    assert snapshot.announcements == []

    {:ok, notice} =
      Status.publish_announcement(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        title: "Removable notice",
        body: "Remove this notice"
      })

    assert {:ok, unpublished} = Status.unpublish_announcement(context.scope, notice)
    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    assert snapshot.announcements == []

    # Unpublishing is reversible, so the notice can go back on the public page.
    assert {:ok, _republished} = Status.republish_announcement(context.scope, unpublished)
    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    assert Enum.map(snapshot.announcements, & &1.title) == ["Removable notice"]
  end

  test "incident targets clear only when explicitly blank and always clear on resolution",
       context do
    monitor = monitor_fixture(context, "API")

    {:ok, service} =
      Status.create_service(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        name: "API",
        monitor_ids: [monitor.id]
      })

    target = DateTime.add(DateTime.utc_now(), 3600, :second)

    {:ok, incident} =
      Status.create_incident(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        service_ids: [service.id],
        title: "API outage",
        body: "We are investigating.",
        next_update_at: target
      })

    assert {:ok, _update} =
             Status.publish_incident_update(context.scope, %{
               status_incident_id: incident.id,
               body: "Still investigating."
             })

    assert {:ok, current} = Ash.get(Status.StatusIncident, incident.id, actor: context.scope)
    assert DateTime.compare(current.next_update_at, target) == :eq

    assert {:ok, _update} =
             Status.publish_incident_update(context.scope, %{
               status_incident_id: incident.id,
               body: "The next update time is cleared.",
               next_update_at: ""
             })

    assert {:ok, current} = Ash.get(Status.StatusIncident, incident.id, actor: context.scope)
    assert is_nil(current.next_update_at)

    {:ok, resolving} =
      Status.create_incident(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        service_ids: [service.id],
        title: "Second outage",
        body: "We are investigating.",
        next_update_at: target
      })

    assert {:ok, resolved} = Status.resolve_incident(context.scope, resolving)
    assert resolved.status == "closed"
    assert is_nil(resolved.next_update_at)

    assert {:error, :incident_closed} =
             Status.change_incident_stage(context.scope, resolved, "monitoring")

    assert {:error, :incident_closed} =
             Status.update_incident(context.scope, resolved, %{stage: "monitoring"})
  end

  test "announcement and incident-draft mutations write audit rows", context do
    monitor = monitor_fixture(context, "API")

    {:ok, announcement} =
      Status.publish_announcement(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        title: "Planned change",
        body: "We will update the service soon."
      })

    {:ok, announcement} =
      Status.update_announcement(context.scope, announcement, %{body: "The update is complete."})

    assert {:ok, _unpublished} = Status.unpublish_announcement(context.scope, announcement)

    {:ok, draft} =
      Status.create_incident_draft(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        monitor_id: monitor.id
      })

    assert {:ok, _draft} =
             Status.save_incident_draft(context.scope, %{
               status_incident_id: draft.id,
               title: "Updated draft",
               body: "We are preparing the incident update."
             })

    assert :ok = Status.clear_incident_draft(context.scope, draft.id)

    actions =
      AuditLog
      |> Ash.Query.filter(org_id == ^context.org.id)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.action)

    assert "status_announcement.publish" in actions
    assert "status_announcement.update" in actions
    assert "status_announcement.unpublish" in actions
    assert "status_incident.draft" in actions
    assert "status_incident_draft.create" in actions
    assert "status_incident_draft.update" in actions
    assert "status_incident_draft.destroy" in actions
  end

  defp monitor_fixture(context, name) do
    Ash.create!(
      Monitor,
      %{org_id: context.org.id, project_id: context.project.id, type: "http", name: name},
      action: :create,
      actor: context.scope
    )
  end
end
