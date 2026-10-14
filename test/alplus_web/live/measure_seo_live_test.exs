defmodule AlplusWeb.MeasureSeoLiveTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.AuditFixtures
  import Alplus.OrgsFixtures
  import Phoenix.LiveViewTest

  setup do
    original = Application.get_env(:alplus, :seo_enabled_org_ids, [])

    on_exit(fn ->
      Application.put_env(:alplus, :seo_enabled_org_ids, original)
    end)
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp seo_path(org, project) do
    ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/measure/seo"
  end

  test "the SEO route is hidden and denied outside the organization allowlist", %{conn: conn} do
    user = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(user.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    Application.put_env(:alplus, :seo_enabled_org_ids, [])

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn |> log_in(user) |> live(seo_path(org, project))
    end
  end

  test "an enabled organization sees the SEO navigation and setup state", %{conn: conn} do
    user = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(user.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    Application.put_env(:alplus, :seo_enabled_org_ids, [org.id])

    {:ok, view, _html} = conn |> log_in(user) |> live(seo_path(org, project))

    assert has_element?(view, "h1", "Add an SEO profile")
    assert has_element?(view, "#measure-seo-empty", "Add an SEO profile")
    assert has_element?(view, "a[href='#{seo_path(org, project)}']", "SEO")
  end
end
