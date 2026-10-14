defmodule AlplusWeb.MonitorNewLiveTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.AuditFixtures
  import Alplus.OrgsFixtures
  import Phoenix.LiveViewTest

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp wizard_path(org, project),
    do: "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor/new"

  defp monitor_index_path(org, project),
    do: "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor"

  test "retired monitor creation redirects owners to analysis with a notice", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)

    assert {:error, {:redirect, %{to: to, flash: flash}}} =
             conn |> log_in(owner) |> live(wizard_path(org, project))

    assert to == monitor_index_path(org, project)
    assert flash["info"] =~ "Monitor creation now runs through your connected agent"
  end

  test "members are redirected without a creation form", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    member = user_fixture()
    member_fixture(scope, org, member, "member")

    assert {:error, {:redirect, %{to: to}}} =
             conn |> log_in(member) |> live(wizard_path(org, project))

    assert to == monitor_index_path(org, project)
  end

  test "a foreign project token is not resolved by the retired route", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project_fixture(scope, org)

    other_owner = user_fixture()
    {other_org, other_scope} = org_fixture(Alplus.Scope.for_user(other_owner.id))
    other_project = project_fixture(other_scope, other_org)

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn
      |> log_in(owner)
      |> live(wizard_path(org, other_project))
    end
  end

  test "an unknown project token is not resolved by the retired route", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project_fixture(scope, org)

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn
      |> log_in(owner)
      |> live("/dashboard/orgs/#{org.public_token}/projects/does-not-exist/monitor/new")
    end
  end
end
