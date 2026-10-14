defmodule AlplusWeb.MonitorEditLiveTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.AuditFixtures
  import Alplus.OrgsFixtures
  import Phoenix.LiveViewTest

  alias Alplus.Monitoring.Monitor

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp edit_path(org, project, monitor_id) when is_binary(monitor_id),
    do:
      "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor/#{monitor_id}/edit"

  defp edit_path(org, project, monitor),
    do:
      "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor/#{monitor.id}/edit"

  defp detail_path(org, project, monitor),
    do:
      "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor/#{monitor.id}"

  defp monitor_fixture(scope, org, project) do
    Ash.create!(
      Monitor,
      %{org_id: org.id, project_id: project.id, type: "http", name: "Status page"},
      action: :create,
      actor: Alplus.Scope.put_project(scope, project.id)
    )
  end

  test "retired monitor editing redirects owners to monitor detail with a notice", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    monitor = monitor_fixture(scope, org, project)

    assert {:error, {:redirect, %{to: to, flash: flash}}} =
             conn |> log_in(owner) |> live(edit_path(org, project, monitor))

    assert to == detail_path(org, project, monitor)
    assert flash["info"] =~ "Monitor changes now run through your connected agent"
  end

  test "members cannot use the retired edit route", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    monitor = monitor_fixture(scope, org, project)
    member = user_fixture()
    member_fixture(scope, org, member, "member")

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn
      |> log_in(member)
      |> live(edit_path(org, project, monitor))
    end
  end

  test "a monitor from another project is not resolved by the retired route", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {other_org, other_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_scope, other_org)
    monitor = monitor_fixture(other_scope, other_org, other_project)

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn
      |> log_in(owner)
      |> live(edit_path(org, project, monitor))
    end
  end

  test "an unknown monitor id is not resolved by the retired route", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn
      |> log_in(owner)
      |> live(edit_path(org, project, "does-not-exist"))
    end
  end
end
