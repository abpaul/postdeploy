defmodule AlplusWeb.StatusIssue118Test do
  use AlplusWeb.ConnCase, async: false

  import Alplus.AuditFixtures
  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.Monitor
  alias Alplus.Scope
  alias Alplus.Status

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp page_path(org, project, _page),
    do: ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/public/status"

  setup %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    scope = Scope.put_project(owner_scope, project.id)

    {:ok, page} =
      Status.create_page(scope, %{
        org_id: org.id,
        project_id: project.id,
        public_slug: "issue-118-#{System.unique_integer([:positive])}",
        title: "Issue 118"
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
     conn: conn,
     owner: owner,
     org: org,
     project: project,
     scope: scope,
     page: page,
     monitor: monitor,
     service: service}
  end

  test "overview, service composition, and objective evidence are visible", context do
    Ash.Seed.update!(context.monitor, %{last_known_status: "up"})
    path = page_path(context.org, context.project, context.page)

    {:ok, overview, _html} =
      context.conn
      |> log_in(context.owner)
      |> live(path <> "/services")

    # One banner states what customers see; the counts ride under it as
    # evidence rather than in a second band that repeats the same verdict.
    assert has_element?(overview, "#status-overview-health")
    assert has_element?(overview, "#status-overview-public-state", "All systems operational")
    refute has_element?(overview, "#status-overview-summary")
    assert has_element?(overview, "#status-overview-monitors", "1")
    assert has_element?(overview, "#status-overview-services", "1")
    assert has_element?(overview, "#status-services-workspace", "Public API gateway")

    {:ok, service_view, _html} =
      context.conn
      |> log_in(context.owner)
      |> live(path <> "/services/#{context.service.id}")

    assert has_element?(service_view, "#status-service-composition")
    assert has_element?(service_view, "#status-service-monitor-#{context.monitor.id}", "API")
    assert has_element?(service_view, "#status-service-reliability")
    assert has_element?(service_view, "#status-service-reliability-days")

    {:ok, empty_service} =
      Status.create_service(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        name: "Background jobs",
        monitor_ids: []
      })

    {:ok, empty_view, _html} =
      context.conn
      |> log_in(context.owner)
      |> live(path <> "/services/#{empty_service.id}")

    assert has_element?(empty_view, "#status-service-reliability-absent")
  end

  test "incident detail distinguishes machine observation from customer narrative", context do
    observed_incident =
      Ash.create!(
        Alplus.Monitoring.Incident,
        %{
          org_id: context.org.id,
          project_id: context.project.id,
          monitor_id: context.monitor.id,
          cause: "availability",
          cause_detail: %{},
          started_at: DateTime.utc_now(),
          checks_failed_count: 2
        },
        action: :open,
        actor: context.scope,
        authorize?: false
      )

    {:ok, incident} =
      Status.publish_incident(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        incident_id: observed_incident.id,
        service_ids: [context.service.id],
        title: "API outage",
        body: "We are investigating."
      })

    path = page_path(context.org, context.project, context.page)

    {:ok, view, _html} =
      context.conn
      |> log_in(context.owner)
      |> live(path <> "/incidents/#{incident.id}")

    assert has_element?(view, "#status-incident-observation")
    assert has_element?(view, "#status-incident-observation", "Monitor observation")
    assert has_element?(view, "#status-incident-workspace", "We are investigating.")
  end

  test "a member cannot open a private incident by guessing its URL", context do
    {:ok, private_incident} =
      Status.create_incident_draft(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        monitor_id: context.monitor.id
      })

    member = user_fixture()

    member_scope = member_fixture(context.scope, context.org, member)
    member_scope = Scope.put_project(member_scope, context.project.id)

    path = page_path(context.org, context.project, context.page)

    assert_error_sent 404, fn ->
      context.conn
      |> log_in(member)
      |> live(path <> "/incidents/#{private_incident.id}")
    end

    assert member_scope.project_id == context.project.id
  end
end
