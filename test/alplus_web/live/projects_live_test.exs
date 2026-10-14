defmodule AlplusWeb.ProjectsLiveTest do
  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures
  import Alplus.AuditFixtures

  require Ash.Query

  alias Alplus.Observe.Issue
  alias Alplus.Projects.Project

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp projects_path(org), do: ~p"/dashboard/orgs/#{org.public_token}/projects"

  defp issue_fixture(org, project, source, attrs \\ %{}) do
    now = DateTime.utc_now()

    Ash.create!(
      Issue,
      Map.merge(
        %{
          org_id: org.id,
          project_id: project.id,
          source_id: source.id,
          environment: source.environment,
          fingerprint: "sha256:" <> String.duplicate("a", 64),
          level: "error",
          title: "Database timeout",
          first_seen_at: now,
          last_seen_at: now
        },
        attrs
      ),
      action: :record,
      authorize?: false
    )
  end

  describe "tenant isolation" do
    test "lists only the current org's projects", %{conn: conn} do
      owner = user_fixture()
      {org_a, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project_a = project_fixture(owner_scope, org_a, %{name: "Project A"})

      other_owner = user_fixture()
      {org_b, other_scope} = org_fixture(Alplus.Scope.for_user(other_owner.id))
      _project_b = project_fixture(other_scope, org_b, %{name: "Project B"})

      {:ok, view, html} =
        conn
        |> log_in(owner)
        |> live(projects_path(org_a))

      assert html =~ "Project A"
      refute html =~ "Project B"
      assert has_element?(view, "#project-name-#{project_a.id}", "Project A")
    end

    test "a cross-tenant org id renders 404", %{conn: conn} do
      owner = user_fixture()
      {_org_a, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      other_owner = user_fixture()
      {org_b, _other_scope} = org_fixture(Alplus.Scope.for_user(other_owner.id))

      conn = log_in(conn, owner)

      assert_error_sent 404, fn ->
        live(conn, projects_path(org_b))
      end

      # sanity: owner_scope really has no membership in org_b
      assert {:error, :not_found} = Alplus.Orgs.build_scope(owner_scope, org_b.id)
    end

    test "another org's project id, requested through a page the actor can otherwise reach, is not found",
         %{conn: conn} do
      owner = user_fixture()
      {org_a, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      other_owner = user_fixture()
      {org_b, other_scope} = org_fixture(Alplus.Scope.for_user(other_owner.id))
      project_b = project_fixture(other_scope, org_b, %{name: "Project B"})

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(projects_path(org_a))

      # The actor is a real member of org_a (the page loads fine), but
      # org_b's project id must still not resolve here — 404, never 403
      # (ARCHITECTURE.md §4).
      render_click(view, "confirm_archive", %{"id" => project_b.id})

      refute has_element?(view, "#archive-project-#{project_b.id}-confirm")

      # the project itself is untouched
      assert {:ok, %Project{}} = Ash.get(Project, project_b.id, actor: other_scope)
    end

    test "batch signals ignore foreign project ids", %{conn: conn} do
      owner = user_fixture()
      {org_a, scope_a} = org_fixture(Alplus.Scope.for_user(owner.id))
      project_a = project_fixture(scope_a, org_a, %{name: "Visible"})

      other_owner = user_fixture()
      {org_b, scope_b} = org_fixture(Alplus.Scope.for_user(other_owner.id))
      project_b = project_fixture(scope_b, org_b, %{name: "Foreign"})

      signals = AlplusWeb.ProjectSignals.load_many([project_a, project_b], scope_a)

      assert Map.keys(signals) == [project_a.id]
      refute Map.has_key?(signals, project_b.id)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(projects_path(org_a))

      assert has_element?(view, "#project-name-#{project_a.id}", "Visible")
      refute has_element?(view, "#project-name-#{project_b.id}")
    end
  end

  test "a narrow project row keeps all pillar links visible", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(projects_path(org))

    assert has_element?(view, "#projects-#{project.id}")
    assert render(element(view, "#projects-#{project.id}")) =~ "sm:table-row"

    for pillar <- ~w(monitor observe measure) do
      element = element(view, "#project-#{project.id}-#{pillar}")
      rendered = render(element)

      refute rendered =~ ~s(class="hidden)
    end
  end

  test "load failure is exclusive of onboarding and populated project states" do
    html =
      render_component(&AlplusWeb.ProjectsLive.render/1, %{
        flash: %{},
        agent_connected?: false,
        org: %{name: "Example", public_token: "example", id: "org-1"},
        organizations: [],
        nav_projects: [],
        scope: %Alplus.Scope{org_id: "org-1", role: "owner"},
        current_user: nil,
        onboarding?: true,
        loading: false,
        load_failed?: true,
        checklist: [],
        projects: [],
        project_signals: %{}
      })

    assert html =~ ~s(id="projects-load-error")
    refute html =~ ~s(id="first-project-onboarding")
    refute html =~ ~s(id="projects-summary")
  end

  describe "role-correct UI" do
    test "a member sees no create control and cannot create by sending the event directly", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      member_user = user_fixture()
      member_fixture(owner_scope, org, member_user, "member")

      {:ok, view, html} =
        conn
        |> log_in(member_user)
        |> live(projects_path(org))

      refute html =~ ~s(id="new-project-form")
      refute has_element?(view, "#new-project-form")
      assert has_element?(view, "#onboarding-no-permission", "owner or admin")

      render_submit(view, "save", %{
        "project" => %{"org_id" => org.id, "name" => "Sneaky"}
      })

      projects = Alplus.Projects.list_projects_for_org!(org.id, actor: owner_scope)
      refute Enum.any?(projects, &(&1.name == "Sneaky"))
    end
  end

  describe "create and archive, as an owner" do
    test "a new organization sees only the first-value path and essential sidebar controls", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(projects_path(org))

      assert has_element?(view, "#first-project-onboarding")
      assert has_element?(view, "main.flex.items-center.justify-center")
      assert has_element?(view, "#first-project-form")
      assert has_element?(view, "#desktop-nav-sign-out")
      refute has_element?(view, "#desktop-nav-overview")
      refute has_element?(view, "#confirm-email-banner")
      refute has_element?(view, "#projects")
      refute has_element?(view, "#project-slug")
    end

    test "create appends a row and archive (with typed confirmation) removes it", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(projects_path(org))

      assert has_element?(view, "#first-project-onboarding")

      view
      |> form("#first-project-form", project: %{name: "Launchpad"})
      |> render_submit()

      assert %Project{id: project_id, public_token: project_token} =
               Ash.read_one!(
                 Ash.Query.filter(Project, name == "Launchpad"),
                 actor: owner_scope
               )

      assert_redirect(
        view,
        "/dashboard/orgs/#{org.public_token}/projects/#{project_token}/connect"
      )

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(projects_path(org))

      assert has_element?(view, "#project-name-#{project_id}", "Launchpad")

      view
      |> element("#archive-project-#{project_id}-trigger")
      |> render_click()

      assert has_element?(view, "#archive-project-#{project_id}-confirm")
      assert render(view) =~ "14-day grace period"

      render_change(view, "archive_input", %{
        "id" => project_id,
        "confirm_text" => "Launchpad"
      })

      view
      |> form("#archive-project-#{project_id}-form", %{
        "id" => project_id,
        "confirm_text" => "Launchpad"
      })
      |> render_submit()

      refute has_element?(view, "#project-name-#{project_id}")
      assert has_element?(view, "#first-project-onboarding")
      assert has_element?(view, "#first-project-form")
      refute has_element?(view, "#projects-summary")
      refute has_element?(view, "#projects-empty")

      assert {:error, %Ash.Error.Invalid{}} = Ash.get(Project, project_id, actor: owner_scope)

      archived_row = Alplus.Repo.get(Project, project_id)
      assert archived_row.archived_at
    end

    test "primary project link resumes connection until an allowed agent call exists", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org, %{name: "Activation"})
      conn = log_in(conn, owner)

      {:ok, view, _html} = live(conn, projects_path(org))

      assert has_element?(
               view,
               "#open-project-#{project.id}[href='/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/connect']"
             )

      agent_audit_fixture(owner_scope, project, "webmcp")

      {:ok, resumed, _html} = live(conn, projects_path(org))

      assert has_element?(
               resumed,
               "#open-project-#{project.id}[href='/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}']"
             )
    end

    test "a member of a connected project gets the project link, not Connect", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org, %{name: "Shared"})
      member = user_fixture()
      member_fixture(owner_scope, org, member, "member")

      agent_audit_fixture(owner_scope, project, "remote_mcp")

      {:ok, view, _html} = live(log_in(conn, member), projects_path(org))

      # The audit read policy admits owners and admins only, so a member
      # must never be routed back to Connect for a project their agent
      # has already reached.
      assert has_element?(
               view,
               "#open-project-#{project.id}[href='/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}']"
             )
    end

    test "archiving one project refreshes remaining signals", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      retiring = project_fixture(owner_scope, org, %{name: "Retire"})
      remaining = project_fixture(owner_scope, org, %{name: "Keep"})
      {source, _secret} = source_fixture(owner_scope, org, retiring)
      issue_fixture(org, retiring, source)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(projects_path(org))

      assert has_element?(view, "#stat-issues-open", "1")
      assert has_element?(view, "#projects-summary", "1 open issue")

      view
      |> element("#archive-project-#{retiring.id}-trigger")
      |> render_click()

      render_change(view, "archive_input", %{
        "id" => retiring.id,
        "confirm_text" => "Retire"
      })

      view
      |> form("#archive-project-#{retiring.id}-form", %{
        "id" => retiring.id,
        "confirm_text" => "Retire"
      })
      |> render_submit()

      refute has_element?(view, "#project-name-#{retiring.id}")
      assert has_element?(view, "#project-name-#{remaining.id}", "Keep")
      assert has_element?(view, "#stat-issues-open", "0")
      assert has_element?(view, "#projects-summary", "Waiting for the first check")
      assert has_element?(view, "#projects-summary", "Across 1 project")
    end

    test "organization totals distinguish no source, no series, and a real zero", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      no_source = project_fixture(owner_scope, org, %{name: "No analytics"})
      no_series = project_fixture(owner_scope, org, %{name: "No traffic"})
      {_no_series_source, _} = source_fixture(owner_scope, org, no_series, %{type: :measure})

      zero = project_fixture(owner_scope, org, %{name: "Zero traffic"})
      {zero_source, _} = source_fixture(owner_scope, org, zero, %{type: :measure})

      Alplus.Measure.Rollups.record!(
        zero,
        zero_source.id,
        zero_source.environment,
        %{type: "pageview", path: "/", hostname: "example.test"},
        %{pageviews: 0, visitors: 0, visits: 0, bounces: 0, duration_seconds: 0},
        DateTime.utc_now()
      )

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(projects_path(org))

      assert has_element?(view, "#project-#{no_source.id}-measure", "No analytics yet")

      assert has_element?(
               view,
               "#project-#{no_source.id}-measure[data-state=empty]",
               "No analytics yet"
             )

      assert has_element?(view, "#project-#{no_series.id}-measure", "No traffic yet")

      assert has_element?(
               view,
               "#project-#{no_series.id}-measure[data-state=empty]",
               "No traffic yet"
             )

      assert has_element?(view, "#project-#{zero.id}-measure", "0 views, 7d")

      assert has_element?(
               view,
               "#project-#{zero.id}-measure[data-state=available]",
               "0 views, 7d"
             )

      assert has_element?(view, "#stat-pageviews", "0")
    end
  end

  describe "onboarding checklist (onboarding overhaul §4)" do
    test "refreshes project and Source rows without a broadcast", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(projects_path(org))

      assert has_element?(view, "#onboarding-step-project[data-state=current]")

      project = project_fixture(owner_scope, org)
      send(view.pid, :refresh_onboarding)

      assert has_element?(view, "#projects-summary")
      assert has_element?(view, "#onboarding-step-project[data-state=done]")

      source_fixture(owner_scope, org, project)
      send(view.pid, :refresh_onboarding)

      assert has_element?(view, "#onboarding-step-integrate[data-state=done]")
      assert has_element?(view, "#onboarding-step-first_value[data-state=current]")
    end

    test "refreshes Issue rows into the derived first-value state", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      {source, _secret} = source_fixture(owner_scope, org, project)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(projects_path(org))

      assert has_element?(view, "#onboarding-step-first_value[data-state=current]")

      issue_fixture(org, project, source)
      send(view.pid, :refresh_onboarding)

      assert has_element?(view, "#onboarding-just-completed", "You're live")
      refute has_element?(view, "#onboarding-checklist")
    end

    test "refreshes AnalyticsDay rows into the derived first-value state", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      {source, _secret} = source_fixture(owner_scope, org, project, %{type: :measure})

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(projects_path(org))

      assert has_element?(view, "#onboarding-step-first_value[data-state=current]")

      Alplus.Measure.Rollups.record!(
        project,
        source.id,
        source.environment,
        %{type: "pageview", path: "/", hostname: "example.test"},
        %{pageviews: 1, visitors: 1, visits: 1, bounces: 0, duration_seconds: 0},
        DateTime.utc_now()
      )

      send(view.pid, :refresh_onboarding)

      assert has_element?(view, "#onboarding-just-completed", "You're live")
      refute has_element?(view, "#onboarding-checklist")
    end

    test "flips to 'You're live' the moment a check result lands, via PubSub", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      project_scope = Alplus.Scope.put_project(owner_scope, project.id)

      monitor =
        Ash.create!(
          Alplus.Monitoring.Monitor,
          %{org_id: org.id, project_id: project.id, name: "Homepage", type: "http"},
          action: :create,
          actor: project_scope
        )

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(projects_path(org))

      assert has_element?(view, "#onboarding-checklist")
      refute has_element?(view, "#onboarding-just-completed")

      Ash.create!(
        Alplus.Monitoring.MonitorCheck,
        %{
          org_id: org.id,
          project_id: project.id,
          monitor_id: monitor.id,
          status: "up",
          checked_at: DateTime.utc_now()
        },
        action: :record,
        authorize?: false
      )

      Phoenix.PubSub.broadcast(
        Alplus.PubSub,
        "monitor:#{project.id}",
        {:monitor_updated, project.id}
      )

      assert has_element?(view, "#onboarding-just-completed", "You're live")
      refute has_element?(view, "#onboarding-checklist")
    end
  end

  describe "package project limit" do
    test "an owner at the package limit sees no create control and a limit note", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      subscribed_fixture(org)

      for _ <- 1..Alplus.Billing.Package.limit(:projects),
          do: project_fixture(owner_scope, org)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(projects_path(org))

      refute has_element?(view, "#new-project-toggle")
      assert has_element?(view, "#project-limit-note", "PostDeploy includes")
    end

    test "archiving frees a slot and restores the create control", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      subscribed_fixture(org)
      project = project_fixture(owner_scope, org, %{name: "Only One"})
      limit = Alplus.Billing.Package.limit(:projects)
      for _ <- 2..limit, do: project_fixture(owner_scope, org)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(projects_path(org))

      refute has_element?(view, "#new-project-toggle")

      view |> element("#archive-project-#{project.id}-trigger") |> render_click()

      render_change(view, "archive_input", %{
        "id" => project.id,
        "confirm_text" => "Only One"
      })

      view
      |> form("#archive-project-#{project.id}-form", %{
        "id" => project.id,
        "confirm_text" => "Only One"
      })
      |> render_submit()

      assert has_element?(view, "#new-project-toggle")
      refute has_element?(view, "#project-limit-note")
    end

    test "toggle, validate, cancel archive, and ignore unknown messages", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org, %{name: "Alpha"})
      subscribed_fixture(org)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(projects_path(org))

      render_click(view, "toggle_new_project", %{})
      assert has_element?(view, "#new-project-form")

      view
      |> form("#new-project-form", project: %{name: "Beta", org_id: org.id})
      |> render_change()

      view |> element("#archive-project-#{project.id}-trigger") |> render_click()

      assert has_element?(
               view,
               "#projects-content[phx-hook='AlplusWeb.ProjectsLive.ProjectsArchiveFocus']"
             )

      assert has_element?(
               view,
               "#projects-content[data-archive-focus-id=archive-project-#{project.id}-trigger]"
             )

      render_click(view, "cancel_archive", %{"id" => project.id})
      refute has_element?(view, "#projects-content[data-archive-focus-id]")
      send(view.pid, {:observe_updated, project.id})
      send(view.pid, :noise)
      assert render(view) =~ "Alpha"
    end
  end
end
