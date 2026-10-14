defmodule AlplusWeb.PublicPageSettingsLiveTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.AuditFixtures
  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures

  alias Alplus.PublicPages
  alias Alplus.Scope

  defp log_in(conn, user),
    do:
      conn
      |> Plug.Test.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)

  defp settings_path(org, project),
    do: ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/public/settings"

  defp create_page(scope, project) do
    {:ok, page} =
      PublicPages.create_identity(scope, %{
        org_id: scope.org_id,
        project_id: project.id,
        title: "Acme",
        public_slug: "acme"
      })

    page
  end

  test "without a Public identity shows an evidence empty state", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {:ok, view, _html} = conn |> log_in(owner) |> live(settings_path(org, project))

    assert has_element?(view, "#public-page-settings-empty", "No public name or address yet")
    assert has_element?(view, "#public-page-settings-empty-task")
    assert has_element?(view, "#public-page-settings-empty-action")
    assert has_element?(view, "#copy-public-page-settings-empty-task", "Copy task")
    refute has_element?(view, "form")
    refute has_element?(view, "Save settings")
    refute has_element?(view, "Publish page")
  end

  test "identity renders publication, aliases, and public links without mutation controls", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, scope} = org_fixture(Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    page = create_page(Scope.put_project(scope, project.id), project)
    {:ok, view, _html} = conn |> log_in(owner) |> live(settings_path(org, project))

    assert has_element?(view, "#public-page-settings-panel")
    assert has_element?(view, "#public-page-canonical-link", "/status/acme")
    refute has_element?(view, "#public-page-aliases")
    refute has_element?(view, "#public-page-status-setup")
    refute has_element?(view, "form")
    refute has_element?(view, "Save settings")
    refute has_element?(view, "Publish page")
    refute has_element?(view, "Unpublish page")

    assert {:ok, current} =
             PublicPages.get_for_project(Scope.put_project(scope, project.id), project.id)

    assert current.id == page.id
  end

  test "published identity keeps a copyable public Status link", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    project_scope = Scope.put_project(scope, project.id)
    page = create_page(project_scope, project)
    {:ok, _page} = PublicPages.publish(project_scope, page)

    {:ok, view, _html} = conn |> log_in(owner) |> live(settings_path(org, project))
    assert has_element?(view, "#public-page-canonical-link", "/status/acme")
    assert has_element?(view, "a[href='/status/acme']", "Open")
    assert has_element?(view, "button[data-target='public-page-canonical-link']")
    refute has_element?(view, "phx-click")
  end
end
