defmodule AlplusWeb.ObserveIssueLiveTest do
  # async: false — the full-payload fetch tests stub
  # `Alplus.Observe.PayloadStore.Fake` through global `Application` env, the
  # same reason `error_ingest_controller_test.exs` opts out of async.
  use AlplusWeb.ConnCase, async: false

  import Alplus.AuditFixtures
  import Alplus.OrgsFixtures
  import Phoenix.LiveViewTest

  alias Alplus.Observe.{EventWriter, Issue, IssueEvidence, Release}

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp issue_fixture(org, project, attrs \\ %{}) do
    now = DateTime.utc_now()

    params =
      Map.merge(
        %{
          org_id: org.id,
          project_id: project.id,
          environment: "production",
          fingerprint: "sha256:" <> String.duplicate("a", 64),
          level: "error",
          title: "Database timeout",
          culprit: "Worker.perform/1",
          first_seen_at: now,
          last_seen_at: now,
          context_summary: %{"request_id" => "req-123"}
        },
        attrs
      )

    Ash.create!(Issue, params, action: :record, authorize?: false)
  end

  defp overflow_event(source, event_id, payload_s3_key) do
    now = ~U[2026-08-12 10:00:00.000000Z]

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
      payload_s3_key: payload_s3_key
    }
  end

  defp put_test_get_response(key, response) do
    responses =
      Application.get_env(:alplus, :observe_payload_store_test_gets, %{})
      |> Map.put(key, response)

    Application.put_env(:alplus, :observe_payload_store_test_gets, responses)
    on_exit(fn -> Application.delete_env(:alplus, :observe_payload_store_test_gets) end)
  end

  test "an owner sees issue analysis and no mutation controls", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    issue = issue_fixture(org, project)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{issue.id}"
      )

    assert has_element?(view, "h1", "Database timeout")
    assert has_element?(view, "#observe-issue-culprit", "Worker.perform/1")
    assert has_element?(view, "#observe-issue-context")
    refute has_element?(view, "#resolve-issue")
    refute has_element?(view, "#ignore-issue")
    refute has_element?(view, "#reopen-issue")
    refute has_element?(view, "#observe-issue-assign")
    refute has_element?(view, "#observe-issue-comment-form")
    refute has_element?(view, "#observe-issue-report-form")
  end

  test "a socket origin error leads with the problem and keeps the framework message as evidence",
       %{
         conn: conn
       } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)

    raw_error = """
    Could not check origin for Phoenix.Socket transport.

    Origin of the request: https://www.postdeploy.dev

    This happens when you are attempting a socket connection to
    a different host than the one configured in your config/ files.
    """

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(%{
        event_id: "err_socket_origin",
        org_id: org.id,
        project_id: project.id,
        source_id: source.id,
        environment: "production",
        occurred_at: DateTime.utc_now(),
        received_at: DateTime.utc_now(),
        level: "error",
        sdk_name: "phoenix",
        sdk_version: "1.8",
        message: raw_error,
        breadcrumbs: [
          %{
            "category" => "log",
            "message" => raw_error,
            "ts" => DateTime.utc_now()
          }
        ]
      })

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{issue_id}"
      )

    assert has_element?(view, "h1", "Socket connection blocked")

    assert has_element?(view, "#observe-issue-diagnosis", "Fix the socket origin")

    assert has_element?(view, "#observe-issue-diagnosis", "https://www.postdeploy.dev")
    assert has_element?(view, "#observe-issue-diagnosis", "Deploy the configuration change")

    assert has_element?(view, "#observe-issue-technical-details summary", "Technical details")

    assert has_element?(
             view,
             "#observe-issue-technical-details",
             "Could not check origin for Phoenix.Socket transport."
           )

    assert has_element?(
             view,
             "#observe-issue-technical-details",
             "Origin of the request: https://www.postdeploy.dev"
           )

    refute has_element?(view, "#observe-issue-culprit")
    refute has_element?(view, "#observe-issue-context-block")
    refute has_element?(view, "#observe-issue-breadcrumbs")
    refute has_element?(view, "#observe-issue-occurrences-block")
    refute has_element?(view, "#observe-issue-full-payload-block")
  end

  test "an issue with no captured context states so honestly, without fabricating evidence", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    issue = issue_fixture(org, project, %{context_summary: nil})

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{issue.id}"
      )

    refute has_element?(view, "#observe-issue-context")
    assert has_element?(view, "#observe-issue-no-context")
  end

  test "issue triage exposes impact, release, assignment, and keyboard views", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)

    issue =
      issue_fixture(org, project, %{
        release_first_seen: "2026.08.1",
        release_last_seen: "2026.08.2"
      })

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{issue.id}"
      )

    assert has_element?(view, "#observe-issue-header")
    refute has_element?(view, "#observe-issue-triage")
    assert has_element?(view, "#observe-issue-context-row")
    assert has_element?(view, "#observe-issue-release", "2026.08.2")
    assert has_element?(view, "#observe-issue-impact", "event")
    assert has_element?(view, "#observe-issue-assignment", "Unassigned")
    refute has_element?(view, "#observe-issue-assign-select")
    assert has_element?(view, "#observe-issue-tabs[role=tablist]")
    assert has_element?(view, "#observe-issue-tabs [role=tab]")
    assert has_element?(view, "#observe-issue-tabs-tab-event[aria-controls=observe-issue-event]")
    assert has_element?(view, "#observe-issue-comments[hidden][aria-hidden=true]")
    assert has_element?(view, "#observe-issue-reports[hidden][aria-hidden=true]")

    assert has_element?(
             view,
             "#observe-issue-event[role=tabpanel][aria-labelledby=observe-issue-tabs-tab-event]"
           )
  end

  test "evidence renders from a seeded event's frames, breadcrumbs, tags, and occurrences", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)

    now = ~U[2026-08-12 09:00:00.000000Z]

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(%{
        event_id: "err_evidence_view_1",
        org_id: org.id,
        project_id: project.id,
        source_id: source.id,
        environment: "production",
        occurred_at: now,
        received_at: now,
        level: "error",
        sdk_name: "@alplus/sdk",
        sdk_version: "0.3.0",
        exception_type: "TypeError",
        exception_value: "boom",
        frames: [
          %{file: "/src/app.ts", function: "run", lineno: 4, in_app: true},
          %{file: "/node_modules/lib/index.js", function: "callback", in_app: false}
        ],
        breadcrumbs: [%{"category" => "navigation", "message" => "checkout", "ts" => "09:00"}],
        tags: %{"build" => "main"},
        release: "1.0.0"
      })

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{issue_id}"
      )

    assert has_element?(view, "#observe-issue-stacktrace", "run @ /src/app.ts:4")
    assert has_element?(view, "#observe-issue-stacktrace", "callback")
    assert has_element?(view, "#observe-issue-breadcrumbs", "checkout")
    assert has_element?(view, "#observe-issue-tags", "build: main")
    refute has_element?(view, "#observe-issue-occurrences-block")
    refute has_element?(view, "#observe-issue-full-payload-block")
    refute has_element?(view, "#observe-issue-occurrence-table", "SDK")
    refute has_element?(view, "#observe-issue-occurrence-table", "1.0.0")
  end

  test "evidence renders source context, causes, user, mechanism, and per-event context", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)

    now = ~U[2026-08-12 09:00:00.000000Z]

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(%{
        event_id: "err_full_evidence_view",
        org_id: org.id,
        project_id: project.id,
        source_id: source.id,
        environment: "production",
        occurred_at: now,
        received_at: now,
        level: "error",
        sdk_name: "alplus-ruby",
        sdk_version: "0.3.0",
        exception_type: "WrapperError",
        exception_value: "outer",
        frames: [
          %{
            file: "app/models/order.rb",
            function: "charge!",
            lineno: 42,
            in_app: true,
            pre_context: ["  amount = total"],
            context_line: "  gateway.charge(amount)",
            post_context: ["end"]
          }
        ],
        causes: [%{type: "Timeout::Error", value: "expired", frames: nil}],
        context: %{"request" => %{"method" => "POST", "url" => "https://app.test/orders"}},
        user_id: "user_42",
        user_email: "person@example.com",
        mechanism: "rack.middleware"
      })

    {:ok, view, html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{issue_id}"
      )

    assert has_element?(view, "#observe-issue-stacktrace", "gateway.charge(amount)")
    assert has_element?(view, "#observe-issue-stacktrace", "amount = total")
    assert has_element?(view, "#observe-issue-causes", "Timeout::Error")
    assert has_element?(view, "#observe-issue-user", "user_42")
    assert has_element?(view, "#observe-issue-request", "https://app.test/orders")
    assert html =~ "Unhandled"
    assert has_element?(view, "#observe-issue-impact", "1 event")
    assert has_element?(view, "#observe-issue-impact", "1 user affected")
    refute html =~ "·"
  end

  test "a cause with the same stack as the wrapper keeps type and drops the frames", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)
    now = ~U[2026-08-12 09:00:00.000000Z]

    shared_frames = [
      %{file: "app/models/order.rb", function: "charge!", lineno: 42, in_app: true},
      %{file: "lib/rails/railtie.rb", function: "call", lineno: 10, in_app: false}
    ]

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(%{
        event_id: "err_dup_cause_stack",
        org_id: org.id,
        project_id: project.id,
        source_id: source.id,
        environment: "production",
        occurred_at: now,
        received_at: now,
        level: "error",
        sdk_name: "alplus-ruby",
        sdk_version: "0.3.0",
        exception_type: "RuntimeError",
        exception_value: "wrapper",
        frames: shared_frames,
        causes: [%{type: "ArgumentError", value: "root", frames: shared_frames}]
      })

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{issue_id}"
      )

    assert has_element?(view, "#observe-issue-stacktrace", "charge! @ app/models/order.rb:42")
    assert has_element?(view, "#observe-issue-causes", "ArgumentError")
    assert has_element?(view, "#observe-issue-causes", "root")
    refute has_element?(view, "#observe-issue-causes", "charge!")
  end

  test "a cause with its own frames still renders that stack", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)
    now = ~U[2026-08-12 09:00:00.000000Z]

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(%{
        event_id: "err_distinct_cause_stack",
        org_id: org.id,
        project_id: project.id,
        source_id: source.id,
        environment: "production",
        occurred_at: now,
        received_at: now,
        level: "error",
        sdk_name: "alplus-ruby",
        sdk_version: "0.3.0",
        exception_type: "RuntimeError",
        exception_value: "wrapper",
        frames: [%{file: "app/jobs/import.rb", function: "perform", lineno: 8, in_app: true}],
        causes: [
          %{
            type: "ArgumentError",
            value: "bad row",
            frames: [%{file: "app/models/row.rb", function: "parse!", lineno: 21, in_app: true}]
          }
        ]
      })

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{issue_id}"
      )

    assert has_element?(view, "#observe-issue-stacktrace", "perform @ app/jobs/import.rb:8")
    assert has_element?(view, "#observe-issue-causes", "parse! @ app/models/row.rb:21")
  end

  test "breadcrumbs render as a timeline: offsets, error divider, after-error lines", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)

    occurred_at = ~U[2026-08-12 09:00:10.000000Z]

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(%{
        event_id: "err_timeline_1",
        org_id: org.id,
        project_id: project.id,
        source_id: source.id,
        environment: "production",
        occurred_at: occurred_at,
        received_at: occurred_at,
        level: "error",
        sdk_name: "@alplus/sdk",
        sdk_version: "0.3.0",
        exception_type: "TypeError",
        exception_value: "boom",
        breadcrumbs: [
          %{
            "category" => "console",
            "message" => "loading cart",
            "level" => "info",
            "ts" => "2026-08-12T09:00:06.800Z"
          },
          %{
            "category" => "console",
            "message" => "retrying gateway",
            "level" => "warning",
            "ts" => "2026-08-12T09:00:10.800Z",
            "data" => %{"after_error" => true}
          },
          %{"category" => "console", "message" => "no timestamp line"}
        ]
      })

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{issue_id}"
      )

    assert has_element?(view, "#observe-issue-breadcrumbs", "-3.2s")
    assert has_element?(view, "#observe-issue-breadcrumbs", "+0.8s")
    assert has_element?(view, "#observe-issue-error-divider", "Error occurred")
    assert has_element?(view, "#observe-issue-breadcrumbs", "no timestamp line")
    # The after_error marker renders as the divider, never as line noise
    # in the timeline. The raw-event copy target may still contain the key.
    refute has_element?(view, "#observe-issue-breadcrumbs", "after_error")
  end

  test "an occurrence without after-error breadcrumbs shows no divider", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)
    now = ~U[2026-08-12 09:00:00.000000Z]

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(%{
        event_id: "err_timeline_2",
        org_id: org.id,
        project_id: project.id,
        source_id: source.id,
        environment: "production",
        occurred_at: now,
        received_at: now,
        level: "error",
        sdk_name: "@alplus/sdk",
        sdk_version: "0.3.0",
        exception_type: "TypeError",
        exception_value: "boom",
        breadcrumbs: [%{"category" => "navigation", "message" => "checkout", "ts" => "09:00"}]
      })

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{issue_id}"
      )

    assert has_element?(view, "#observe-issue-breadcrumbs", "checkout")
    refute has_element?(view, "#observe-issue-context-block")
    refute has_element?(view, "#observe-issue-error-divider")
  end

  test "selecting an older occurrence switches the rendered evidence", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)

    base = %{
      org_id: org.id,
      project_id: project.id,
      source_id: source.id,
      environment: "production",
      level: "error",
      sdk_name: "alplus-ruby",
      sdk_version: "0.3.0",
      exception_type: "TypeError",
      exception_value: "boom",
      frames: [%{file: "app/a.rb", function: "run", lineno: 1, in_app: true}]
    }

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(
        Map.merge(base, %{
          event_id: "err_occ_old",
          occurred_at: ~U[2026-08-12 09:00:00.000000Z],
          received_at: ~U[2026-08-12 09:00:00.000000Z],
          context: %{"marker" => "older-event"}
        })
      )

    {:ok, %{issue_id: ^issue_id}} =
      EventWriter.record(
        Map.merge(base, %{
          event_id: "err_occ_new",
          occurred_at: ~U[2026-08-12 09:05:00.000000Z],
          received_at: ~U[2026-08-12 09:05:00.000000Z],
          context: %{"marker" => "newest-event"}
        })
      )

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{issue_id}"
      )

    assert has_element?(view, "#observe-issue-context", "newest-event")

    view
    |> element("#select-occurrence-err_occ_old")
    |> render_click()

    assert has_element?(view, "#observe-issue-context", "older-event")
    assert has_element?(view, "#observe-issue-occurrence-table button[aria-pressed='true']")
    refute has_element?(view, "#observe-issue-occurrence-table", "SDK")

    view
    |> element("#observe-issue-tabs [role=tab][phx-value-tab=comments]")
    |> render_click()

    assert has_element?(view, "#observe-issue-comments[role=tabpanel]")
    assert has_element?(view, "#observe-issue-comments[aria-hidden=false]")
    assert has_element?(view, "#observe-issue-event[hidden][aria-hidden=true]")

    view
    |> element("#observe-issue-tabs [role=tab][phx-value-tab=event]")
    |> render_click()

    assert has_element?(view, "#observe-issue-context", "older-event")
  end

  test "Recent occurrences shows SDK only when the value changes across rows", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)

    base = %{
      org_id: org.id,
      project_id: project.id,
      source_id: source.id,
      environment: "production",
      level: "error",
      exception_type: "TypeError",
      exception_value: "boom",
      frames: [%{file: "app/a.rb", function: "run", lineno: 1, in_app: true}]
    }

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(
        Map.merge(base, %{
          event_id: "err_sdk_ruby",
          sdk_name: "alplus-ruby",
          sdk_version: "0.3.0",
          occurred_at: ~U[2026-08-12 09:00:00.000000Z],
          received_at: ~U[2026-08-12 09:00:00.000000Z]
        })
      )

    {:ok, %{issue_id: ^issue_id}} =
      EventWriter.record(
        Map.merge(base, %{
          event_id: "err_sdk_elixir",
          sdk_name: "alplus-elixir",
          sdk_version: "0.1.0",
          occurred_at: ~U[2026-08-12 09:05:00.000000Z],
          received_at: ~U[2026-08-12 09:05:00.000000Z]
        })
      )

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{issue_id}"
      )

    assert has_element?(view, "#observe-issue-occurrence-table", "SDK")
    assert has_element?(view, "#observe-issue-occurrence-table", "alplus-ruby")
    assert has_element?(view, "#observe-issue-occurrence-table", "alplus-elixir")
  end

  test "a canonical issue aggregates merged children; a child shows the merged banner", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)

    canonical =
      issue_fixture(org, project, %{source_id: source.id, title: "Canonical timeout"})

    child =
      issue_fixture(org, project, %{
        source_id: source.id,
        title: "Variant timeout",
        fingerprint: "sha256:" <> String.duplicate("e", 64)
      })

    scope = Alplus.Scope.put_project(owner_scope, project.id)
    Ash.update!(child, %{merged_into_issue_id: canonical.id}, action: :merge, actor: scope)

    path_prefix =
      "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues"

    {:ok, view, _html} = conn |> log_in(owner) |> live("#{path_prefix}/#{canonical.id}")

    assert has_element?(view, "#observe-issue-merged-children", "Variant timeout")

    child_page =
      IssueEvidence.merged_children_page(
        Alplus.Scope.put_project(owner_scope, project.id),
        canonical.id
      )

    assert Enum.map(child_page.results, & &1.id) == [child.id]
    assert child_page.more? == false
    assert has_element?(view, "#observe-issue-impact", "2 events")
    assert has_element?(view, "#observe-issue-merged-children", "Merged issues (1)")

    {:ok, child_view, _html} = conn |> log_in(owner) |> live("#{path_prefix}/#{child.id}")
    assert has_element?(child_view, "#observe-issue-merged-banner", "Canonical timeout")
  end

  test "fetching the full payload renders it on success", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)

    key = "events/#{project.id}/err_full_payload_ok.json"

    put_test_get_response(
      key,
      {:ok, ~s({"id":"err_full_payload_ok","message":"boom","token":"do-not-render"})}
    )

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(overflow_event(source, "err_full_payload_ok", key))

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{issue_id}"
      )

    assert has_element?(view, "#fetch-full-payload")
    view |> element("#fetch-full-payload") |> render_click()

    assert has_element?(view, "#observe-issue-full-payload", "err_full_payload_ok")
    refute has_element?(view, "#observe-issue-full-payload", "do-not-render")
    assert has_element?(view, "#observe-issue-full-payload", "[REDACTED]")
    refute has_element?(view, "#fetch-full-payload")
  end

  test "fetching the full payload renders the typed error when it is gone", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)

    key = "events/#{project.id}/err_full_payload_missing.json"
    put_test_get_response(key, {:error, :not_found})

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(overflow_event(source, "err_full_payload_missing", key))

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{issue_id}"
      )

    view |> element("#fetch-full-payload") |> render_click()

    assert has_element?(
             view,
             "#observe-issue-full-payload-error",
             "The full payload is no longer available."
           )

    assert has_element?(view, "#fetch-full-payload", "Retry loading full payload")

    view |> element("#fetch-full-payload") |> render_click()
    assert has_element?(view, "#observe-issue-full-payload-error")

    refute has_element?(view, "#observe-issue-full-payload")
  end

  test "request, highlights, copy targets, and stack controls render from a seeded event", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)
    now = DateTime.add(DateTime.utc_now(), -2, :day)

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(%{
        event_id: "err_ux_request",
        org_id: org.id,
        project_id: project.id,
        source_id: source.id,
        environment: "production",
        occurred_at: now,
        received_at: now,
        level: "error",
        sdk_name: "alplus-elixir",
        sdk_version: "0.1.0",
        exception_type: "RuntimeError",
        exception_value: "boom",
        frames: [
          %{file: "lib/app.ex", function: "App.run", lineno: 4, in_app: true},
          %{file: "lib/elixir.ex", function: "Elixir.eval", lineno: 1, in_app: false}
        ],
        context: %{
          "request" => %{
            "method" => "POST",
            "path" => "/orders",
            "host" => "app.test",
            "headers" => %{"user-agent" => "alplus-elixir/0.1"},
            "query" => %{"page" => "2"}
          },
          "os" => %{"name" => "macOS"}
        },
        tags: %{"component" => "mailer"}
      })

    {:ok, view, html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{issue_id}"
      )

    assert has_element?(view, "#observe-issue-request", "POST")
    assert has_element?(view, "#observe-issue-request", "/orders")
    assert has_element?(view, "#observe-issue-request", "user-agent")
    assert has_element?(view, "#observe-issue-request", "Query page")
    assert has_element?(view, "#observe-issue-highlights", "macOS")
    refute has_element?(view, "#observe-issue-highlights", "production")
    assert has_element?(view, "#observe-issue-event-context", "production")
    assert html =~ "Copy debugging context"
    assert html =~ "Copy raw event"
    assert html =~ "days ago"
    refute has_element?(view, "#observe-issue-meta")
    assert has_element?(view, "#observe-issue-tag-component")

    assert has_element?(view, "#observe-issue-stacktrace", "Elixir.eval")
    assert has_element?(view, "#observe-stack-status", "2 frames")

    view |> element("#observe-stack-in-app") |> render_click()
    refute has_element?(view, "#observe-issue-stacktrace", "Elixir.eval")
    assert has_element?(view, "#observe-issue-stacktrace", "App.run")
    assert has_element?(view, "#observe-stack-status", "1 in-app of 2")

    view |> element("#observe-stack-newest") |> render_click()
    assert has_element?(view, "#observe-stack-status", "callers first")

    view |> element("#observe-stack-raw") |> render_click()
    assert has_element?(view, "#observe-issue-stack-raw", "RuntimeError: boom")
    assert has_element?(view, "#observe-issue-stack-raw", "App.run @ lib/app.ex:4")
    assert has_element?(view, "#observe-stack-status", "raw dump")
  end

  test "Older and Newer move between occurrences", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)

    base = %{
      org_id: org.id,
      project_id: project.id,
      source_id: source.id,
      environment: "production",
      level: "error",
      sdk_name: "alplus-elixir",
      sdk_version: "0.1.0",
      exception_type: "TypeError",
      exception_value: "boom",
      frames: [%{file: "app/a.rb", function: "run", lineno: 1, in_app: true}]
    }

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(
        Map.merge(base, %{
          event_id: "err_nav_old",
          occurred_at: ~U[2026-08-12 09:00:00.000000Z],
          received_at: ~U[2026-08-12 09:00:00.000000Z],
          context: %{"marker" => "older-event"}
        })
      )

    {:ok, %{issue_id: ^issue_id}} =
      EventWriter.record(
        Map.merge(base, %{
          event_id: "err_nav_new",
          occurred_at: ~U[2026-08-12 09:05:00.000000Z],
          received_at: ~U[2026-08-12 09:05:00.000000Z],
          context: %{"marker" => "newest-event"}
        })
      )

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{issue_id}"
      )

    assert has_element?(view, "#observe-issue-context", "newest-event")
    assert has_element?(view, "#breadcrumbs-2[aria-current='page']", "Issues")
    assert has_element?(view, "#observe-issue-event-context", "err_nav_new")

    assert has_element?(
             view,
             "#observe-issue-event-context time[aria-label='12 Aug 2026, 09:05 UTC']"
           )

    assert has_element?(
             view,
             "#observe-issue-first-seen time[aria-label='12 Aug 2026, 09:00 UTC']"
           )

    assert has_element?(
             view,
             "#observe-issue-last-seen time[aria-label='12 Aug 2026, 09:05 UTC']"
           )

    view |> element("#observe-issue-older") |> render_click()
    assert has_element?(view, "#observe-issue-context", "older-event")
    assert has_element?(view, "#observe-issue-event-context", "err_nav_old")

    assert has_element?(
             view,
             "#observe-issue-event-context time[aria-label='12 Aug 2026, 09:00 UTC']"
           )

    view |> element("#observe-issue-newer") |> render_click()
    assert has_element?(view, "#observe-issue-context", "newest-event")
    assert has_element?(view, "#observe-issue-event-context", "err_nav_new")
  end

  test "a resolved issue shows its referenced release when a newer release exists", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)
    issue = issue_fixture(org, project, %{source_id: source.id})
    scope = Alplus.Scope.put_project(owner_scope, project.id)

    older_release =
      Ash.create!(
        Release,
        %{
          org_id: org.id,
          project_id: project.id,
          source_id: source.id,
          environment: "production",
          version: "1.0.0",
          released_at: ~U[2026-08-10 13:00:00.000000Z]
        },
        actor: scope
      )

    Ash.create!(
      Release,
      %{
        org_id: org.id,
        project_id: project.id,
        source_id: source.id,
        environment: "production",
        version: "2.0.0",
        released_at: ~U[2026-08-11 13:00:00.000000Z]
      },
      actor: scope
    )

    resolved_issue =
      Ash.update!(
        issue,
        %{resolved_in_release_id: older_release.id},
        action: :resolve,
        actor: scope
      )

    path =
      "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{resolved_issue.id}"

    {:ok, view, _html} = conn |> log_in(owner) |> live(path)

    assert has_element?(view, "#observe-issue-release", "1.0.0")
    refute has_element?(view, "#observe-issue-details")
    refute has_element?(view, "#observe-issue-release", "2.0.0")
  end

  test "an issue with no captured events renders no evidence, not a crash or a fabricated value",
       %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    issue = issue_fixture(org, project)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/issues/#{issue.id}"
      )

    refute has_element?(view, "#observe-issue-stacktrace")
    refute has_element?(view, "#observe-issue-breadcrumbs")
    refute has_element?(view, "#observe-issue-occurrences")
  end

  test "an issue id outside the selected project 404s", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    subscribed_fixture(org)
    project_a = project_fixture(owner_scope, org)
    project_b = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project_b)
    issue = issue_fixture(org, project_a)

    conn = log_in(conn, owner)

    assert_raise AlplusWeb.NotFoundError, fn ->
      live(
        conn,
        "/dashboard/orgs/#{org.public_token}/projects/#{project_b.public_token}/observe/issues/#{issue.id}"
      )
    end
  end

  test "an issue id from another org 404s, even for an owner who knows it", %{conn: conn} do
    owner_a = user_fixture()
    {org_a, scope_a} = org_fixture(Alplus.Scope.for_user(owner_a.id))
    project_a = project_fixture(scope_a, org_a)
    issue_a = issue_fixture(org_a, project_a)

    owner_b = user_fixture()
    {org_b, scope_b} = org_fixture(Alplus.Scope.for_user(owner_b.id))
    project_b = project_fixture(scope_b, org_b)
    agent_audit_fixture(scope_b, project_b)

    conn = log_in(conn, owner_b)

    assert_raise AlplusWeb.NotFoundError, fn ->
      live(
        conn,
        "/dashboard/orgs/#{org_b.public_token}/projects/#{project_b.public_token}/observe/issues/#{issue_a.id}"
      )
    end
  end

  test "an unknown project token 404s rather than guessing a project", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    issue = issue_fixture(org, project)

    conn = log_in(conn, owner)

    assert_raise AlplusWeb.NotFoundError, fn ->
      live(
        conn,
        "/dashboard/orgs/#{org.public_token}/projects/notaprojecttoken00/observe/issues/#{issue.id}"
      )
    end
  end
end
