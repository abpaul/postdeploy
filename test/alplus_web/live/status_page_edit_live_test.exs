defmodule AlplusWeb.StatusPageEditLiveTest do
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

  defp base_path(org, project),
    do: ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/public/status"

  defp setup_workspace(owner) do
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
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "API"},
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

    %{org: org, project: project, scope: scope, page: page, service: service}
  end

  test "retired service creation redirects to the Services collection", %{conn: conn} do
    owner = user_fixture()
    %{org: org, project: project} = setup_workspace(owner)
    base = base_path(org, project)
    services_path = base <> "/services"

    assert {:error, {:redirect, %{to: ^services_path, flash: flash}}} =
             conn |> log_in(owner) |> live(base <> "/services/new")

    assert flash["info"] =~ "Service creation now runs through your connected agent"
  end

  test "retired incident creation redirects to the Incidents collection", %{conn: conn} do
    owner = user_fixture()
    %{org: org, project: project} = setup_workspace(owner)
    base = base_path(org, project)
    incidents_path = base <> "/incidents"

    assert {:error, {:redirect, %{to: ^incidents_path, flash: flash}}} =
             conn |> log_in(owner) |> live(base <> "/incidents/new")

    assert flash["info"] =~ "Incident creation now runs through your connected agent"
  end

  test "retired maintenance creation redirects to the Maintenance collection", %{conn: conn} do
    owner = user_fixture()
    %{org: org, project: project} = setup_workspace(owner)
    base = base_path(org, project)
    maintenance_path = base <> "/maintenance"

    assert {:error, {:redirect, %{to: ^maintenance_path, flash: flash}}} =
             conn |> log_in(owner) |> live(base <> "/maintenance/new")

    assert flash["info"] =~ "Maintenance creation now runs through your connected agent"
  end

  test "the retained Services collection exposes evidence without mutation events", %{conn: conn} do
    owner = user_fixture()
    %{org: org, project: project} = setup_workspace(owner)
    base = base_path(org, project)

    {:ok, view, _html} = conn |> log_in(owner) |> live(base <> "/services")

    assert has_element?(view, "#status-services-workspace")

    for action <-
          ~w(create edit publish unpublish rotate revoke retire resolve schedule cancel delete) do
      refute has_element?(view, "[phx-click*='#{action}']")
      refute has_element?(view, "[phx-submit*='#{action}']")
      refute has_element?(view, "[id*='#{action}']")
    end

    refute has_element?(view, "form")
    refute has_element?(view, "[phx-submit]")
    refute has_element?(view, "[phx-change]")
  end

  test "a foreign project token is not resolved by retired Public Status routes", %{conn: conn} do
    owner = user_fixture()
    %{org: org} = setup_workspace(owner)
    other_owner = user_fixture()
    %{org: other_org, project: other_project} = setup_workspace(other_owner)

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn
      |> log_in(owner)
      |> live(base_path(org, other_project) <> "/services/new")
    end

    assert other_org.public_token != org.public_token
  end
end
