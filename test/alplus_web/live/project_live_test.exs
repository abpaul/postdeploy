defmodule AlplusWeb.ProjectLiveTest do
  @moduledoc """
  Route-and-render tests for the project Overview: one answer title, one
  selectable real-signal chart, and a restrained attention rail.

  Public and Changelog remain sidebar destinations rather than Overview
  signals.
  """
  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Alplus.AuditFixtures
  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.Monitor

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp hub_path(org, project),
    do: ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}"

  describe "rendering" do
    test "fresh project overview leads with health, changes, investigations, and destinations", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)

      {:ok, view, html} =
        conn
        |> log_in(owner)
        |> live(hub_path(org, project))

      assert has_element?(view, "main")
      # The title is the answer; one cell per pillar, all three at once.
      assert has_element?(view, "h1", "Ready for your first check.")
      assert has_element?(view, "#project-hub-summary", "Ready for your first check.")
      assert has_element?(view, "#project-signals")
      assert has_element?(view, "#project-signals > #project-signal-monitor", "Monitors")
      assert has_element?(view, "#project-signals > #project-signal-issues", "Issues")
      assert has_element?(view, "#project-signals > #project-signal-traffic", "Traffic")
      assert has_element?(view, "#project-signal-monitor-value", "No checks yet")
      assert has_element?(view, "#project-signal-issues-value", "None open")
      assert has_element?(view, "#project-signal-traffic-value", "Not connected")
      assert has_element?(view, "#project-monitor-timeline")
      assert has_element?(view, "#project-issues-chart")
      assert has_element?(view, "#project-traffic-trend")
      assert has_element?(view, "#project-signal-monitor-link", "All monitors")
      assert has_element?(view, "#project-signal-issues-link", "All issues")
      assert has_element?(view, "#project-signal-traffic-link", "All traffic")
      refute has_element?(view, "#project-uptime")
      refute has_element?(view, "#project-agent-evidence")

      # Attention is absent when there is no actionable evidence.
      refute has_element?(view, "#project-attention")

      # The rail holds measurements; Public and Changelog live in the sidebar.
      refute has_element?(view, "#project-public")
      refute has_element?(view, "#project-changelog")

      # Read-only, agentic-first: no create affordance anywhere on Overview.
      refute html =~ "Create monitor"
      refute html =~ "Create source"
      refute html =~ "Publish"
    end

    test "connection state requires an allowed agent audit for this project", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      conn = log_in(conn, owner)

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, hub_path(org, project))
      assert to == hub_path(org, project) <> "/connect"

      agent_audit_fixture(owner_scope, project)

      {:ok, verified, _html} = live(conn, hub_path(org, project))
      assert has_element?(verified, "#project-hub-content")
    end

    test "configured Observe evidence with no open issues remains successful", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)
      {_source, _secret} = source_fixture(owner_scope, org, project)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(hub_path(org, project))

      assert has_element?(view, "#project-issues-chart")
      assert has_element?(view, "#project-signal-issues-value", "None open")
    end

    test "every cell links to the screen that holds the whole of it", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(hub_path(org, project))

      assert has_element?(
               view,
               ~s(#project-signal-monitor-link[href="#{hub_path(org, project)}/monitor"])
             )

      assert has_element?(
               view,
               ~s(#project-signal-issues-link[href="#{hub_path(org, project)}/observe"])
             )

      assert has_element?(
               view,
               ~s(#project-signal-traffic-link[href="#{hub_path(org, project)}/measure"])
             )
    end

    test "the header time range drives every pillar on the page", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(hub_path(org, project))

      assert has_element?(view, "#window-select [aria-pressed=true]", "Last 24h")

      view |> element("#window-select [phx-value-window='30d']") |> render_click()

      assert has_element?(view, "#window-select [aria-pressed=true]", "Last 30 days")
      assert has_element?(view, "#project-signals")
    end

    test "the time range is read from the URL, so a reload keeps it", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(hub_path(org, project) <> "?window=30d")

      assert has_element?(view, "#window-select [aria-pressed=true]", "Last 30 days")
    end

    test "picking a time range writes it to the URL", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(hub_path(org, project))

      view |> element("#window-select [phx-value-window='24h']") |> render_click()

      assert_patched(view, hub_path(org, project) <> "?window=24h")
    end

    test "an unknown time range in the URL falls back to the default", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(hub_path(org, project) <> "?window=all-time")

      assert has_element?(view, "#window-select [aria-pressed=true]", "Last 24h")
    end

    test "a project with no monitors never claims everything is up", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)
      {source, _secret} = source_fixture(owner_scope, org, project)
      now = DateTime.utc_now()

      Ash.create!(
        Alplus.Observe.Issue,
        %{
          org_id: org.id,
          project_id: project.id,
          source_id: source.id,
          environment: source.environment,
          fingerprint: "sha256:" <> String.duplicate("b", 64),
          level: "error",
          title: "Database timeout",
          first_seen_at: now,
          last_seen_at: now
        },
        action: :record,
        authorize?: false
      )

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(hub_path(org, project))

      # Uptime comes from monitors. With none configured there is no evidence
      # for "Everything is up", whatever Observe reports.
      assert has_element?(view, "#project-hub-summary", "Ready for your first check.")
      refute has_element?(view, "#project-hub-summary", "Everything is up")
    end

    test "attention links name their destinations and the fleet timeline has 24 hourly buckets",
         %{
           conn: conn
         } do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      project_scope = Alplus.Scope.put_project(owner_scope, project.id)
      agent_audit_fixture(owner_scope, project)
      {source, _secret} = source_fixture(owner_scope, org, project)

      monitor =
        Ash.create!(
          Monitor,
          %{
            org_id: org.id,
            project_id: project.id,
            type: "http",
            name: "Checkout"
          },
          action: :create,
          actor: project_scope
        )

      Ash.Seed.update!(monitor, %{last_known_status: "down"})

      now = DateTime.utc_now()

      Ash.create!(
        Alplus.Observe.Issue,
        %{
          org_id: org.id,
          project_id: project.id,
          source_id: source.id,
          environment: source.environment,
          fingerprint: "sha256:" <> String.duplicate("c", 64),
          level: "error",
          title: "Checkout failed",
          first_seen_at: now,
          last_seen_at: now
        },
        action: :record,
        authorize?: false
      )

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(hub_path(org, project))

      assert has_element?(view, "#project-attention-monitors-down a", "Open monitors")
      assert has_element?(view, "#project-attention-open-issues a", "Open issues")
      assert has_element?(view, "#project-hub-content > #project-signals")
      assert has_element?(view, "#project-hub-content > #project-attention")
      refute has_element?(view, "#project-signals #project-attention")
      assert has_element?(view, "#project-monitor-timeline")
      assert has_element?(view, "#project-monitor-timeline-visual .bg-status-error")

      timeline_html = view |> element("#project-monitor-timeline-visual") |> render()
      assert length(Regex.scan(~r/data-display-point="true"/, timeline_html)) == 24
    end

    test "the hub carries no MCP activity panel; the connect screen owns it", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(hub_path(org, project))

      refute has_element?(view, "#project-agent-evidence")
      refute has_element?(view, "#project-agent-activity-empty")
    end
  end

  describe "tenant isolation" do
    test "a project token from another organization returns 404", %{conn: conn} do
      owner = user_fixture()
      {org_a, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      other = user_fixture()
      {org_b, other_scope} = org_fixture(Alplus.Scope.for_user(other.id))
      project_b = project_fixture(other_scope, org_b)

      assert_raise AlplusWeb.NotFoundError, fn ->
        conn
        |> log_in(owner)
        |> live(~p"/dashboard/orgs/#{org_a.public_token}/projects/#{project_b.public_token}")
      end
    end

    test "an unknown project token returns 404", %{conn: conn} do
      owner = user_fixture()
      {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      assert_raise AlplusWeb.NotFoundError, fn ->
        conn
        |> log_in(owner)
        |> live(~p"/dashboard/orgs/#{org.public_token}/projects/does-not-exist")
      end
    end
  end

  test "an archived project token returns 404", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    Ash.destroy!(project, action: :archive, actor: scope)

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn
      |> log_in(owner)
      |> live(hub_path(org, project))
    end
  end
end
