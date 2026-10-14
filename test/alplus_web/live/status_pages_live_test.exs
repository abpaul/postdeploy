defmodule AlplusWeb.StatusPagesLiveTest do
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

  defp public_status_path(org, project),
    do: ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/public/status"

  defp legacy_index_path(org, project),
    do:
      ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor/status-pages"

  defp legacy_new_path(org, project),
    do:
      ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor/status-pages/new"

  defp legacy_project_path(org, project),
    do: ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/status"

  defp monitor_fixture(scope, org, project, name) do
    Ash.create!(Monitor, %{org_id: org.id, project_id: project.id, type: "http", name: name},
      action: :create,
      actor: Scope.put_project(scope, project.id)
    )
  end

  defp page_fixture(scope, org, project, slug \\ "acme-status") do
    {:ok, page} =
      Status.create_page(Scope.put_project(scope, project.id), %{
        org_id: org.id,
        project_id: project.id,
        public_slug: slug,
        title: "Acme Status"
      })

    page
  end

  test "without monitors shows an evidence empty state without mutation controls", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {:ok, view, _html} = conn |> log_in(owner) |> live(public_status_path(org, project))

    # The page-level answer names the missing evidence; the setup card names
    # the step that fixes it, so the two do not repeat one sentence.
    assert has_element?(view, "#status-page-state", "No monitors are reporting yet")
    assert has_element?(view, "#status-pages-need-monitors", "A monitor has to run first")
    assert has_element?(view, "#status-pages-need-monitors-task")
    assert has_element?(view, "#status-pages-need-monitors-action", "Open monitors")
    assert has_element?(view, "#copy-status-pages-need-monitors-task", "Copy task")
    refute has_element?(view, "form")
    refute has_element?(view, "Create monitor")
  end

  test "with monitors but no page shows setup evidence through the agent", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    monitor_fixture(scope, org, project, "API health")
    {:ok, view, _html} = conn |> log_in(owner) |> live(public_status_path(org, project))

    assert has_element?(view, "#status-page-workspace-empty", "No status page yet")
    assert has_element?(view, "#status-page-workspace-empty-task")
    refute has_element?(view, "#status-page-create-form")
    refute has_element?(view, "Create Public page")
  end

  test "existing workspace keeps monitor analysis and public links", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    project_scope = Scope.put_project(scope, project.id)
    monitor = monitor_fixture(scope, org, project, "API health")
    page = page_fixture(scope, org, project)

    {:ok, service} =
      Status.create_service(project_scope, %{
        org_id: org.id,
        project_id: project.id,
        status_page_id: page.id,
        name: "API",
        monitor_ids: [monitor.id]
      })

    {:ok, _page} = Status.publish_page(project_scope, page)

    {:ok, view, _html} =
      conn |> log_in(owner) |> live(public_status_path(org, project) <> "/services")

    assert has_element?(view, "#status-services-workspace", "API")

    assert has_element?(
             view,
             "a[href='/status/acme-status#status-component-#{service.id}']",
             "View public service"
           )

    refute has_element?(view, "form")
    refute has_element?(view, "Add service")
    refute has_element?(view, "phx-click")
  end

  test "legacy status entry routes redirect to analysis", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    expected = public_status_path(org, project)

    assert {:error, {:live_redirect, %{to: to}}} =
             conn |> log_in(owner) |> live(legacy_new_path(org, project))

    assert to == expected

    assert {:error, {:live_redirect, %{to: to}}} =
             conn |> log_in(owner) |> live(legacy_index_path(org, project))

    assert to == expected

    assert {:error, {:live_redirect, %{to: to}}} =
             conn |> log_in(owner) |> live(legacy_project_path(org, project))

    assert to == expected
  end
end
