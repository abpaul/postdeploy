defmodule AlplusWeb.ObserveLiveTest do
  use AlplusWeb.ConnCase, async: true

  import Alplus.AuditFixtures
  import Alplus.OrgsFixtures

  import Phoenix.LiveViewTest

  alias Alplus.Observe.Issue
  alias Alplus.Scope

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp project_scope(scope, project), do: Scope.put_project(scope, project.id)

  defp issue_fixture(org, project, source, attrs \\ %{}) do
    now = DateTime.utc_now()

    params =
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
      )

    Ash.create!(Issue, params, action: :record, authorize?: false)
  end

  describe "no Sources yet: empty state" do
    test "shows the analysis empty state with agent task and repair link", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe")

      assert has_element?(view, "#observe-sources-empty")

      assert has_element?(
               view,
               "#observe-sources-empty-task",
               "Inspect this project's current health"
             )

      assert has_element?(view, "#copy-observe-sources-empty-task", "Copy task")

      assert has_element?(
               view,
               "#observe-sources-empty-action[href='/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/connect']"
             )

      refute has_element?(view, "#new-observe-source-button")
    end

    test "a member sees the same analysis-only empty state", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)
      member = user_fixture()
      member_fixture(owner_scope, org, member, "member")

      {:ok, view, _html} =
        conn
        |> log_in(member)
        |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe")

      assert has_element?(view, "#observe-sources-empty-action")
      refute has_element?(view, "#empty-new-observe-source-button")
      refute has_element?(view, "#observe-sources-forbidden")
    end
  end

  describe "with Sources: issue list" do
    test "renders the issue list and no Source cards", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)
      {prod_source, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
      {staging_source, _} = source_fixture(owner_scope, org, project, %{environment: "staging"})

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe")

      assert has_element?(view, "#observe-issues")
      refute has_element?(view, "#observe-error-overview")
      refute has_element?(view, "#observe-source-overviews")
      assert has_element?(view, "#window-select")
      refute has_element?(view, "#observe-source-#{prod_source.id}")
      refute has_element?(view, "#observe-source-#{staging_source.id}")
      refute has_element?(view, "#new-observe-source-button")
      refute has_element?(view, "#observe-sources-empty")
    end

    test "a member sees the issue list, with no Add source control", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)
      source_fixture(owner_scope, org, project)
      member = user_fixture()
      member_fixture(owner_scope, org, member, "member")

      {:ok, view, _html} =
        conn
        |> log_in(member)
        |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe")

      assert has_element?(view, "#observe-issues")
      refute has_element?(view, "#new-observe-source-button")
    end
  end

  describe "project-wide issue list" do
    test "lists open issues from every Source and links to the issue page", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)
      {prod, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
      {staging, _} = source_fixture(owner_scope, org, project, %{environment: "staging"})

      prod_issue = issue_fixture(org, project, prod, %{title: "Prod timeout"})

      staging_issue =
        issue_fixture(org, project, staging, %{
          title: "Staging timeout",
          fingerprint: "sha256:" <> String.duplicate("b", 64)
        })

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe")

      assert has_element?(view, "#observe-issues")
      refute has_element?(view, "#observe-issues-heading")
      assert has_element?(view, "#observe-issue-row-#{prod_issue.id} ~ div")
      assert has_element?(view, "#observe-issue-row-#{prod_issue.id}", "Prod timeout")
      assert has_element?(view, "#observe-issue-row-#{staging_issue.id}", "Staging timeout")
      assert has_element?(view, "#observe-issues-table", "production")
      assert has_element?(view, "#observe-issues-table", "staging")
      assert has_element?(view, "#observe-issue-source-#{prod_issue.id}", prod.name)
      assert has_element?(view, "#observe-issue-source-#{staging_issue.id}", staging.name)
      refute has_element?(view, "#observe-issues-table", "No culprit identified")
      refute has_element?(view, "#observe-resolve-issue-#{prod_issue.id}")

      issue_path =
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{prod_issue.id}"

      assert has_element?(view, "#observe-issue-row-#{prod_issue.id}[href='#{issue_path}']")
      assert has_element?(view, "#observe-issue-last-seen-#{prod_issue.id}", "just now")
    end

    test "paginates 201 project issues with URL page links", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)
      {source, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
      now = DateTime.utc_now()

      Enum.each(1..201, fn index ->
        seen_at = DateTime.add(now, -index, :second)

        issue_fixture(org, project, source, %{
          fingerprint:
            "sha256:" <>
              String.pad_leading(Base.encode16(<<index::32>>, case: :lower), 64, "0"),
          title: "Paginated issue #{index}",
          first_seen_at: seen_at,
          last_seen_at: seen_at
        })
      end)

      path = "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe"

      {:ok, view, _html} = conn |> log_in(owner) |> live(path)

      assert has_element?(view, "#observe-issues-pagination")
      assert has_element?(view, "#observe-issues-pagination a[href*='page=2']")
      refute has_element?(view, "#observe-issues-table", "Paginated issue 201")

      {:ok, page_five, _html} = conn |> log_in(owner) |> live(path <> "?page=5")

      assert has_element?(page_five, "#observe-issues-pagination")
      assert has_element?(page_five, "#observe-issues-table", "Paginated issue 201")
      assert has_element?(page_five, "#observe-issues-pagination-page-5[aria-current='page']")
    end

    test "does not list an issue from another project in the same org", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      subscribed_fixture(org)
      project_a = project_fixture(owner_scope, org)
      project_b = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project_a)
      {source_a, _} = source_fixture(owner_scope, org, project_a, %{environment: "production"})
      {source_b, _} = source_fixture(owner_scope, org, project_b, %{environment: "production"})
      issue_a = issue_fixture(org, project_a, source_a, %{title: "Project A boom"})
      issue_b = issue_fixture(org, project_b, source_b, %{title: "Project B boom"})

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live("/dashboard/orgs/#{org.public_token}/projects/#{project_a.public_token}/observe")

      assert has_element?(view, "#observe-issue-row-#{issue_a.id}")
      refute has_element?(view, "#observe-issue-row-#{issue_b.id}")
    end

    test "status and environment filters change the rows", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)
      {prod, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
      {staging, _} = source_fixture(owner_scope, org, project, %{environment: "staging"})
      open_issue = issue_fixture(org, project, prod, %{title: "Still open"})

      resolved_issue =
        issue_fixture(org, project, staging, %{
          title: "Already resolved",
          fingerprint: "sha256:" <> String.duplicate("c", 64)
        })

      Ash.update!(resolved_issue, %{},
        action: :resolve,
        actor: project_scope(owner_scope, project)
      )

      path = "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe"
      {:ok, view, _html} = conn |> log_in(owner) |> live(path)

      assert has_element?(view, "#observe-issue-row-#{open_issue.id}")
      refute has_element?(view, "#observe-issue-row-#{resolved_issue.id}")

      view
      |> element("#observe-issues-filters")
      |> render_change(%{"status" => "all"})

      assert has_element?(view, "#observe-issue-row-#{resolved_issue.id}")

      view
      |> element("#observe-issues-filters")
      |> render_change(%{"status" => "open", "environment" => "staging"})

      refute has_element?(view, "#observe-issue-row-#{open_issue.id}")
      refute has_element?(view, "#observe-issue-row-#{resolved_issue.id}")
    end

    test "shows the empty state when a Source exists but no issue matches", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)
      source_fixture(owner_scope, org, project)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe")

      assert has_element?(view, "#observe-issues-empty")
      refute has_element?(view, "#observe-issues-table")

      # The default view is filtered to Open because that is what the screen is
      # for. Nothing was narrowed, so nothing is offered to be cleared.
      refute has_element?(view, "#observe-issues-clear-filters")
      refute render(view) =~ "No issues match this filter."
      assert has_element?(view, "#observe-issues-quiet", "No events arrived in the last 24 hours")
      assert has_element?(view, "#observe-issues-widen-window", "Look at the last 7 days")
    end

    test "a narrowed list says so and offers the reset", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)
      {source, _} = source_fixture(owner_scope, org, project)
      issue_fixture(org, project, source, %{title: "Database timeout"})

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(
          "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe?q=nothingmatchesthis"
        )

      assert has_element?(view, "#observe-issues-empty", "No issues match this filter.")
      assert has_element?(view, "#observe-issues-clear-filters", "Clear filters")
      refute has_element?(view, "#observe-issues-quiet")
    end

    test "a quiet default list points at the resolved issues behind it", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)
      {source, _} = source_fixture(owner_scope, org, project)

      org
      |> issue_fixture(project, source, %{title: "Fixed already"})
      |> Ash.update!(%{}, action: :resolve, authorize?: false)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe")

      assert has_element?(view, "#observe-issues-quiet")
      assert has_element?(view, "#observe-issues-see-resolved", "See 1 resolved issue")

      resolved = element(view, "#observe-issues-see-resolved") |> render()
      assert resolved =~ "status=resolved"
    end

    test "Error overview shows the open-issue count across Sources", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)
      {prod, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
      {staging, _} = source_fixture(owner_scope, org, project, %{environment: "staging"})
      issue_fixture(org, project, prod, %{title: "Prod timeout"})

      issue_fixture(org, project, staging, %{
        title: "Staging timeout",
        fingerprint: "sha256:" <> String.duplicate("b", 64)
      })

      {:ok, view, html} =
        conn
        |> log_in(owner)
        |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe")

      # The open-issue count is the screen's title, and nothing restates it.
      assert has_element?(view, "h1", "2 open issues")
      assert length(Regex.scan(~r/2 open issues/, html)) == 1
    end
  end

  describe "activation" do
    test "the first open issue arriving flashes a success transition, not a silent swap", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)
      agent_audit_fixture(owner_scope, project)
      {source, _} = source_fixture(owner_scope, org, project)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe")

      refute render(view) =~ "Your first error arrived"

      issue_fixture(org, project, source)

      render_patch(
        view,
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe?window=24h"
      )

      assert render(view) =~ "Your first error arrived"

      reloaded = Ash.get!(Alplus.Projects.Project, project.id, actor: owner_scope)
      assert reloaded.observe_activated_at

      {:ok, remounted_view, remounted_html} =
        conn
        |> log_in(owner)
        |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe")

      refute remounted_html =~ "Your first error arrived"
      refute render(remounted_view) =~ "Your first error arrived"
    end
  end

  test "project selector navigates to an authorized sibling project", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org, %{name: "Current"})
    sibling = project_fixture(owner_scope, org, %{name: "Sibling"})
    agent_audit_fixture(owner_scope, project)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe")

    assert has_element?(view, "#project-select-input option[value='#{sibling.id}']", "Sibling")

    render_change(view, "pick_project", %{"project_id" => sibling.id})

    assert_redirect(
      view,
      "/dashboard/orgs/#{org.public_token}/projects/#{sibling.public_token}/observe"
    )
  end

  test "a cross-tenant project 404s before any Observe Source data leaks", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    _own_project = project_fixture(owner_scope, org)
    {other_org, other_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_scope, other_org)
    source_fixture(other_scope, other_org, other_project, %{type: :observe})

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{other_project.public_token}/observe"
      )
    end
  end

  test "a cross-org project token never renders another org's project", %{conn: conn} do
    owner_a = user_fixture()
    {org_a, scope_a} = org_fixture(Alplus.Scope.for_user(owner_a.id))
    project_a = project_fixture(scope_a, org_a)
    source_fixture(scope_a, org_a, project_a)

    owner_b = user_fixture()
    {org_b, scope_b} = org_fixture(Alplus.Scope.for_user(owner_b.id))
    project_fixture(scope_b, org_b)

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn
      |> log_in(owner_b)
      |> live("/dashboard/orgs/#{org_b.public_token}/projects/#{project_a.public_token}/observe")
    end
  end

  test "window pick, retry, and unknown messages stay on the page", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    source_fixture(scope, org, project)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe")

    render_click(view, "pick_window", %{"window" => "7d"})
    render_click(view, "retry_observe", %{})
    send(view.pid, :noise)
    assert has_element?(view, "#observe-error-overview") or render(view) =~ "Observe"
  end
end
