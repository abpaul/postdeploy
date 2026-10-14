defmodule AlplusWeb.MonitorDetailLiveTest do
  use AlplusWeb.ConnCase, async: true

  import Alplus.AuditFixtures
  import Alplus.OrgsFixtures
  import Phoenix.LiveViewTest

  alias Alplus.Monitoring.{DailyRollup, HttpConfig, Incident, Monitor, MonitorCheck}

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp project_scope(scope, project), do: Alplus.Scope.put_project(scope, project.id)

  defp monitor_fixture(scope, org, project, attrs) do
    Ash.create!(
      Monitor,
      Map.merge(
        %{org_id: org.id, project_id: project.id, type: "http", name: "Status page"},
        attrs
      ),
      action: :create,
      actor: project_scope(scope, project)
    )
  end

  defp http_monitor_fixture(scope, org, project, attrs \\ %{}) do
    scope = project_scope(scope, project)
    monitor = monitor_fixture(scope, org, project, Map.drop(attrs, [:url, :headers]))

    Ash.create!(
      HttpConfig,
      %{
        monitor_id: monitor.id,
        org_id: org.id,
        url: Map.get(attrs, :url, "https://example.test/health"),
        method: "GET",
        expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
        headers: Map.get(attrs, :headers),
        interval_seconds: 300,
        timeout_seconds: 10
      },
      action: :create,
      actor: scope
    )

    monitor
  end

  defp heartbeat_monitor_fixture(scope, org, project, attrs \\ %{}) do
    scope = project_scope(scope, project)
    monitor = monitor_fixture(scope, org, project, Map.put(attrs, :type, "heartbeat"))

    {:ok, _config} =
      Alplus.Monitoring.HeartbeatConfig
      |> Ash.Changeset.for_create(
        :issue,
        %{
          monitor_id: monitor.id,
          org_id: org.id,
          grace_period_seconds: 60,
          interval_seconds: 300
        },
        actor: scope
      )
      |> Ash.create()

    monitor
  end

  defp check_fixture(org, project, monitor, attrs) do
    Ash.create!(
      MonitorCheck,
      Map.merge(
        %{
          org_id: org.id,
          project_id: project.id,
          monitor_id: monitor.id,
          status: "up",
          checked_at: DateTime.utc_now()
        },
        attrs
      ),
      action: :record,
      authorize?: false
    )
  end

  defp detail_path(org, project, monitor),
    do:
      "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor/#{monitor.id}"

  test "shows the monitor header, target, config, and empty check history", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = http_monitor_fixture(owner_scope, org, project)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, monitor))

    assert has_element?(view, "#monitor-detail-page-heading", "Status page")
    assert has_element?(view, "#detail-target", "https://example.test/health")
    assert has_element?(view, "#monitor-config", "https://example.test/health")
    assert has_element?(view, "#recent-checks-empty", "No checks recorded yet")
    assert has_element?(view, "#monitor-incidents-empty", "No incidents recorded")
    # No evidence in the window yet (no checks), so uptime is honestly "No
    # data" — the shared Activity model only computes a ratio once evidence
    # exists (`MonitorOverview.activities!/3`), matching the index's waiting
    # state rather than faking a 100%.
    assert has_element?(view, "#monitor-metrics-waiting", "Waiting for the first check")
    refute has_element?(view, "#stat-uptime")
    assert has_element?(view, "#stat-check-count", "0")
  end

  test "accessible reliability details identify maintenance evidence", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    subscribed_fixture(org)
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = http_monitor_fixture(owner_scope, org, project, %{slo_target: 0.99})
    day = Date.add(Date.utc_today(), -8)

    Ash.Seed.seed!(DailyRollup, %{
      org_id: org.id,
      project_id: project.id,
      monitor_id: monitor.id,
      day: day,
      uptime_ratio: 1.0,
      monitored_microseconds: 300_000_000,
      downtime_microseconds: 0,
      check_count: 12
    })

    insert_pause_interval(org, project, monitor, day)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, monitor))

    assert has_element?(view, "#monitor-reliability", "Paused")
    assert render(view) =~ "1 maintenance pause"
  end

  test "renders exactly one visible h1 for the monitor", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = http_monitor_fixture(owner_scope, org, project)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, monitor))

    html = render(view)
    assert length(Regex.scan(~r/<h1[\s>]/, html)) == 1
    assert has_element?(view, "h1#monitor-detail-page-heading", monitor.name)
    refute has_element?(view, "#back-to-monitors")
  end

  test "owner detail redacts URL credentials, query secrets, and sensitive headers", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)

    monitor =
      http_monitor_fixture(owner_scope, org, project, %{
        url: "https://user:pass@example.test/health?token=private&ok=1",
        headers: %{"Authorization" => "Bearer private", "X-Request-ID" => "safe"}
      })

    {:ok, view, _html} = conn |> log_in(owner) |> live(detail_path(org, project, monitor))

    html = render(view)
    assert html =~ "https://example.test/health"
    assert html =~ "ok=1"
    assert html =~ "[REDACTED]"
    assert html =~ "X-Request-ID: safe"
    refute html =~ "user:pass"
    refute html =~ "private"
  end

  test "member detail also redacts sensitive monitor display values", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)

    monitor =
      http_monitor_fixture(owner_scope, org, project, %{
        url: "https://user:pass@example.test/health?secret=private",
        headers: %{"cookie" => "session=private"}
      })

    member = user_fixture()
    member_fixture(owner_scope, org, member, "member")

    {:ok, view, _html} = conn |> log_in(member) |> live(detail_path(org, project, monitor))

    html = render(view)
    assert html =~ "https://example.test/health"
    assert html =~ "[REDACTED]"
    refute html =~ "user:pass"
    refute html =~ "session=private"
  end

  test "renders the shared response-time chart and availability strip with enough evidence", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = http_monitor_fixture(owner_scope, org, project)

    check_fixture(org, project, monitor, %{
      status: "up",
      latency_ms: 120,
      status_code: 200,
      checked_at: DateTime.add(DateTime.utc_now(), -600, :second)
    })

    check_fixture(org, project, monitor, %{
      status: "up",
      latency_ms: 140,
      status_code: 200,
      checked_at: DateTime.utc_now()
    })

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, monitor))

    assert has_element?(view, "#response-time-chart-#{monitor.id}")
    assert has_element?(view, "#monitor-detail-timeline-#{monitor.id}")
    assert has_element?(view, "#monitor-detail-timeline-#{monitor.id}[data-display-kind='ticks']")

    assert has_element?(
             view,
             "#monitor-detail-timeline-#{monitor.id} [data-touch-tooltip='true']"
           )

    assert has_element?(view, "#monitor-detail-status-group > #monitor-panel-#{monitor.id}")
    assert has_element?(view, "#monitor-detail-status-group > #monitor-uptime")
    assert has_element?(view, "#monitor-detail-evidence-group > #recent-checks")
    assert has_element?(view, "#monitor-detail-evidence-group > #monitor-incidents")
    assert has_element?(view, "#monitor-latency")
    assert has_element?(view, "#monitor-config")
    assert has_element?(view, "#monitor-config-help[role='tooltip']")
    assert render(view) =~ "h-30 lg:h-40"
    refute render(view) =~ "latency-analysis-disclosure"
    refute render(view) =~ "latency-retention-notice"
    refute render(view) =~ "response-composition"
    assert has_element?(view, "#stat-check-count", "2")
    assert has_element?(view, "#stat-latest-latency", "140 ms")
    assert has_element?(view, "#stat-latest-latency", "HTTP 200")
  end

  test "availability keeps an older interval beyond the response sample cap", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = http_monitor_fixture(owner_scope, org, project)
    first_check_at = DateTime.add(DateTime.utc_now(), -121 * 60, :second)

    Enum.each(0..120, fn index ->
      check_fixture(org, project, monitor, %{
        status: if(index == 0, do: "down", else: "up"),
        checked_at: DateTime.add(first_check_at, index * 60, :second)
      })
    end)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, monitor))

    assert has_element?(view, "#monitor-detail-timeline-#{monitor.id}", "Down")
  end

  test "the full recent-checks list shows timestamp, status, latency, and response code", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = http_monitor_fixture(owner_scope, org, project)

    check =
      check_fixture(org, project, monitor, %{
        status: "down",
        latency_ms: 987,
        status_code: 503
      })

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, monitor))

    row = element(view, "#check-#{check.id}") |> render()
    assert row =~ "Down"
    assert row =~ "987 ms"
    assert row =~ "HTTP 503"
  end

  test "the full typed configuration lists every field", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = http_monitor_fixture(owner_scope, org, project)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, monitor))

    config = element(view, "#monitor-config") |> render()
    assert config =~ "https://example.test/health"
    assert config =~ "GET"
    assert config =~ "5 minutes"
    assert config =~ "10 seconds"
  end

  test "monitor detail keeps analysis controls and no lifecycle mutations", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = http_monitor_fixture(owner_scope, org, project)

    {:ok, view, _html} = conn |> log_in(owner) |> live(detail_path(org, project, monitor))

    assert has_element?(view, "#window-select")
    assert has_element?(view, "#recent-checks")
    assert has_element?(view, "#monitor-incidents")
    refute has_element?(view, "#detail-pause-monitor")
    refute has_element?(view, "#detail-resume-monitor")
    refute has_element?(view, "#detail-edit-monitor")
    refute has_element?(view, "#detail-delete-monitor")
  end

  test "a member cannot see mutation controls but can view the page", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = heartbeat_monitor_fixture(owner_scope, org, project)

    member = user_fixture()
    member_fixture(owner_scope, org, member, "member")

    {:ok, view, _html} =
      conn
      |> log_in(member)
      |> live(detail_path(org, project, monitor))

    assert has_element?(view, "#monitor-detail-page-heading", "Status page")
    refute has_element?(view, "#detail-pause-monitor")
    refute has_element?(view, "#detail-resume-monitor")
    refute has_element?(view, "#detail-reissue-heartbeat")
  end

  test "detail incident and heartbeat evidence have no mutation controls", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = http_monitor_fixture(owner_scope, org, project)

    incident =
      Ash.create!(
        Incident,
        %{
          org_id: org.id,
          project_id: project.id,
          monitor_id: monitor.id,
          cause: "availability",
          cause_detail: %{},
          started_at: DateTime.utc_now()
        },
        action: :open,
        authorize?: false
      )

    {:ok, view, _html} = conn |> log_in(owner) |> live(detail_path(org, project, monitor))

    assert has_element?(view, "#detail-incident-#{incident.id}", "availability")
    refute has_element?(view, "#detail-acknowledge-incident-#{incident.id}")
    refute has_element?(view, "#detail-reissue-heartbeat")
    refute has_element?(view, "#heartbeat-token-once")
  end

  test "switching the window control recomputes the metrics via a URL-backed window param", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = http_monitor_fixture(owner_scope, org, project)

    check_fixture(org, project, monitor, %{
      status: "up",
      latency_ms: 100,
      checked_at: DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)
    })

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, monitor))

    assert has_element?(view, "[aria-pressed=true]", "Last 24h")
    # The range is empty, the monitor is not: the notice names both facts.
    assert has_element?(view, "#monitor-metrics-waiting", "No checks in the last 24 hours")
    assert has_element?(view, "#monitor-metrics-waiting", "Last check 2 days ago")
    refute has_element?(view, "#monitor-metrics-waiting", "Waiting for the first check")

    view |> element("[phx-value-window='7d']") |> render_click()

    path = assert_patch(view)
    assert path =~ "window=7d"
    assert has_element?(view, "[aria-pressed=true]", "Last 7 days")
    assert has_element?(view, "#stat-check-count", "1")
  end

  test "recent checks default to the first 5, most recent first", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = http_monitor_fixture(owner_scope, org, project)

    checks =
      for i <- 1..7 do
        check_fixture(org, project, monitor, %{
          checked_at: DateTime.add(DateTime.utc_now(), -i * 60, :second)
        })
      end

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, monitor))

    assert has_element?(view, "#recent-checks-range", "Showing 1-5 of 7")

    for check <- Enum.take(checks, 5) do
      assert has_element?(view, "#check-#{check.id}")
    end

    for check <- Enum.drop(checks, 5) do
      refute has_element?(view, "#check-#{check.id}")
    end

    assert has_element?(view, "#checks-prev-page[disabled]")
    refute has_element?(view, "#checks-next-page[disabled]")
  end

  test "changing the page size shows that many checks and resets to page 0", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = http_monitor_fixture(owner_scope, org, project)

    checks =
      for i <- 1..12 do
        check_fixture(org, project, monitor, %{
          checked_at: DateTime.add(DateTime.utc_now(), -i * 60, :second)
        })
      end

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, monitor))

    view |> element("#checks-page-size-form") |> render_change(%{"size" => "15"})

    path = assert_patch(view)
    assert path =~ "checks_size=15"
    assert path =~ "checks_page=0"
    assert has_element?(view, "#recent-checks-range", "Showing 1-12 of 12")

    for check <- checks do
      assert has_element?(view, "#check-#{check.id}")
    end
  end

  test "the Next control paginates and stays URL-backed", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = http_monitor_fixture(owner_scope, org, project)

    checks =
      for i <- 1..7 do
        check_fixture(org, project, monitor, %{
          checked_at: DateTime.add(DateTime.utc_now(), -i * 60, :second)
        })
      end

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, monitor))

    view |> element("#checks-next-page") |> render_click()

    path = assert_patch(view)
    assert path =~ "checks_page=1"
    assert has_element?(view, "#recent-checks-range", "Showing 6-7 of 7")
    assert has_element?(view, "#checks-next-page[disabled]")
    refute has_element?(view, "#checks-prev-page[disabled]")

    for check <- Enum.drop(checks, 5) do
      assert has_element?(view, "#check-#{check.id}")
    end

    for check <- Enum.take(checks, 5) do
      refute has_element?(view, "#check-#{check.id}")
    end
  end

  test "a monitor outside the scoped project renders 404, never 403", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)

    other_owner = user_fixture()
    {other_org, other_scope} = org_fixture(Alplus.Scope.for_user(other_owner.id))
    other_project = project_fixture(other_scope, other_org)
    other_monitor = http_monitor_fixture(other_scope, other_org, other_project)

    conn = conn |> log_in(owner)

    assert_raise AlplusWeb.NotFoundError, fn ->
      live(conn, detail_path(org, project, other_monitor))
    end
  end

  test "an unknown project token renders 404 instead of leaking the monitor", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    monitor = http_monitor_fixture(owner_scope, org, project)

    conn = conn |> log_in(owner)

    assert_raise AlplusWeb.NotFoundError, fn ->
      live(
        conn,
        "/dashboard/orgs/#{org.public_token}/projects/notaprojecttoken00/monitor/#{monitor.id}"
      )
    end
  end

  test "an unknown monitor id renders 404 instead of leaking existence", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)

    conn = conn |> log_in(owner)

    assert_raise AlplusWeb.NotFoundError, fn ->
      live(
        conn,
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor/mon_doesnotexist"
      )
    end
  end

  test "detail ignores unknown messages and retains evidence without delete controls", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = http_monitor_fixture(owner_scope, org, project)

    {:ok, view, _html} = conn |> log_in(owner) |> live(detail_path(org, project, monitor))

    refute has_element?(view, "#detail-delete-monitor")
    send(view.pid, :not_a_real_message)
    assert render(view) =~ monitor.name
    render_click(view, "retry_load", %{})
    assert render(view) =~ monitor.name
  end

  test "tcp and dns detail pages render typed config rows", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    scope = project_scope(owner_scope, project)

    tcp =
      monitor_fixture(scope, org, project, %{type: "tcp", name: "DB"})

    Ash.create!(
      Alplus.Monitoring.TcpConfig,
      %{
        monitor_id: tcp.id,
        org_id: org.id,
        hostname: "db.example.test",
        port: 5432,
        timeout_seconds: 10,
        interval_seconds: 300
      },
      action: :create,
      actor: scope
    )

    {:ok, _view, html} = conn |> log_in(owner) |> live(detail_path(org, project, tcp))
    assert html =~ "db.example.test"
    assert html =~ "5432"

    dns =
      monitor_fixture(scope, org, project, %{type: "dns", name: "Edge"})

    Ash.create!(
      Alplus.Monitoring.DnsConfig,
      %{
        monitor_id: dns.id,
        org_id: org.id,
        hostname: "edge.example.test",
        record_type: "A",
        expected_values: ["1.2.3.4"],
        match_mode: :all,
        interval_seconds: 300
      },
      action: :create,
      actor: scope
    )

    {:ok, _dns_view, dns_html} = conn |> log_in(owner) |> live(detail_path(org, project, dns))
    assert dns_html =~ "edge.example.test"
    assert dns_html =~ "1.2.3.4"
  end

  test "owner and member detail surfaces expose no mutation controls", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = http_monitor_fixture(owner_scope, org, project)

    {:ok, owner_view, _html} = conn |> log_in(owner) |> live(detail_path(org, project, monitor))
    member = user_fixture()
    member_fixture(owner_scope, org, member, "member")
    {:ok, member_view, _html} = conn |> log_in(member) |> live(detail_path(org, project, monitor))

    for view <- [owner_view, member_view] do
      assert has_element?(view, "#monitor-detail-page-heading", "Status page")
      refute has_element?(view, "#detail-edit-monitor")
      refute has_element?(view, "#detail-delete-monitor")
      refute render(view) =~ "/monitor/new"
      refute render(view) =~ "/edit"
    end
  end

  defp insert_pause_interval(org, project, monitor, day) do
    paused_at = DateTime.new!(day, ~T[12:00:00], "Etc/UTC")
    resumed_at = DateTime.add(paused_at, 3_600, :second)

    Alplus.Repo.query!(
      """
      INSERT INTO monitor_pause_intervals
        (id, org_id, project_id, monitor_id, paused_at, resumed_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $5, $6)
      """,
      [
        Alplus.Id.generate(:monitor_pause_interval),
        org.id,
        project.id,
        monitor.id,
        paused_at,
        resumed_at
      ]
    )
  end
end
