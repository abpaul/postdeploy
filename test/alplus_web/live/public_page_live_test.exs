defmodule AlplusWeb.PublicPageLiveTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.AuditFixtures
  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures

  alias Alplus.PublicPages
  alias Alplus.Scope
  alias Alplus.Status

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp public_path(org, project, section),
    do: "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/public/#{section}"

  defp status_path(org, project), do: public_path(org, project, "status")

  test "project navigation exposes one Public destination and durable sections", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {:ok, view, _html} = conn |> log_in(owner) |> live(status_path(org, project))

    # The sidebar is the only navigator. A second tab row above the page
    # repeated destinations the rail already carries, so every Public screen
    # reaches its siblings through the rail alone.
    assert has_element?(view, "#desktop-nav-status_page", "Status page")
    assert has_element?(view, "#desktop-nav-changelog", "Changelog")
    assert has_element?(view, "#desktop-nav-public_settings", "Settings")
    refute has_element?(view, "#public-page-console-navigation")

    refute has_element?(view, "#monitor-subnav")
    refute has_element?(view, "#status-page-list")
    refute has_element?(view, "#new-status-page-button")
  end

  test "authenticated users analyze shared identity, publication, aliases, and public links", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    scope = Scope.put_project(owner_scope, project.id)

    assert {:ok, identity} =
             PublicPages.ensure_identity(scope, %{
               org_id: org.id,
               project_id: project.id,
               public_slug: "public-page",
               title: "Public page"
             })

    assert {:ok, renamed_identity} =
             PublicPages.update(scope, identity, %{public_slug: "acme-public"})

    assert {:ok, _published_identity} = PublicPages.publish(scope, renamed_identity)

    {:ok, view, _html} = conn |> log_in(owner) |> live(public_path(org, project, "settings"))

    assert has_element?(
             view,
             "#desktop-nav-public_settings[href='/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/public/settings'][aria-current='page']",
             "Settings"
           )

    assert has_element?(view, "#public-page-settings-panel", "Published")
    assert has_element?(view, "#public-page-canonical-link", "/status/acme-public")
    assert has_element?(view, "button[data-target='public-page-canonical-link']")
    assert has_element?(view, "a[href='/status/acme-public']", "Open")
    assert has_element?(view, "#public-page-aliases", "/status/public-page")
    refute has_element?(view, "#public-page-settings-form")
    refute has_element?(view, "#public-page-publish")
    refute has_element?(view, "#public-page-unpublish")
  end

  test "members analyze the same private identity without mutation controls", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    scope = Scope.put_project(owner_scope, project.id)

    assert {:ok, _identity} =
             PublicPages.ensure_identity(scope, %{
               org_id: org.id,
               project_id: project.id,
               public_slug: "members-public",
               title: "Members public"
             })

    member = user_fixture()
    member_fixture(owner_scope, org, member, "member")

    {:ok, view, _html} = conn |> log_in(member) |> live(public_path(org, project, "settings"))

    assert has_element?(view, "#public-page-canonical-link", "/status/members-public")
    assert has_element?(view, "#public-page-settings-panel", "Private")
    refute has_element?(view, "#public-page-aliases")
    refute has_element?(view, "a[href='/status/members-public']")
    refute has_element?(view, "#public-page-settings-form")
    refute has_element?(view, "#public-page-publish")
  end

  test "legacy authenticated management routes redirect to Public", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)

    {:ok, page} =
      Status.create_page(Scope.put_project(scope, project.id), %{
        org_id: org.id,
        project_id: project.id,
        public_slug: "legacy-status",
        title: "Legacy status"
      })

    legacy =
      "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor/status-pages"

    assert {:error, {:live_redirect, %{to: to}}} = conn |> log_in(owner) |> live(legacy)
    assert to == status_path(org, project)

    legacy_settings =
      "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor/status-pages/#{page.id}/settings"

    assert {:error, {:live_redirect, %{to: settings_to}}} =
             conn |> log_in(owner) |> live(legacy_settings)

    assert settings_to == public_path(org, project, "settings")
  end

  test "status creation keeps one workspace without a page-count entitlement", %{conn: _conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    assert {:ok, _page} =
             Status.create_page(scope, %{
               org_id: org.id,
               project_id: project.id,
               status_slug: "singleton-public",
               title: "Singleton public"
             })

    assert {:error, :status_pages_singleton} =
             Status.create_page(scope, %{
               org_id: org.id,
               project_id: project.id,
               status_slug: "another-public",
               title: "Another public"
             })
  end
end
