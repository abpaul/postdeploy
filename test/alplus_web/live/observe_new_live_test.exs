defmodule AlplusWeb.ObserveNewLiveTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.AuditFixtures
  import Alplus.OrgsFixtures
  import Phoenix.LiveViewTest

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp new_path(org, project),
    do: "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/new"

  defp index_path(org, project),
    do: "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe"

  test "retired Observe creation redirects owners to analysis with a notice", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)

    assert {:error, {:redirect, %{to: to, flash: flash}}} =
             conn |> log_in(owner) |> live(new_path(org, project))

    assert to == index_path(org, project)
    assert flash["info"] =~ "Observe source setup now runs through your connected agent"
  end

  test "members are redirected without a source wizard", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    member = user_fixture()
    member_fixture(scope, org, member, "member")

    assert {:error, {:redirect, %{to: to}}} =
             conn |> log_in(member) |> live(new_path(org, project))

    assert to == index_path(org, project)
  end

  test "a foreign project token is not resolved by the retired route", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project_fixture(scope, org)
    other_owner = user_fixture()
    {other_org, other_scope} = org_fixture(Alplus.Scope.for_user(other_owner.id))
    other_project = project_fixture(other_scope, other_org)

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn |> log_in(owner) |> live(new_path(org, other_project))
    end
  end

  test "an unknown project token is not resolved by the retired route", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project_fixture(scope, org)

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn
      |> log_in(owner)
      |> live("/dashboard/orgs/#{org.public_token}/projects/does-not-exist/observe/new")
    end
  end
end
