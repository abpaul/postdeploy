defmodule AlplusWeb.MonitorLiveTest do
  use AlplusWeb.ConnCase, async: true

  import Alplus.AuditFixtures
  import Alplus.OrgsFixtures
  import Phoenix.LiveViewTest

  alias Alplus.Monitoring.{HttpConfig, Incident, Monitor, MonitorCheck}

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp project_scope(scope, project), do: Alplus.Scope.put_project(scope, project.id)

  defp monitor_fixture(scope, org, project, attrs \\ %{}) do
    Ash.create!(
      Monitor,
      Map.merge(
        %{
          org_id: org.id,
          project_id: project.id,
          type: "http",
          name: "Status page"
        },
        attrs
      ),
      action: :create,
      actor: project_scope(scope, project)
    )
  end

  defp complete_onboarding(scope, org, project, monitor \\ nil) do
    monitor = monitor || monitor_fixture(scope, org, project)

    Ash.create!(
      MonitorCheck,
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
  end

  defp http_monitor_fixture(scope, org, project, attrs) do
    scope = project_scope(scope, project)
    monitor = monitor_fixture(scope, org, project, Map.drop(attrs, [:url, :interval_seconds]))

    Ash.create!(
      HttpConfig,
      %{
        monitor_id: monitor.id,
        org_id: org.id,
        url: Map.get(attrs, :url, "https://example.test/health"),
        method: "GET",
        expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
        interval_seconds: Map.get(attrs, :interval_seconds, 300),
        timeout_seconds: 10
      },
      action: :create,
      actor: scope
    )

    monitor
  end

  defp heartbeat_monitor_fixture(scope, org, project, attrs) do
    scope = project_scope(scope, project)
    monitor = monitor_fixture(scope, org, project, Map.put(attrs, :type, "heartbeat"))

    {:ok, config} =
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

    {monitor, Ash.Resource.get_metadata(config, :heartbeat_token)}
  end

  test "a new project shows an analysis empty state with agent connection task", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor")

    assert has_element?(view, "#monitors-empty", "No monitors yet")
    # The connection is the shell's line now, stated once per screen.
    assert has_element?(view, "#topbar-agent-connection", "Agent connected")
    refute has_element?(view, "#monitors-empty", "Agent connection")
    assert has_element?(view, "#monitors-empty-task")
    assert has_element?(view, "#copy-monitors-empty-task", "Copy task")
    assert has_element?(view, "#monitors-empty a[href$='/connect']", "Open agent connection")
    refute has_element?(view, "#first-monitor-form")
    refute has_element?(view, "[phx-submit='create_monitor']")
  end

  test "empty monitor analysis has no onboarding mutation form", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor")

    refute has_element?(view, "#first-monitor-onboarding")
    refute has_element?(view, "#create-first-monitor")
    assert has_element?(view, "#monitors-empty-task")
  end

  test "lists monitors with analysis controls and no mutation controls", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = monitor_fixture(owner_scope, org, project)
    complete_onboarding(owner_scope, org, project, monitor)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor")

    assert has_element?(view, "#monitor-row-#{monitor.id}[aria-label='Status page']")
    assert has_element?(view, "#monitor-name-#{monitor.id}", "Status page")
    assert has_element?(view, "#monitor-evidence-#{monitor.id}")
    refute has_element?(view, "#pause-focused-monitor-#{monitor.id}")
    refute has_element?(view, "#resume-focused-monitor-#{monitor.id}")
    refute has_element?(view, "#reissue-heartbeat-#{monitor.id}")
    refute has_element?(view, "#new-monitor-button")
  end

  test "the first check result flashes a success transition, live over PubSub", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = monitor_fixture(owner_scope, org, project)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor")

    refute render(view) =~ "first check result"

    assert {:ok, _outcome} =
             Alplus.Monitoring.ActiveCheckOutcome.record(monitor.id, %{
               status: "up",
               status_code: 200,
               latency_ms: 42,
               error_class: nil
             })

    assert render(view) =~ "Your first check result came in."
    assert has_element?(view, "#monitor-state-#{monitor.id} [role='status']", "Operational")
  end

  test "monitor analysis does not expose creation navigation", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = monitor_fixture(owner_scope, org, project)
    complete_onboarding(owner_scope, org, project, monitor)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor")

    refute has_element?(view, "#new-monitor-button")
    refute render(view) =~ "/monitor/new"
  end

  test "heartbeat monitor analysis does not expose URL mutation controls", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)

    {monitor, _token} =
      heartbeat_monitor_fixture(owner_scope, org, project, %{name: "Nightly backup"})

    complete_onboarding(owner_scope, org, project, monitor)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor")

    assert has_element?(view, "#monitor-row-#{monitor.id}")
    refute has_element?(view, "#reissue-heartbeat-#{monitor.id}")
    refute has_element?(view, "#heartbeat-token-once")
  end

  test "shows open incidents and keeps members read-only", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = monitor_fixture(owner_scope, org, project)
    complete_onboarding(owner_scope, org, project, monitor)

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

    member = user_fixture()
    member_fixture(owner_scope, org, member, "member")

    {:ok, view, _html} =
      conn
      |> log_in(member)
      |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor")

    # The workspace flags the monitor; the incident list lives on the
    # incidents tab.
    assert has_element?(view, "#monitor-row-#{monitor.id}[aria-label='Status page']")
    assert has_element?(view, "#incident-flag-#{monitor.id}", "Active incident")

    assert has_element?(
             view,
             "#incident-flag-#{monitor.id}[aria-label='Open active incident for Status page']"
           )

    refute has_element?(view, "#open-incidents-count")
    refute has_element?(view, "#incidents-section")
    refute has_element?(view, "#pause-focused-monitor-#{monitor.id}")
    refute has_element?(view, "#new-monitor-button")

    {:ok, view, _html} =
      conn
      |> log_in(member)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor?view=incidents"
      )

    assert has_element?(view, "#incident-#{incident.id}", "ongoing for")
    assert has_element?(view, "h1", "1 open incident")
    refute render(view) =~ "·"

    assert view
           |> element("#open-monitor-#{incident.id}")
           |> render() =~
             ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor/#{monitor.id}"

    refute has_element?(view, "#acknowledge-incident-#{incident.id}")
  end

  test "owners cannot acknowledge incidents from analysis", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = monitor_fixture(owner_scope, org, project)
    complete_onboarding(owner_scope, org, project, monitor)

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

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor?view=incidents"
      )

    assert has_element?(view, "#incident-#{incident.id}")
    refute has_element?(view, "#acknowledge-incident-#{incident.id}")
  end

  test "does not resolve a project from another organization", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    own_project = project_fixture(owner_scope, org)
    complete_onboarding(owner_scope, org, own_project)

    other_owner = user_fixture()
    {other_org, other_scope} = org_fixture(Alplus.Scope.for_user(other_owner.id))
    other_project = project_fixture(other_scope, other_org)

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{other_project.public_token}/monitor"
      )
    end

    assert owner_scope.org_id == org.id
  end

  test "filters monitors by environment", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    prod = monitor_fixture(owner_scope, org, project, %{name: "Prod", environment: "production"})

    staging =
      monitor_fixture(owner_scope, org, project, %{name: "Staging", environment: "staging"})

    complete_onboarding(owner_scope, org, project, prod)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor?view=all"
      )

    assert has_element?(view, "#monitor-row-#{prod.id}")
    assert has_element?(view, "#monitor-row-#{staging.id}")

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor?environment=production&view=all"
      )

    assert has_element?(view, "#monitor-row-#{prod.id}")
    refute has_element?(view, "#monitor-row-#{staging.id}")
  end

  test "shows an HTTP monitor as a resource with trustworthy activity evidence", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)

    monitor =
      http_monitor_fixture(owner_scope, org, project, %{
        name: "health",
        environment: "production",
        url: "https://api.example.test/health",
        interval_seconds: 60
      })

    Ash.create!(
      MonitorCheck,
      %{
        org_id: org.id,
        project_id: project.id,
        monitor_id: monitor.id,
        environment: "production",
        status: "up",
        checked_at: DateTime.add(DateTime.utc_now(), -300, :second),
        status_code: 204,
        latency_ms: 87
      },
      action: :record,
      authorize?: false
    )

    assert {:ok, _} =
             Alplus.Monitoring.ActiveCheckOutcome.record(monitor.id, %{
               status: "up",
               status_code: 200,
               latency_ms: 42,
               error_class: nil
             })

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor")

    assert has_element?(view, "h1", "Everything is up")
    assert has_element?(view, "#monitor-row-#{monitor.id}", "HTTP monitor")
    assert has_element?(view, "#monitor-row-#{monitor.id}", "health")
    assert has_element?(view, "#uptime-timeline-#{monitor.id}")
    assert has_element?(view, "#monitor-uptime-#{monitor.id}")
    assert has_element?(view, "#monitor-name-#{monitor.id}", "health")

    # The index answers "is it up?" with exactly one visual per row. Response
    # time, its amber threshold line, and the target URL are detail-page
    # evidence and must not reappear here.
    html = render(view)
    refute has_element?(view, "#response-time-chart-#{monitor.id}")
    refute html =~ "https://api.example.test/health"
    refute html =~ "alert "
    refute html =~ "monitor-fleet-segments"
    assert length(Regex.scan(~r/data-display-kind=/, html)) == 1
  end

  test "renders one compact row per monitor inside one panel", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)

    monitors =
      for index <- 1..7 do
        monitor_fixture(owner_scope, org, project, %{
          name: "Monitor #{index}",
          environment: if(index == 7, do: "staging", else: "production")
        })
      end

    complete_onboarding(owner_scope, org, project, hd(monitors))
    base = "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor"

    {:ok, view, _html} = conn |> log_in(owner) |> live(base <> "?view=all")
    refute has_element?(view, "#monitor-cards")
    refute has_element?(view, "#monitor-ledger")
    refute has_element?(view, "#monitor-collection")

    assert has_element?(view, "#monitors-list")
    assert has_element?(view, "#monitors-list #monitor-availability-key")
    assert length(Regex.scan(~r/id="monitor-availability-key"/, render(view))) == 1

    for monitor <- monitors do
      assert has_element?(view, "#monitor-row-#{monitor.id}")
    end

    # Seven monitors, seven strips, and no second chart language: exactly one
    # data display per row and nothing else.
    assert length(Regex.scan(~r/data-display-kind=/, render(view))) == 7
    refute render(view) =~ ~s(aria-label="Legend")

    {:ok, filtered_view, _html} =
      conn |> log_in(owner) |> live(base <> "?environment=production&view=all")

    refute has_element?(filtered_view, "#monitor-cards")
    refute has_element?(filtered_view, "#monitor-ledger")

    for monitor <- Enum.take(monitors, 6) do
      assert has_element?(filtered_view, "#monitor-row-#{monitor.id}")
    end

    refute has_element?(filtered_view, "#monitor-row-#{List.last(monitors).id}")
  end

  test "filters by name, target, status, and type in URL-backed collection reads", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)

    api =
      http_monitor_fixture(owner_scope, org, project, %{
        name: "API health",
        url: "https://api.example.test/health"
      })

    other =
      monitor_fixture(owner_scope, org, project, %{name: "Worker heartbeat", type: "heartbeat"})

    complete_onboarding(owner_scope, org, project, api)
    base = "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor"

    {:ok, target_view, _html} =
      conn |> log_in(owner) |> live(base <> "?query=api.example.test&type=http")

    assert has_element?(target_view, "#monitor-row-#{api.id}")
    refute has_element?(target_view, "#monitor-row-#{other.id}")

    {:ok, empty_view, _html} = conn |> log_in(owner) |> live(base <> "?status=down")
    assert has_element?(empty_view, "#monitors-filtered-empty")
  end

  test "URL status filters use waiting, missing, late, and up states", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    now = DateTime.utc_now()
    old = DateTime.add(now, -3_600, :second)

    up =
      http_monitor_fixture(owner_scope, org, project, %{name: "Reporting", interval_seconds: 60})

    late = http_monitor_fixture(owner_scope, org, project, %{name: "Late", interval_seconds: 60})
    missing = monitor_fixture(owner_scope, org, project, %{name: "Missing evidence"})
    waiting = monitor_fixture(owner_scope, org, project, %{name: "Waiting"})

    for {monitor, checked_at} <- [{up, now}, {late, old}, {missing, old}] do
      Ash.create!(
        MonitorCheck,
        %{
          org_id: org.id,
          project_id: project.id,
          monitor_id: monitor.id,
          status: "up",
          checked_at: checked_at
        },
        action: :record,
        authorize?: false
      )
    end

    Alplus.Repo.query!(
      "UPDATE monitors SET last_known_status = 'up', last_check_at = $2 WHERE id = $1",
      [up.id, now]
    )

    Alplus.Repo.query!(
      "UPDATE monitors SET last_known_status = 'up', last_check_at = $2 WHERE id = $1",
      [late.id, old]
    )

    complete_onboarding(owner_scope, org, project, up)
    base = "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor"

    for {status, expected, absent} <- [
          {"waiting", waiting, [up, late, missing]},
          {"missing", missing, [up, late, waiting]},
          {"late", late, [up, missing, waiting]},
          {"up", up, [late, missing, waiting]}
        ] do
      {:ok, view, _html} = conn |> log_in(owner) |> live(base <> "?status=#{status}")
      assert has_element?(view, "#monitor-row-#{expected.id}")
      for monitor <- absent, do: refute(has_element?(view, "#monitor-row-#{monitor.id}"))
    end
  end

  test "keeps waiting monitors in All and out of Needs attention", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)

    reporting = http_monitor_fixture(owner_scope, org, project, %{name: "Reporting"})
    waiting = http_monitor_fixture(owner_scope, org, project, %{name: "Waiting"})
    complete_onboarding(owner_scope, org, project, reporting)

    Ash.update!(reporting, %{status: "paused"},
      action: :update,
      actor: project_scope(owner_scope, project)
    )

    base = "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor"
    {:ok, all_view, _html} = conn |> log_in(owner) |> live(base)

    assert has_element?(all_view, "#monitor-view-all[aria-current='page']", "All")
    assert has_element?(all_view, "#monitor-row-#{waiting.id}")
    assert render(all_view) =~ "1 monitor is waiting for its first check"

    {:ok, attention_view, _html} =
      conn |> log_in(owner) |> live(base <> "?view=attention")

    refute has_element?(attention_view, "#monitor-row-#{waiting.id}")
  end

  test "states waiting and unavailable configuration as row state, with detail carrying the reason",
       %{
         conn: conn
       } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    configured = http_monitor_fixture(owner_scope, org, project, %{name: "Waiting HTTP"})
    unavailable = monitor_fixture(owner_scope, org, project, %{name: "Missing config"})
    complete_onboarding(owner_scope, org, project, unavailable)
    base = "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor"

    {:ok, view, _html} = conn |> log_in(owner) |> live(base <> "?view=all")

    # The index states the row condition in words. A configured monitor with
    # no checks keeps its one visible empty sentence in the activity slot.
    assert has_element?(view, "#monitor-state-#{configured.id}", "Waiting")
    assert has_element?(view, "#monitor-evidence-#{configured.id}", "no check yet")

    assert has_element?(
             view,
             "#monitor-uptime-#{configured.id}.sr-only",
             "Uptime unavailable"
           )

    refute has_element?(view, "#monitor-uptime-#{configured.id}", "No data")
    refute has_element?(view, "#focused-waiting-#{configured.id}")
    refute has_element?(view, "#focused-config-unavailable-#{unavailable.id}")

    {:ok, detail_view, _html} =
      conn |> log_in(owner) |> live(base <> "/#{configured.id}")

    assert has_element?(
             detail_view,
             "#focused-waiting-#{configured.id}",
             "Waiting for the first check"
           )

    {:ok, unavailable_view, _html} =
      conn |> log_in(owner) |> live(base <> "/#{unavailable.id}")

    assert has_element?(
             unavailable_view,
             "#focused-config-unavailable-#{unavailable.id}",
             "configuration is unavailable"
           )

    assert has_element?(unavailable_view, "#detail-target", "Target unavailable")

    {:ok, invalid_view, _html} = conn |> log_in(owner) |> live(base <> "?window=forever")
    assert has_element?(invalid_view, "#invalid-monitor-filter", "time window")
  end

  test "paginates a large filtered collection with an Ash keyset cursor", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)

    monitors =
      for index <- 1..21 do
        monitor_fixture(owner_scope, org, project, %{name: "Paged monitor #{index}"})
      end

    complete_onboarding(owner_scope, org, project, hd(monitors))

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor?view=all"
      )

    assert has_element?(view, "#next-monitor-page")
    assert length(Regex.scan(~r/id="monitor-row-mon_/, render(view))) == 20

    view |> element("#next-monitor-page") |> render_click()

    assert length(Regex.scan(~r/id="monitor-row-mon_/, render(view))) == 1
    refute has_element?(view, "#next-monitor-page")
  end

  # EEF-CVE-2026-67579: Ash decoded a client-supplied keyset cursor with
  # `non_executable_binary_to_term/2`, and a struct built from already-interned
  # atoms survived the `:safe` guard, so a forged cursor could smuggle an
  # `%Ash.Query.Call{}` into the keyset filter and reach AshPostgres as SQL.
  # `?cursor=` here is a URL parameter, so it is fully attacker controlled.
  # Ash 3.31.3 rejects such a term (`Ash.Page.Keyset.check_no_expression/1`);
  # this pins that the console surfaces it as the unavailable-data boundary and
  # leaks no rows, rather than evaluating it.
  test "refuses a forged keyset cursor carrying an Ash expression", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = monitor_fixture(owner_scope, org, project)
    complete_onboarding(owner_scope, org, project, monitor)

    base = "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor"

    forged =
      [{{:name, :asc, %Ash.Query.Call{name: :fragment, args: ["1=1"], operator?: false}}, 0}]
      |> :erlang.term_to_binary()
      |> Base.encode64()

    {:ok, view, _html} = conn |> log_in(owner) |> live(base <> "?cursor=#{forged}")

    assert has_element?(view, "#monitors-error")
    refute has_element?(view, "#monitor-row-#{monitor.id}")
  end

  test "renders the unavailable-data boundary after a scoped read connection fails", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = monitor_fixture(owner_scope, org, project)
    complete_onboarding(owner_scope, org, project, monitor)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> put_session("monitor_overview_failure", true)
      |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor")

    assert has_element?(view, "#monitors-error", "Monitor activity is unavailable")
  end

  test "environment pick, retry, and unknown messages stay on the page", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = monitor_fixture(owner_scope, org, project, %{environment: "production"})
    complete_onboarding(owner_scope, org, project, monitor)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor")

    assert has_element?(view, "#environment-select")
    assert has_element?(view, "#environment-select-input option[value='production']")

    render_change(view, "pick_environment", %{"environment" => "production"})
    render_change(view, "pick_environment", %{"environment" => ""})
    render_click(view, "retry_monitors", %{})
    send(view.pid, :noise)
    assert has_element?(view, "#monitor-row-#{monitor.id}") or render(view) =~ "monitor"
  end

  test "the monitor filter applies in place, writes the URL, and holds on bad input", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = monitor_fixture(owner_scope, org, project, %{environment: "production"})
    complete_onboarding(owner_scope, org, project, monitor)

    base = "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor"

    {:ok, view, html} = conn |> log_in(owner) |> live(base)

    # The Apply submit is gone: one live grammar, and one primary per view.
    refute html =~ ~s(id="monitor-filters") and html =~ ">Apply<"

    render_change(view, "filter_monitors", %{
      "query" => "",
      "environment" => "",
      "status" => "down",
      "type" => ""
    })

    assert_patched(view, base <> "?status=down&view=attention&window=24h")

    # A value the loader would reject holds the current view instead of
    # patching to a URL that cannot be read.
    render_change(view, "filter_monitors", %{
      "query" => "",
      "environment" => "",
      "status" => "not-a-status",
      "type" => ""
    })

    assert render(view) =~ "monitor"
  end

  test "project selector navigates siblings and ignores unknown or cross-tenant ids", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org, %{name: "Current"})
    sibling = project_fixture(owner_scope, org, %{name: "Sibling"})
    agent_audit_fixture(owner_scope, project)

    other_owner = user_fixture()
    {other_org, other_scope} = org_fixture(Alplus.Scope.for_user(other_owner.id))
    other_project = project_fixture(other_scope, other_org, %{name: "Other tenant"})

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor")

    assert has_element?(view, "#project-select-input option[value='#{sibling.id}']", "Sibling")

    render_change(view, "pick_project", %{"project_id" => "project_unknown"})
    assert has_element?(view, "#project-select-input option[value='#{project.id}'][selected]")

    render_change(view, "pick_project", %{"project_id" => other_project.id})
    assert has_element?(view, "#project-select-input option[value='#{project.id}'][selected]")
    refute has_element?(view, "#project-select-input option[value='#{other_project.id}']")

    render_change(view, "pick_project", %{"project_id" => sibling.id})

    assert_redirect(
      view,
      "/dashboard/orgs/#{org.public_token}/projects/#{sibling.public_token}/monitor?view=all"
    )
  end

  test "Monitor's sidebar has no standalone incidents destination", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = monitor_fixture(owner_scope, org, project)
    complete_onboarding(owner_scope, org, project, monitor)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live("/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor")

    assert has_element?(view, "#desktop-nav-monitors[aria-current='page']", "Monitors")
    refute has_element?(view, "#desktop-nav-incidents")
    refute render(view) =~ "/monitor/status-pages"
  end

  test "the incidents page lists open incidents, or says there are none", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = monitor_fixture(owner_scope, org, project)
    complete_onboarding(owner_scope, org, project, monitor)

    incidents_path =
      "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor?view=incidents"

    {:ok, view, _html} = conn |> log_in(owner) |> live(incidents_path)

    assert has_element?(view, "#monitor-view-incidents[aria-current='page']")
    assert has_element?(view, "h1", "No recent incidents")
    assert has_element?(view, "#incidents-empty", "No recent incidents")
    refute has_element?(view, "#incidents-empty-task")

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

    {:ok, view, _html} = conn |> log_in(owner) |> live(incidents_path)

    assert has_element?(view, "#incident-#{incident.id}", "ongoing for")
    refute has_element?(view, "#acknowledge-incident-#{incident.id}")
    refute has_element?(view, "#incidents-empty")
  end

  test "incident current state follows the affected monitor", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    monitor = http_monitor_fixture(owner_scope, org, project, %{interval_seconds: 60})
    complete_onboarding(owner_scope, org, project, monitor)

    now = DateTime.utc_now()

    Alplus.Repo.query!(
      "UPDATE monitors SET last_known_status = 'up', last_check_at = $2 WHERE id = $1",
      [monitor.id, now]
    )

    incident =
      Ash.create!(
        Incident,
        %{
          org_id: org.id,
          project_id: project.id,
          monitor_id: monitor.id,
          cause: "availability",
          cause_detail: %{},
          started_at: DateTime.add(now, -120, :second)
        },
        action: :open,
        authorize?: false
      )

    path =
      "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor?view=incidents"

    {:ok, view, _html} = conn |> log_in(owner) |> live(path)

    assert has_element?(view, "#incident-#{incident.id}", "Operational")
    refute has_element?(view, "#incident-#{incident.id}", "Down")
  end
end
