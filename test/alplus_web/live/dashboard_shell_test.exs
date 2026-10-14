defmodule AlplusWeb.DashboardShellTest do
  @moduledoc """
  The application shell: role-aware nav, org switcher, and the onboarding
  checklist derived from real rows (docs/research/dashboard-ui-parity-plan.md
  §6, §10). Driven through the real org project-list LiveView.
  """

  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures
  import Alplus.AuditFixtures

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp overview_path(org), do: ~p"/dashboard/orgs/#{org.id}/projects"

  describe "navigation" do
    test "owner sees organization navigation", %{conn: conn} do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project_fixture(scope, org)

      {:ok, view, _html} = conn |> log_in(owner) |> live(overview_path(org))

      for key <- ~w(overview team billing settings) do
        assert has_element?(view, "#desktop-nav-#{key}")
      end

      for key <- ~w(measure monitor observe) do
        refute has_element?(view, "#desktop-nav-#{key}")
      end

      refute has_element?(view, "#environment-select")
    end

    test "the org switcher shows the current org and links to sibling orgs", %{conn: conn} do
      owner = user_fixture()
      {org_a, scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Alpha Org"})
      {org_b, _} = org_fixture(scope, %{name: "Beta Org"})

      {:ok, view, _html} = conn |> log_in(owner) |> live(overview_path(org_a))

      assert has_element?(view, "#desktop-nav-org", "Alpha Org")
      assert has_element?(view, "#desktop-nav-org-switch-#{org_b.id}", "Beta Org")
      assert has_element?(view, "#desktop-nav-org-menu[role=menu][aria-hidden=true]")

      assert has_element?(
               view,
               "#desktop-nav-org-menu[phx-hook='AlplusWeb.DashboardComponents.ConsoleMenu']"
             )

      assert has_element?(view, "#desktop-nav-org-toggle[aria-controls='desktop-nav-org-menu']")
    end

    test "the active nav item is marked selected", %{conn: conn} do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project_fixture(scope, org)

      {:ok, view, _html} = conn |> log_in(owner) |> live(overview_path(org))

      assert has_element?(view, "#desktop-nav-overview[aria-current=page]")
    end

    test "mobile navigation is an accessible focus-managed sheet", %{conn: conn} do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project_fixture(scope, org)

      {:ok, view, _html} = conn |> log_in(owner) |> live(overview_path(org))

      assert has_element?(view, "#mobile-nav[role=dialog][aria-modal=true][aria-hidden=true]")
      assert has_element?(view, "#mobile-nav[aria-labelledby=mobile-nav-title]")
      assert has_element?(view, ~s(#mobile-nav-focus-wrap[phx-hook="Phoenix.FocusWrap"]))
      assert has_element?(view, "#mobile-nav-focus-wrap.hidden[aria-hidden=true]")
      assert has_element?(view, "#mobile-nav-focus-wrap[phx-key=escape]")
      assert has_element?(view, "#mobile-nav-focus-wrap-start[aria-hidden=true]")
      assert has_element?(view, "#mobile-nav-focus-wrap-end[aria-hidden=true]")
      refute has_element?(view, "#mobile-nav-focus-wrap[phx-window-keydown]")
      refute has_element?(view, "#mobile-nav[phx-window-keydown]")
      assert has_element?(view, "#mobile-nav-open[aria-controls=mobile-nav][aria-expanded=false]")
      assert has_element?(view, "#mobile-nav-open.min-h-target-min.min-w-target-min")
      assert has_element?(view, "#mobile-nav-close[aria-label='Close navigation']")
      assert has_element?(view, "#mobile-nav-scrim[aria-hidden=true]")

      open_command = view |> element("#mobile-nav-open") |> render()
      close_command = view |> element("#mobile-nav-close") |> render()
      escape_command = view |> element("#mobile-nav-focus-wrap") |> render()
      assert open_command =~ "push_focus"
      assert open_command =~ "overflow-hidden"
      assert close_command =~ "pop_focus"
      assert close_command =~ "overflow-hidden"
      assert escape_command =~ "pop_focus"
    end
  end

  describe "breadcrumbs (issue #29: org/project context always visible)" do
    defp hub_path(org, project),
      do: ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}"

    # The trail is the console's visible page heading: its last crumb names the
    # current page, is not a link, and carries `aria-current="page"`. The
    # shell's `<h1>` is `sr-only` so the heading is not drawn twice.
    test "the org project list shows Org / Projects, with Projects as the current page", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Alpha Org"})
      project_fixture(scope, org)

      {:ok, view, _html} = conn |> log_in(owner) |> live(overview_path(org))

      assert has_element?(view, "a#breadcrumbs-0", "Alpha Org")
      assert has_element?(view, "#breadcrumbs-1[aria-current=page]", "Projects")
      # The current crumb is never a link.
      refute has_element?(view, "a#breadcrumbs-1")
      # The heading exists once, for assistive technology only.
      assert has_element?(view, "h1.sr-only", "Projects")
    end

    test "the project hub shows Org / Overview, with the selector naming the project once", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Alpha Org"})
      project = project_fixture(scope, org, %{name: "Storefront"})
      agent_audit_fixture(scope, project)

      {:ok, view, _html} = conn |> log_in(owner) |> live(hub_path(org, project))

      assert has_element?(view, "a#breadcrumbs-0", "Alpha Org")
      assert has_element?(view, "#breadcrumbs-1[aria-current=page]", "Overview")
      refute has_element?(view, "#breadcrumbs-2")

      # The context bar carries the project selector here, so the trail does
      # not print the project name a second time beside it.
      assert has_element?(view, "#project-select", "Storefront")
      refute has_element?(view, "#breadcrumbs-1", "Storefront")

      assert has_element?(
               view,
               "[data-webmcp-dashboard][data-webmcp-org-id='#{org.id}'][data-webmcp-project-handle='#{project.id}']"
             )
    end

    test "a pillar page shows Org / Project / Traffic, with Traffic as the current page", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Alpha Org"})
      project = project_fixture(scope, org, %{name: "Storefront"})
      agent_audit_fixture(scope, project)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(hub_path(org, project) <> "/measure")

      assert has_element?(view, "a#breadcrumbs-0", "Alpha Org")
      assert has_element?(view, "a#breadcrumbs-1", "Storefront")
      assert has_element?(view, "#breadcrumbs-2[aria-current=page]", "Traffic")
    end

    test "a monitor detail page stops the breadcrumb at Monitor (no visible resource crumb)", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Alpha Org"})
      project = project_fixture(scope, org, %{name: "Storefront"})
      agent_audit_fixture(scope, project)

      monitor =
        Ash.create!(
          Alplus.Monitoring.Monitor,
          %{org_id: org.id, project_id: project.id, type: "http", name: "Status page"},
          action: :create,
          actor: %{scope | project_id: project.id}
        )

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(hub_path(org, project) <> "/monitor/#{monitor.id}")

      # No visible resource (monitor-name) crumb — the monitor name shows once,
      # in the page's own resource-panel header.
      assert has_element?(view, "a#breadcrumbs-0", "Alpha Org")
      assert has_element?(view, "a#breadcrumbs-1", "Storefront")
      assert has_element?(view, "#breadcrumbs-2[aria-current=page]", "Monitor")
      refute has_element?(view, "#breadcrumbs-3")
    end

    test "a cross-tenant org token 404s instead of rendering any breadcrumb", %{conn: conn} do
      owner = user_fixture()
      {_org, _scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      {other_org, _other_scope} = org_fixture(scope_fixture())

      assert_raise AlplusWeb.NotFoundError, fn ->
        conn |> log_in(owner) |> live(overview_path(other_org))
      end
    end
  end

  describe "project sidebar (design system v3 §04: flat, grouped nav; project switching moved to the topbar)" do
    defp team_path(org), do: ~p"/dashboard/orgs/#{org.id}/team"
    defp billing_path(org), do: ~p"/dashboard/orgs/#{org.id}/billing"

    test "a project page shows the flat v3 IA: ungrouped rows, then grouped destinations", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(scope, org, %{name: "ALP+ SaaS"})
      agent_audit_fixture(scope, project)

      {:ok, view, _html} = conn |> log_in(owner) |> live(hub_path(org, project))

      assert has_element?(view, "#desktop-nav-overview[aria-current=page]", "Overview")
      assert has_element?(view, "#desktop-nav-monitors", "Monitors")

      # Uptime checks and heartbeats share one screen, so they share one row.
      refute has_element?(view, "#desktop-nav-heartbeats")

      for {key, label} <- [
            {"issues", "Issues"},
            {"traffic", "Traffic"},
            {"status_page", "Status page"},
            {"changelog", "Changelog"},
            {"mcp", "MCP"},
            {"public_settings", "Settings"}
          ] do
        assert has_element?(view, "#desktop-nav-#{key}", label)
      end

      # Only reachable destinations are listed: no dead "Soon" rows.
      refute has_element?(view, "#desktop-nav-search")
      refute has_element?(view, "#desktop-nav-releases")
      refute has_element?(view, "#desktop-nav-reports")
      refute render(view) =~ "Soon"

      # A different project is a topbar concern now, not a per-project
      # sidebar row for every sibling project.
      refute has_element?(view, "#desktop-nav-project-#{project.id}-monitor")
      assert has_element?(view, "#project-select")
    end

    test "the project Settings screen marks one nav row current, not two", %{conn: conn} do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(scope, org, %{name: "ALP+ SaaS"})
      agent_audit_fixture(scope, project)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(hub_path(org, project) <> "/public/settings")

      assert has_element?(view, "#desktop-nav-public_settings[aria-current=page]", "Settings")
      refute has_element?(view, "#desktop-nav-status_page[aria-current=page]")

      # The trail still reads through Public, and still links back to the org.
      assert has_element?(view, "a#breadcrumbs-0")
      assert has_element?(view, "a#breadcrumbs-2", "Public")
      assert has_element?(view, "#breadcrumbs-3[aria-current=page]", "Public identity")
    end

    test "the Status page screen marks the Status page row current, not Settings", %{conn: conn} do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(scope, org, %{name: "ALP+ SaaS"})
      agent_audit_fixture(scope, project)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(hub_path(org, project) <> "/public/status")

      assert has_element?(view, "#desktop-nav-status_page[aria-current=page]", "Status page")
      refute has_element?(view, "#desktop-nav-public_settings[aria-current=page]")
    end

    test "an org-level page (Team) shows the org's own nav, with no single project pinned", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project_fixture(scope, org, %{name: "ALP+ SaaS"})

      {:ok, view, _html} = conn |> log_in(owner) |> live(team_path(org))

      assert has_element?(view, "#desktop-nav-team[aria-current=page]", "Team")
      assert has_element?(view, "#desktop-nav-billing", "Billing")
      assert has_element?(view, "#desktop-nav-overview", "Projects")
      refute has_element?(view, "#desktop-nav-monitors")
    end

    test "another org-level page (Billing) shows the same org nav", %{conn: conn} do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project_fixture(scope, org)

      {:ok, view, _html} = conn |> log_in(owner) |> live(billing_path(org))

      assert has_element?(view, "#desktop-nav-billing[aria-current=page]", "Billing")
    end

    test "the account row exposes Team, Billing, and Organization settings behind its overflow menu",
         %{conn: conn} do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(scope, org, %{name: "ALP+ SaaS"})
      agent_audit_fixture(scope, project)

      {:ok, view, _html} = conn |> log_in(owner) |> live(hub_path(org, project))

      assert has_element?(
               view,
               "#desktop-nav-account-toggle[aria-controls='desktop-nav-account-menu']"
             )

      assert has_element?(
               view,
               "#desktop-nav-account-menu[role=menu][aria-hidden=true]"
             )

      assert has_element?(view, "#desktop-nav-account-team", "Team")
      assert has_element?(view, "#desktop-nav-account-billing", "Billing")
      assert has_element?(view, "#desktop-nav-account-settings", "Organization settings")
      assert has_element?(view, "#desktop-nav-account")
      assert has_element?(view, "#desktop-nav-sign-out", "Sign out")
    end

    test "a cross-tenant org still 404s (tenant scoping unchanged)", %{conn: conn} do
      owner = user_fixture()
      {other_org, _other_scope} = org_fixture(scope_fixture())

      assert_raise AlplusWeb.NotFoundError, fn ->
        conn |> log_in(owner) |> live(overview_path(other_org))
      end
    end
  end

  # A project with no agent connection has nothing behind its product
  # screens, so the rail states that once, upfront, through the same
  # disabled-row treatment "Soon" already uses — rather than letting every
  # click bounce back to Connect with a re-flashed message.
  describe "locked project navigation (no agent connection yet)" do
    @locked_rows ~w(overview monitors issues traffic status_page changelog public_settings)

    defp connect_path(org, project), do: hub_path(org, project) <> "/connect"

    test "every project destination except MCP is a non-interactive MCP-required row", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(scope, org, %{name: "ALP+ SaaS"})

      {:ok, view, _html} = conn |> log_in(owner) |> live(connect_path(org, project))

      for row <- @locked_rows do
        assert has_element?(view, "#desktop-nav-#{row}[aria-disabled=true]")
        refute has_element?(view, "a#desktop-nav-#{row}")
      end

      # The prerequisite is said once, above the locked rows, never repeated
      # as a note on each of them.
      assert has_element?(
               view,
               "#desktop-nav-locked-note",
               "Connect an agent to manage this project."
             )

      refute render(view) =~ "MCP required"

      # MCP is the screen that resolves the lock, so it stays a real link and
      # is marked as the current page.
      assert has_element?(view, "a#desktop-nav-mcp[aria-current=page]", "MCP")

      # Leaving the project is never locked: the switcher, the org crumb and
      # the account footer stay usable.
      assert has_element?(view, "#desktop-nav-org-toggle", org.name)
      assert has_element?(view, "a#breadcrumbs-0")
      assert has_element?(view, "a#desktop-nav-account")
      assert has_element?(view, "#desktop-nav-account-team", "Team")
      assert has_element?(view, "#desktop-nav-sign-out", "Sign out")
    end

    test "the mobile drawer locks the same rows and keeps MCP reachable", %{conn: conn} do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(scope, org, %{name: "ALP+ SaaS"})

      {:ok, view, _html} = conn |> log_in(owner) |> live(connect_path(org, project))

      for row <- @locked_rows do
        assert has_element?(view, "#mobile-nav-#{row}[aria-disabled=true]")
        refute has_element?(view, "a#mobile-nav-#{row}")
      end

      assert has_element?(view, "a#mobile-nav-mcp", "MCP")
      assert has_element?(view, "#mobile-nav-org-toggle", org.name)
    end

    test "a connected project renders every destination as a link, with no MCP-required row", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(scope, org, %{name: "ALP+ SaaS"})
      agent_audit_fixture(scope, project)

      {:ok, view, _html} = conn |> log_in(owner) |> live(connect_path(org, project))

      for row <- @locked_rows do
        assert has_element?(view, "a#desktop-nav-#{row}")
        refute has_element?(view, "#desktop-nav-#{row}[aria-disabled=true]")
      end

      refute render(view) =~ "MCP required"
    end
  end

  describe "onboarding checklist" do
    test "reflects real state: project step is current with no project", %{conn: conn} do
      owner = user_fixture()
      {org, _scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      {:ok, view, _html} = conn |> log_in(owner) |> live(overview_path(org))

      assert has_element?(view, "#onboarding-checklist")
      # Organization step is done; creating a project is the current step.
      assert has_element?(view, "#onboarding-step-organization")
      assert has_element?(view, "#first-project-form")
      refute has_element?(view, "#onboarding-complete")
    end

    test "advances the project step once a project exists", %{conn: conn} do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      _project = project_fixture(scope, org)

      {:ok, view, _html} = conn |> log_in(owner) |> live(overview_path(org))

      # With a project present, the create-project affordance for the checklist
      # step is gone (that step is done); integrate is now the current step.
      refute has_element?(view, "#checklist-create-project")
      assert has_element?(view, "#onboarding-step-integrate")
    end
  end
end
