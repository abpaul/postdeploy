defmodule AlplusWeb.ObserveDetailLiveTest do
  use AlplusWeb.ConnCase, async: true

  import Alplus.AuditFixtures
  import Alplus.OrgsFixtures
  import Phoenix.LiveViewTest

  alias Alplus.Observe.{EventWriter, Issue, Release}
  alias Alplus.Scope

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp project_scope(scope, project), do: Scope.put_project(scope, project.id)

  defp detail_path(org, project, source, params \\ %{}) do
    ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/#{source.id}?#{params}"
  end

  defp event(source, event_id, release, stack_marker) do
    now = ~U[2026-08-12 09:00:00.000000Z]

    %{
      event_id: event_id,
      org_id: source.org_id,
      project_id: source.project_id,
      source_id: source.id,
      environment: source.environment,
      occurred_at: now,
      received_at: now,
      level: "error",
      sdk_name: "@alplus/sdk",
      sdk_version: "0.3.0",
      exception_type: "TypeError",
      exception_value: "boom",
      frames: [%{file: "/src/#{stack_marker}.ts", function: "run", lineno: 1}],
      release: release
    }
  end

  defp issue_fixture(org, project, source, attrs) do
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

  defp release_fixture(scope, org, project, source, attrs) do
    Ash.create!(
      Release,
      Map.merge(
        %{
          org_id: org.id,
          project_id: project.id,
          source_id: source.id,
          environment: source.environment,
          released_at: ~U[2026-08-11 13:00:00.000000Z]
        },
        attrs
      ),
      actor: project_scope(scope, project)
    )
  end

  test "shows the Source panel, its graph, and its full issues list, scoped by source_id", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{environment: "production"})

    {other_source, _} = source_fixture(scope, org, project, %{environment: "staging"})

    prod_issue = issue_fixture(org, project, source, %{})

    staging_issue =
      issue_fixture(org, project, other_source, %{
        fingerprint: "sha256:" <> String.duplicate("b", 64)
      })

    {:ok, view, _html} =
      conn |> log_in(owner) |> live(detail_path(org, project, source, %{status: "all"}))

    assert has_element?(view, "#observe-panel-#{source.id}")
    assert has_element?(view, "#observe-detail-name", source.name)
    assert has_element?(view, "#observe-detail-issue-title-#{prod_issue.id}")
    refute has_element?(view, "#observe-detail-issue-title-#{staging_issue.id}")
  end

  test "a revoked Source and an active Source sharing one environment never share issues", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)

    {revoked, _} = source_fixture(scope, org, project, %{environment: "production"})
    Ash.update!(revoked, %{}, action: :revoke, actor: project_scope(scope, project))

    {active, _} = source_fixture(scope, org, project, %{environment: "production"})

    revoked_issue = issue_fixture(org, project, revoked, %{})

    active_issue =
      issue_fixture(org, project, active, %{
        fingerprint: "sha256:" <> String.duplicate("c", 64)
      })

    {:ok, revoked_view, _html} =
      conn |> log_in(owner) |> live(detail_path(org, project, revoked, %{status: "all"}))

    assert has_element?(revoked_view, "#observe-detail-issue-title-#{revoked_issue.id}")
    refute has_element?(revoked_view, "#observe-detail-issue-title-#{active_issue.id}")

    {:ok, active_view, _html} =
      conn |> log_in(owner) |> live(detail_path(org, project, active, %{status: "all"}))

    assert has_element?(active_view, "#observe-detail-issue-title-#{active_issue.id}")
    refute has_element?(active_view, "#observe-detail-issue-title-#{revoked_issue.id}")
  end

  test "owners see analysis only, without source or issue mutation controls", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _} = source_fixture(scope, org, project, %{environment: "production"})
    issue = issue_fixture(org, project, source, %{})

    {:ok, view, html} = conn |> log_in(owner) |> live(detail_path(org, project, source))

    assert has_element?(view, "#observe-detail-issue-title-#{issue.id}")
    refute has_element?(view, "#rotate-observe-detail-source")
    refute has_element?(view, "#revoke-observe-detail-source")
    refute has_element?(view, "#observe-detail-merge-selected")
    refute html =~ "phx-click=\"set_issue_status\""
  end

  test "shows the full releases list for this Source's environment, with health and crash-free",
       %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _} = source_fixture(scope, org, project, %{environment: "production"})

    older = release_fixture(scope, org, project, source, %{version: "1.0.0"})

    newer =
      release_fixture(scope, org, project, source, %{
        version: "1.1.0",
        released_at: ~U[2026-08-12 08:00:00.000000Z]
      })

    {:ok, %{issue_id: older_issue_id}} =
      EventWriter.record(event(source, "err_detail_older", "1.0.0", "older"))

    {:ok, %{issue_id: newer_issue_id}} =
      EventWriter.record(event(source, "err_detail_newer", "1.1.0", "newer"))

    older_issue = Ash.get!(Issue, older_issue_id, actor: project_scope(scope, project))

    Ash.update!(older_issue, %{resolved_in_release_id: newer.id},
      action: :resolve,
      actor: project_scope(scope, project)
    )

    {:ok, view, _html} = conn |> log_in(owner) |> live(detail_path(org, project, source))

    assert has_element?(view, "#observe-detail-source-status", "Active")
    assert has_element?(view, "#observe-detail-release-health")
    assert has_element?(view, "#observe-detail-releases-table")
    assert has_element?(view, "#observe-detail-release-new-issues-#{newer.id}", "1")
    assert has_element?(view, "#observe-detail-release-resolved-issues-#{newer.id}", "1")
    assert has_element?(view, "#observe-detail-release-artifacts-#{newer.id}", "No artifacts")
    assert has_element?(view, "#observe-detail-release-crash-free-#{older.id}", "Not enough data")

    refute newer_issue_id == older_issue_id
  end

  test "release history is paginated so older deployments remain reachable", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _} = source_fixture(scope, org, project, %{environment: "production"})
    base = ~U[2026-08-01 00:00:00.000000Z]

    releases =
      for n <- 1..101 do
        release_fixture(scope, org, project, source, %{
          version: "page-#{n}",
          released_at: DateTime.add(base, n, :second)
        })
      end

    oldest = List.first(releases)
    latest = List.last(releases)

    {:ok, first_page, _html} = conn |> log_in(owner) |> live(detail_path(org, project, source))

    assert has_element?(first_page, "#observe-detail-releases-pagination")
    assert has_element?(first_page, "#observe-detail-release-version-#{latest.id}", "page-101")
    refute has_element?(first_page, "#observe-detail-release-version-#{oldest.id}")

    {:ok, older_page, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, source, %{release_page: 2}))

    assert has_element?(older_page, "#observe-detail-release-version-#{oldest.id}", "page-1")
  end

  test "a cross-tenant Source id 404s, never 403s", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)

    {other_org, other_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_scope, other_org)
    {other_source, _} = source_fixture(other_scope, other_org, other_project)

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn |> log_in(owner) |> live(detail_path(org, project, other_source))
    end
  end

  test "a Monitor Source id in the same project 404s on this Observe route", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {monitor_source, _} = source_fixture(owner_scope, org, project, %{type: :monitor})

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn |> log_in(owner) |> live(detail_path(org, project, monitor_source))
    end
  end

  test "search filters issues by title or culprit substring, case-insensitive", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _} = source_fixture(scope, org, project, %{environment: "production"})

    timeout_issue =
      issue_fixture(org, project, source, %{title: "Database timeout", culprit: "Db.query/2"})

    payment_issue =
      issue_fixture(org, project, source, %{
        title: "PaymentError: card declined",
        culprit: "Billing.charge/1",
        fingerprint: "sha256:" <> String.duplicate("b", 64)
      })

    {:ok, view, _html} = conn |> log_in(owner) |> live(detail_path(org, project, source))

    assert has_element?(view, "#observe-detail-issue-title-#{timeout_issue.id}")
    assert has_element?(view, "#observe-detail-issue-title-#{payment_issue.id}")

    view
    |> element("#observe-detail-issue-filters")
    |> render_change(%{"q" => "payment"})

    assert has_element?(view, "#observe-detail-issue-title-#{payment_issue.id}")
    refute has_element?(view, "#observe-detail-issue-title-#{timeout_issue.id}")

    # A LIKE wildcard in the input matches literally, not as a wildcard.
    view
    |> element("#observe-detail-issue-filters")
    |> render_change(%{"q" => "%"})

    assert has_element?(view, "#observe-detail-issues-empty")

    # Culprit matches too.
    view
    |> element("#observe-detail-issue-filters")
    |> render_change(%{"q" => "db.query"})

    assert has_element?(view, "#observe-detail-issue-title-#{timeout_issue.id}")
    refute has_element?(view, "#observe-detail-issue-title-#{payment_issue.id}")
  end

  test "the level filter narrows the issue list", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _} = source_fixture(scope, org, project, %{environment: "production"})

    error_issue = issue_fixture(org, project, source, %{level: "error"})

    warning_issue =
      issue_fixture(org, project, source, %{
        level: "warning",
        title: "Deprecation warning",
        fingerprint: "sha256:" <> String.duplicate("c", 64)
      })

    {:ok, view, _html} = conn |> log_in(owner) |> live(detail_path(org, project, source))

    view
    |> element("#observe-detail-issue-filters")
    |> render_change(%{"level" => "warning"})

    assert has_element?(view, "#observe-detail-issue-title-#{warning_issue.id}")
    refute has_element?(view, "#observe-detail-issue-title-#{error_issue.id}")
  end

  test "a tag query shows only issues whose events carry that tag", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _} = source_fixture(scope, org, project, %{environment: "production"})

    {:ok, %{issue_id: mailer_id}} =
      EventWriter.record(
        event(source, "err_tag_mailer", "1.0.0", "mailer")
        |> Map.put(:tags, %{"component" => "mailer"})
      )

    {:ok, %{issue_id: web_id}} =
      EventWriter.record(
        event(source, "err_tag_web", "1.0.0", "web")
        |> Map.put(:tags, %{"component" => "web"})
        |> Map.put(:received_at, ~U[2026-08-12 09:00:02.000000Z])
      )

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, source, %{"tag" => "component:mailer"}))

    assert has_element?(view, "#observe-detail-tag-filter", "component:mailer")
    assert has_element?(view, "#observe-detail-issue-title-#{mailer_id}")
    refute has_element?(view, "#observe-detail-issue-title-#{web_id}")
  end
end
