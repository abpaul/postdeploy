defmodule AlplusWeb.StatusWorkspaceLiveTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.AuditFixtures
  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.Monitor
  alias Alplus.Scope
  alias Alplus.Status

  defp log_in(conn, user),
    do:
      conn
      |> Plug.Test.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)

  defp page_path(org, project, _page),
    do: ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/public/status"

  defp workspace_path(org, project, page, section),
    do: page_path(org, project, page) <> "/#{section}"

  defp service_path(org, project, page, id),
    do: workspace_path(org, project, page, "services") <> "/#{id}"

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
        public_slug: "workspace",
        title: "Workspace"
      })

    monitor =
      Ash.create!(Monitor, %{org_id: org.id, project_id: project.id, type: "http", name: "API"},
        action: :create,
        actor: scope
      )

    {:ok, service} =
      Status.create_service(scope, %{
        org_id: org.id,
        project_id: project.id,
        status_page_id: page.id,
        name: "API",
        monitor_ids: [monitor.id]
      })

    {:ok,
     conn: conn,
     owner: owner,
     org: org,
     project: project,
     scope: scope,
     page: page,
     service: service}
  end

  test "services retain health evidence and have no mutation affordances", context do
    {:ok, view, _html} =
      context.conn
      |> log_in(context.owner)
      |> live(workspace_path(context.org, context.project, context.page, "services"))

    assert has_element?(view, "#status-services-workspace", "API")
    assert has_element?(view, "#status-overview-health")
    refute has_element?(view, "form")
    refute has_element?(view, "Add service")
    refute has_element?(view, "Create service")
  end

  test "five monitor broadcasts produce five reload messages and one subscription", context do
    {:ok, view, _html} =
      context.conn
      |> log_in(context.owner)
      |> live(workspace_path(context.org, context.project, context.page, "services"))

    topic = "monitor:#{context.project.id}"
    assert [{pid, _metadata}] = Registry.lookup(Alplus.PubSub, topic)
    assert pid == view.pid

    :erlang.trace(view.pid, true, [:receive])

    for _ <- 1..5 do
      Phoenix.PubSub.broadcast(Alplus.PubSub, topic, {:monitor_updated, context.project.id})
      render(view)
    end

    for _ <- 1..5 do
      assert_receive {:trace, pid, :receive, {:monitor_updated, project_id}}
      assert pid == view.pid
      assert project_id == context.project.id
    end

    refute_receive {:trace, ^pid, :receive, {:monitor_updated, _project_id}}, 100
    assert [{^pid, _metadata}] = Registry.lookup(Alplus.PubSub, topic)
  end

  test "service detail retains monitor and reliability evidence", context do
    {:ok, view, _html} =
      context.conn
      |> log_in(context.owner)
      |> live(service_path(context.org, context.project, context.page, context.service.id))

    assert has_element?(view, "#status-service-detail", "API")
    assert has_element?(view, "#status-service-monitors")
    assert has_element?(view, "#status-service-reliability")
    refute has_element?(view, "form")
    refute has_element?(view, "Save service")
    refute has_element?(view, "Retire service")
  end

  test "a service detail page has one heading, the visible service name", context do
    {:ok, _view, html} =
      context.conn
      |> log_in(context.owner)
      |> live(service_path(context.org, context.project, context.page, context.service.id))

    assert length(Regex.scan(~r/<h1[\s>]/, html)) == 1
    assert html =~ ~r/<h1[^>]*>\s*API\s*<\/h1>/
  end

  test "a workspace section page opens with one visible page heading", context do
    {:ok, view, html} =
      context.conn
      |> log_in(context.owner)
      |> live(workspace_path(context.org, context.project, context.page, "services"))

    assert length(Regex.scan(~r/<h1[\s>]/, html)) == 1
    assert has_element?(view, "h1#status-workspace-page-heading", "Public status")
    refute has_element?(view, "h1.sr-only")
  end

  test "history, announcements, maintenance, and evidence routes are read-only", context do
    for section <- ["incidents", "announcements", "maintenance", "history", "settings"] do
      {:ok, view, _html} =
        context.conn
        |> log_in(context.owner)
        |> live(workspace_path(context.org, context.project, context.page, section))

      refute has_element?(view, "form")
      refute has_element?(view, "Publish")
      refute has_element?(view, "Schedule")
      refute has_element?(view, "Unpublish")
      refute has_element?(view, "Resolve")
    end
  end

  test "retired new routes redirect to their analysis workspaces", context do
    for {section, destination, notice} <- [
          {"services/new", "services",
           "Service creation now runs through your connected agent. Review current services here."},
          {"incidents/new", "incidents",
           "Incident creation now runs through your connected agent. Review current incidents here."},
          {"maintenance/new", "maintenance",
           "Maintenance creation now runs through your connected agent. Review scheduled maintenance here."}
        ] do
      to = workspace_path(context.org, context.project, context.page, destination)

      assert {:error, {:redirect, %{to: ^to, flash: flash}}} =
               context.conn
               |> log_in(context.owner)
               |> live(page_path(context.org, context.project, context.page) <> "/#{section}")

      assert flash["info"] == notice
    end
  end
end
