defmodule AlplusWeb.ConnectGateTest do
  @moduledoc """
  Behaviour of `AlplusWeb.ConnectGate` through the router: which project
  pages open, which redirect to Connect, and what stays untouched.
  """

  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures
  import Alplus.AuditFixtures
  alias AshAuthentication.Plug.Helpers

  @gate_flash "Connect an agent to open this project."

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Helpers.store_in_session(user)
  end

  defp project_base(org, project),
    do: "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}"

  defp connect_path(org, project), do: project_base(org, project) <> "/connect"

  defp org_with_project do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org, %{name: "Gated"})
    {owner, org, owner_scope, project}
  end

  describe "a disconnected project" do
    setup %{conn: conn} do
      {owner, org, owner_scope, project} = org_with_project()
      %{conn: log_in(conn, owner), org: org, owner_scope: owner_scope, project: project}
    end

    test "sends every project page to Connect with one action-oriented flash", context do
      %{conn: conn, org: org, project: project} = context
      base = project_base(org, project)
      connect = connect_path(org, project)

      for path <- [
            base,
            base <> "/observe",
            base <> "/measure",
            base <> "/monitor",
            base <> "/public",
            base <> "/public/status",
            base <> "/public/status/services",
            base <> "/public/settings",
            base <> "/public/changelog",
            base <> "/public/changelog/entries",
            base <> "/public/changelog/activity",
            base <> "/status",
            base <> "/monitor/status-pages"
          ] do
        assert {:error, {:live_redirect, %{to: ^connect, flash: flash}}} = live(conn, path),
               "expected #{path} to redirect to Connect"

        assert Phoenix.Flash.get(flash, :info) == @gate_flash
      end
    end

    test "Connect itself mounts, so the redirect cannot loop", context do
      %{conn: conn, org: org, project: project} = context
      connect = connect_path(org, project)

      {:ok, view, html} = live(conn, connect)

      assert html =~ "Connect"
      # Re-entering Connect from Connect (the destination of the gate) must
      # still render, never bounce.
      assert {:ok, _view, _html} = live(conn, connect)
      assert render(view) =~ "Connect"
    end

    test "the redirect target renders the Connect page, not another redirect", context do
      %{conn: conn, org: org, project: project} = context

      assert {:error, {:live_redirect, %{to: connect}}} = live(conn, project_base(org, project))
      assert {:ok, _view, _html} = live(conn, connect)
    end

    test "org-level pages are untouched", context do
      %{conn: conn, org: org} = context
      base = "/dashboard/orgs/#{org.public_token}"

      for path <- [base <> "/projects", base <> "/team", base <> "/billing", base <> "/settings"] do
        assert {:ok, _view, _html} = live(conn, path), "expected #{path} to mount"
      end
    end
  end

  describe "a connected project" do
    setup %{conn: conn} do
      {owner, org, owner_scope, project} = org_with_project()
      agent_audit_fixture(owner_scope, project, "remote_mcp")
      %{conn: log_in(conn, owner), org: org, owner_scope: owner_scope, project: project}
    end

    test "opens the overview and the pillar pages", context do
      %{conn: conn, org: org, project: project} = context
      base = project_base(org, project)

      for path <- [base, base <> "/observe", base <> "/measure", base <> "/monitor"] do
        assert {:ok, _view, _html} = live(conn, path), "expected #{path} to mount"
      end
    end

    test "opens for a plain member, who cannot read the audit evidence", context do
      %{conn: conn, org: org, owner_scope: owner_scope, project: project} = context
      member = user_fixture()
      member_fixture(owner_scope, org, member, "member")

      assert {:ok, _view, _html} = live(log_in(conn, member), project_base(org, project))
    end

    test "a webmcp handshake also opens the project", %{conn: conn} do
      {owner, org, owner_scope, project} = org_with_project()
      agent_audit_fixture(owner_scope, project, "webmcp")

      assert {:ok, _view, _html} = live(log_in(conn, owner), project_base(org, project))
    end
  end

  describe "resources the visitor may not see" do
    test "an unknown project token still answers 404", %{conn: conn} do
      {owner, org, _owner_scope, _project} = org_with_project()
      conn = log_in(conn, owner)

      assert_raise AlplusWeb.NotFoundError, fn ->
        live(conn, "/dashboard/orgs/#{org.public_token}/projects/nope-not-a-token")
      end
    end

    test "a project token from another org still answers 404", %{conn: conn} do
      {owner, org, _owner_scope, _project} = org_with_project()
      {_other_owner, _other_org, other_scope, other_project} = org_with_project()
      agent_audit_fixture(other_scope, other_project, "remote_mcp")

      conn = log_in(conn, owner)

      assert_raise AlplusWeb.NotFoundError, fn ->
        live(
          conn,
          "/dashboard/orgs/#{org.public_token}/projects/#{other_project.public_token}"
        )
      end
    end

    test "an unknown org token still answers 404", %{conn: conn} do
      {owner, _org, _owner_scope, project} = org_with_project()
      conn = log_in(conn, owner)

      assert_raise AlplusWeb.NotFoundError, fn ->
        live(conn, "/dashboard/orgs/nope-not-a-token/projects/#{project.public_token}")
      end
    end

    test "a foreign org token answers 404 on Connect too, never a gate redirect", %{conn: conn} do
      {owner, _org, _owner_scope, _project} = org_with_project()
      {_other_owner, other_org, _other_scope, other_project} = org_with_project()

      conn = log_in(conn, owner)

      assert_raise AlplusWeb.NotFoundError, fn ->
        live(conn, connect_path(other_org, other_project))
      end
    end
  end

  describe "visitors the gate must not answer for" do
    test "a signed-out visitor goes to sign-in, not to Connect", %{conn: conn} do
      {_owner, org, _owner_scope, project} = org_with_project()

      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, project_base(org, project))
    end

    test "an unconfirmed user keeps the existing dashboard redirect", %{conn: conn} do
      owner = user_fixture(%{confirmed: false})
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org, %{name: "Unconfirmed"})

      assert is_nil(owner.confirmed_at)

      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               live(log_in(conn, owner), project_base(org, project))
    end
  end
end
