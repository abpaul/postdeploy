defmodule AlplusWeb.MeasureDetailLiveTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.AuditFixtures
  import Alplus.OrgsFixtures
  import Phoenix.LiveViewTest

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp detail_path(org, project, source, params \\ %{}) do
    ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/measure/#{source.id}?#{params}"
  end

  defp analytics_queries(view, action) do
    handler = {__MODULE__, make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        [:alplus, :repo, :query],
        fn _, _, metadata, {owner, caller} ->
          if self() == caller and
               String.contains?(metadata.query, [
                 "analytics_days",
                 "analytics_hours",
                 "analytics_dimensions"
               ]) do
            send(owner, {:measure_query, metadata})
          end
        end,
        {test_pid, view.pid}
      )

    try do
      action.()
      drain_analytics_queries([])
    after
      :telemetry.detach(handler)
    end
  end

  defp drain_analytics_queries(queries) do
    receive do
      {:measure_query, query} -> drain_analytics_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  # Every parameter the screen keeps in its URL, at the first page of each
  # breakdown.
  defp url_params(overrides) do
    Map.merge(
      %{window: "30d", metric: "visits", pages_page: 1, sources_page: 1, events_page: 1},
      overrides
    )
  end

  # The read is honest about coverage: a bucket before the site was connected
  # is unmeasured, never zero. A fixture that wants a history to compare
  # against has to have been collecting across it.
  defp collecting_since!(source, days) do
    connected_at = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    Alplus.Repo.query!("UPDATE sources SET inserted_at = $1 WHERE id = $2", [
      connected_at,
      source.id
    ])

    %{source | inserted_at: connected_at}
  end

  # A subscribed organization keeps the package's rollup retention, so a
  # 30-day window's preceding equal period is covered rather than pruned.
  defp retain_90_days!(org) do
    Alplus.Repo.query!(
      "UPDATE organizations SET plan_status = 'active', plan_id = 'postdeploy' WHERE id = $1",
      [org.id]
    )
  end

  defp record!(org, project, source, deltas, at) do
    Alplus.Measure.Rollups.record!(
      %{id: project.id, org_id: org.id},
      source.id,
      "production",
      %{type: "pageview", path: "/pricing", hostname: "example.com"},
      deltas,
      at
    )
  end

  defp refute_mutation_controls(view) do
    mutation_events = ~w(
      create_site toggle_create_site cancel_create_site validate_site
      rotate_measure_source confirm_revoke_measure_source cancel_revoke_measure_source
      revoke_measure_source_input revoke_measure_source
      generate_measure_share validate_measure_share save_measure_share rotate_measure_share
    )

    refute has_element?(view, "form")

    for attribute <- ~w(phx-click phx-submit phx-change), event <- mutation_events do
      refute has_element?(view, "[#{attribute}='#{event}']")
    end

    mutation_actions =
      ~w(create edit publish unpublish pause resume acknowledge reissue archive restore rotate revoke retire resolve schedule cancel delete lifecycle)

    for action <- mutation_actions do
      refute has_element?(view, "[id*='#{action}']")
      refute has_element?(view, "a[href$='/#{action}']")
    end

    refute has_element?(view, "a[href$='/new']")
    refute has_element?(view, "a[href$='/edit']")
  end

  test "the site name is the title and the storage engine stays out of the copy", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :measure})

    {:ok, view, html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, source))

    refute_mutation_controls(view)

    assert has_element?(view, "h1", source.name)
    assert length(Regex.scan(~r/<h1\b/, html)) == 1
    assert has_element?(view, "#measure-panel-#{source.id}")
    assert has_element?(view, "#measure-detail-hostname")
    refute has_element?(view, "#measure-detail-data-source")
    refute render(view) =~ "PostgreSQL"
    refute render(view) =~ "Analytics Engine"
    refute has_element?(view, "#measure-detail-snippet")

    render_change(view, "pick_window", %{"window" => "30d"})

    assert_patch(view, detail_path(org, project, source, url_params(%{})))
  end

  test "traffic for one site never bleeds into a sibling site's detail (Model A isolation)", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)

    {source_a, _} =
      source_fixture(scope, org, project, %{type: :measure, environment: "production"})

    {source_b, _} =
      source_fixture(scope, org, project, %{type: :measure, environment: "production"})

    record!(
      org,
      project,
      source_a,
      %{pageviews: 5, visitors: 4, visits: 4, bounces: 0, duration_seconds: 10},
      DateTime.utc_now()
    )

    {:ok, view_a, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, source_a, %{window: "30d"}))

    assert has_element?(view_a, "#breadcrumbs-2[aria-current='page']", "Traffic")
    refute has_element?(view_a, "#breadcrumbs", "Measure")

    {:ok, view_b, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, source_b, %{window: "30d"}))

    assert has_element?(view_a, "#measure-detail-metric-pageviews", "5")
    assert has_element?(view_a, "#measure-detail-metric-visits", "4")

    # Both sites were connected today, so the 29 days before that are a
    # genuine gap rather than 29 zeros, and the shortfall is one caption.
    assert has_element?(
             view_a,
             "#measure-comparison-chart-#{source_a.id}-coverage",
             "Measured on 1 of 30 days."
           )

    refute has_element?(view_a, "#measure-detail-change")

    assert has_element?(view_b, "#measure-detail-metric-visits", "0")

    # The empty chart says what it is waiting for, inside its own frame.
    assert has_element?(
             view_b,
             "#measure-comparison-chart-#{source_b.id}-empty",
             "Waiting for the first pageview"
           )

    refute has_element?(view_b, "#measure-detail-coverage")
    refute has_element?(view_b, "#measure-detail-limitation")
  end

  test "a member sees the detail read-only, with no rotate/revoke controls", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {source, _secret} = source_fixture(owner_scope, org, project, %{type: :measure})

    member_user = user_fixture()
    member_fixture(owner_scope, org, member_user, "member")

    {:ok, view, _html} =
      conn
      |> log_in(member_user)
      |> live(detail_path(org, project, source))

    refute has_element?(view, "#measure-detail-snippet")
    refute has_element?(view, "#measure-detail-hostname-form")
    refute has_element?(view, "#rotate-measure-detail-source")
    refute has_element?(view, "#revoke-measure-detail-source-trigger")
    refute has_element?(view, "#measure-public-sharing")
    refute has_element?(view, "#measure-detail-permission")
  end

  test "the metric selection and panel pages stay in the dashboard URL", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :measure})
    project_ref = %{id: project.id, org_id: org.id}
    day = Date.utc_today()
    deltas = %{pageviews: 1, visitors: 1, visits: 1, bounces: 0, duration_seconds: 10}

    for index <- 1..9 do
      Alplus.Measure.Rollups.record_dimension!(
        project_ref,
        source.id,
        "production",
        day,
        "path",
        "/page-#{index}",
        deltas
      )
    end

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, source, %{window: "30d", metric: "bounce_rate"}))

    refute has_element?(view, "#measure-detail-metric-users")

    # Tabs and graph name one metric together.
    assert has_element?(view, "#measure-detail-metrics", "Bounce rate")
    assert has_element?(view, "#measure-comparison-panel-#{source.id}[data-metric='bounce_rate']")
    assert has_element?(view, "#measure-comparison-chart-#{source.id}-title", "Bounce rate")
    assert has_element?(view, "#measure-detail-metric-bounce_rate[aria-current='true']")
    refute has_element?(view, "#measure-detail-metric-visits[aria-current='true']")

    assert analytics_queries(view, fn ->
             view |> element("#measure-detail-metric-visits") |> render_click()
           end) == []

    assert_patch(view, detail_path(org, project, source, url_params(%{})))

    # Selecting is exclusive: the previous metric is deselected, not added.
    assert has_element?(view, "#measure-detail-metric-visits[aria-current='true']")
    refute has_element?(view, "#measure-detail-metric-bounce_rate[aria-current='true']")
    assert has_element?(view, "#measure-comparison-panel-#{source.id}[data-metric='visits']")
    assert has_element?(view, "#measure-comparison-chart-#{source.id}-title", "Visits")

    refute has_element?(view, "#measure-panel-pages", "/page-9")

    [query] =
      analytics_queries(view, fn ->
        view |> element("#measure-panel-pages a", "Next") |> render_click()
      end)

    assert String.contains?(query.query, "analytics_dimensions")
    assert Enum.at(query.params, 5) == "path"

    assert_patch(view, detail_path(org, project, source, url_params(%{pages_page: 2})))

    assert has_element?(view, "#measure-panel-pages", "/page-9")
  end

  test "a stale snapshot, retry, and range change refresh analytics", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _} = source_fixture(scope, org, project, %{type: :measure})
    deltas = %{pageviews: 1, visitors: 1, visits: 1, bounces: 0, duration_seconds: 10}
    record!(org, project, source, deltas, DateTime.utc_now())

    {:ok, view, _} =
      conn |> log_in(owner) |> live(detail_path(org, project, source, %{window: "30d"}))

    record!(org, project, source, deltas, DateTime.utc_now())

    assert analytics_queries(view, fn ->
             view |> element("#measure-detail-metric-pageviews") |> render_click()
           end) == []

    assert has_element?(view, "#measure-detail-metric-pageviews", "1")

    # Advance the snapshot age without sleeping or changing the runtime clock.
    :sys.replace_state(view.pid, fn state ->
      put_in(state.socket.assigns.data_loaded_at, System.monotonic_time(:millisecond) - 31_000)
    end)

    assert analytics_queries(view, fn ->
             view |> element("#measure-detail-metric-visits") |> render_click()
           end) != []

    assert has_element?(view, "#measure-detail-metric-visits", "2")

    record!(org, project, source, deltas, DateTime.utc_now())
    assert analytics_queries(view, fn -> render_click(view, "retry_measure") end) != []
    assert has_element?(view, "#measure-detail-metric-visits", "3")

    queries =
      analytics_queries(view, fn -> render_change(view, "pick_window", %{"window" => "7d"}) end)

    assert Enum.any?(queries, &String.contains?(&1.query, "analytics_hours"))
  end

  test "a metric patch retries an unavailable comparison", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _} = source_fixture(scope, org, project, %{type: :measure})

    record!(
      org,
      project,
      source,
      %{pageviews: 2, visitors: 2, visits: 2, bounces: 0, duration_seconds: 10},
      DateTime.utc_now()
    )

    {:ok, view, _} =
      conn |> log_in(owner) |> live(detail_path(org, project, source, %{window: "30d"}))

    # Isolate a comparison failure after the summary and panels succeeded.
    :sys.replace_state(view.pid, fn state ->
      socket =
        Phoenix.Component.assign(state.socket, :comparison, %{
          state.socket.assigns.comparison
          | unavailable?: true
        })

      %{state | socket: socket}
    end)

    assert analytics_queries(view, fn ->
             view |> element("#measure-detail-metric-pageviews") |> render_click()
           end) != []

    refute has_element?(view, "#measure-comparison-chart-#{source.id}-error")
    assert has_element?(view, "#measure-detail-metric-pageviews", "2")
  end

  test "a metric patch rechecks membership before reusing analytics", %{conn: conn} do
    Process.flag(:trap_exit, true)
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _} = source_fixture(scope, org, project, %{type: :measure})
    member = user_fixture()
    member_fixture(scope, org, member)

    {:ok, view, _} =
      conn |> log_in(member) |> live(detail_path(org, project, source, %{window: "30d"}))

    membership =
      Alplus.Orgs.list_memberships_for_org!(org.id, actor: scope)
      |> Enum.find(&(&1.user_id == member.id))

    :ok = Alplus.Orgs.remove_member(membership, actor: scope)

    assert {{%AlplusWeb.NotFoundError{}, _}, _} =
             catch_exit(view |> element("#measure-detail-metric-pageviews") |> render_click())
  end

  test "under the chart: pages and referrers, and nothing else", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :measure})

    {:ok, view, _html} = conn |> log_in(owner) |> live(detail_path(org, project, source))

    # The breakdowns sit below the chart in their own panels.
    assert has_element?(view, "#measure-panel-pages")
    assert has_element?(view, "#measure-panel-sources")

    # This site sends no custom events, so Events is absent rather than an
    # empty promise of a report nobody asked for.
    refute has_element?(view, "#measure-panel-events")

    # Audience, collection and sharing were cut: they answered questions the
    # reader did not open this page with.
    refute has_element?(view, "#measure-detail-audience")
    refute has_element?(view, "#measure-panel-countries")
    refute has_element?(view, "#measure-panel-browsers")
    refute has_element?(view, "#measure-detail-availability")

    for metric <- ~w(visits pageviews bounce_rate avg_duration) do
      assert has_element?(view, "#measure-detail-metric-#{metric}")
    end

    # The selectors are URL-backed links, so the selected one is the current
    # destination, never a pressed toggle button. Visits is the default.
    assert has_element?(view, "a#measure-detail-metric-visits[aria-current='true']")
    assert has_element?(view, "#measure-detail-metric-visits [data-selected-indicator]")
    refute has_element?(view, "#measure-detail-metrics [aria-pressed]")

    for metric <- ~w(pageviews bounce_rate avg_duration) do
      refute has_element?(view, "#measure-detail-metric-#{metric}[aria-current]")
    end
  end

  test "a configured event keeps the Events panel through a quiet range", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :measure})

    {:ok, view, _html} = conn |> log_in(owner) |> live(detail_path(org, project, source))

    refute has_element?(view, "#measure-panel-events")

    {:ok, _definition} =
      Alplus.Measure.create_event_definition(
        %{org_id: org.id, project_id: project.id, name: "signup"},
        actor: %{scope | project_id: project.id}
      )

    {:ok, view, _html} = conn |> log_in(owner) |> live(detail_path(org, project, source))

    assert has_element?(view, "#measure-panel-events")

    assert has_element?(
             view,
             "#measure-panel-events-empty",
             "Events are configured for this site and none were recorded in this range."
           )
  end

  test "only the three offered ranges are honoured", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :measure})

    {:ok, view, html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, source, %{window: "90d"}))

    assert html =~ "last 24 hours"
    refute html =~ "last 90 days"
    assert has_element?(view, "[phx-value-window='24h'][aria-pressed='true']")
    refute has_element?(view, "[phx-value-window='90d']")
  end

  test "the hero reads tabs, then chart, and names each string once", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :measure})

    {:ok, view, _html} = conn |> log_in(owner) |> live(detail_path(org, project, source))

    html = render(view)

    assert has_element?(
             view,
             "#measure-detail-metrics[role='group'][aria-label='Choose the metric to plot']"
           )

    for metric <- ~w(visits pageviews bounce_rate avg_duration) do
      assert has_element?(view, "#measure-detail-metric-#{metric}.h-28")
    end

    [controls, plot] =
      Enum.map(
        ["measure-detail-metrics", "measure-comparison-panel-"],
        fn id -> :binary.match(html, id) |> elem(0) end
      )

    assert controls < plot

    assert has_element?(view, "#measure-detail-metrics", "Visits")
    refute html =~ ~s(class="text-label font-semibold text-text-primary")
    refute html =~ "Hourly totals in UTC."
    assert html =~ "lg:min-h-80"

    assert has_element?(
             view,
             "#measure-comparison-chart-#{source.id}-title.sr-only",
             "Visits, last 24 hours"
           )
  end

  test "seeded page and referrer rollups render as ranked panels", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :measure})

    completed_day = Date.add(Date.utc_today(), -1)
    deltas = %{pageviews: 1, visitors: 1, visits: 1, bounces: 0, duration_seconds: 0}
    project_ref = %{id: project.id, org_id: org.id}

    Alplus.Measure.Rollups.record_dimension!(
      project_ref,
      source.id,
      "production",
      completed_day,
      "path",
      "/pricing",
      deltas
    )

    Alplus.Measure.Rollups.record_dimension!(
      project_ref,
      source.id,
      "production",
      completed_day,
      "referrer",
      "google.com",
      deltas
    )

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, source, %{window: "30d"}))

    assert has_element?(view, "#measure-panel-pages", "/pricing")
    assert has_element?(view, "#measure-panel-sources", "google.com")

    assert has_element?(
             view,
             "#measure-panel-sources use[href='/images/referrer-favicons.svg#google']"
           )

    refute has_element?(view, "#measure-panel-pages-table")
  end

  test "the hero states the change once and plots only this period", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :measure})
    today = Date.utc_today()

    retain_90_days!(org)
    source = collecting_since!(source, 80)

    deltas = %{
      pageviews: 12,
      visitors: 12,
      visits: 12,
      bounces: 0,
      duration_seconds: 60,
      landing_page_visits: 12
    }

    record!(
      org,
      project,
      source,
      deltas,
      DateTime.new!(Date.add(today, -1), ~T[12:00:00], "Etc/UTC")
    )

    record!(
      org,
      project,
      source,
      %{deltas | pageviews: 6, visitors: 6, visits: 6},
      DateTime.new!(Date.add(today, -40), ~T[12:00:00], "Etc/UTC")
    )

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, source, %{window: "30d"}))

    assert has_element?(view, "#measure-detail-metrics", "Visits")
    assert has_element?(view, "#measure-detail-metric-visits", "12")

    assert has_element?(
             view,
             "#measure-detail-change",
             "Up 100% from the previous period"
           )

    # Inside proven coverage every day of the window is a reading, so there is
    # no shortfall to state: 29 measured zeros are not 29 gaps.
    refute has_element?(view, "#measure-detail-coverage")

    assert has_element?(
             view,
             "#measure-comparison-chart-#{source.id}-title.sr-only",
             "Visits, last 30 days"
           )

    assert length(Regex.scan(~r/data-selected-indicator/, render(view))) == 1

    chart = "#measure-comparison-chart-#{source.id}"

    assert has_element?(view, "#{chart}[data-display-kind='line']")
    refute has_element?(view, "#{chart} [aria-label='Legend']")
    assert has_element?(view, "#{chart}-range", "now (UTC)")
    refute render(view) =~ "dashed gray"
    refute render(view) =~ "stroke-chart-previous"

    # The table alternative carries the same current-period readings as the chart.
    table = "#{chart}-table"
    assert has_element?(view, table, "Visits")
    refute has_element?(view, table, "Visits 30 days earlier")
    assert has_element?(view, "#{table} tbody tr:nth-child(29)", "12")
    refute view |> element(table) |> render() =~ "Not recorded"

    assert has_element?(view, "#measure-panel-pages-bars [data-share='100.0']")
  end

  test "a preceding period that measured nothing leaves no change line", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :measure})

    retain_90_days!(org)
    source = collecting_since!(source, 80)

    record!(
      org,
      project,
      source,
      %{pageviews: 9, visitors: 9, visits: 9, bounces: 0, duration_seconds: 90},
      DateTime.new!(Date.add(Date.utc_today(), -1), ~T[12:00:00], "Etc/UTC")
    )

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, source, %{window: "30d"}))

    refute has_element?(view, "#measure-detail-change")
    refute has_element?(view, "#measure-detail-coverage")
    refute render(view) =~ "Nothing was recorded in the preceding"

    # Thirty daily buckets, thirty focus targets.
    targets =
      ~r/<button\b[^>]*data-display-point="true"[^>]*>/s
      |> Regex.scan(render(view))
      |> List.flatten()

    assert length(targets) == 30

    table = view |> element("#measure-comparison-chart-#{source.id}-table") |> render()
    assert length(Regex.scan(~r/<tr\b/, table)) == 31
  end

  test "a preceding period the data cannot cover is withheld, not called zero", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :measure})

    retain_90_days!(org)
    source = collecting_since!(source, 40)

    record!(
      org,
      project,
      source,
      %{pageviews: 4, visitors: 4, visits: 4, bounces: 0, duration_seconds: 40},
      DateTime.new!(Date.add(Date.utc_today(), -1), ~T[12:00:00], "Etc/UTC")
    )

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, source, %{window: "30d"}))

    refute has_element?(view, "#measure-detail-change")
    refute render(view) =~ "not completely covered"
    refute render(view) =~ "Nothing was recorded in the preceding"
    assert has_element?(view, "#measure-detail-metric-visits", "4")
  end

  test "a failed comparison read is an error on the chart, never out of retention", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :measure})

    Alplus.Repo.query!("ALTER TABLE analytics_days RENAME TO analytics_days_unavailable")

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, source, %{window: "30d"}))

    assert has_element?(
             view,
             "#measure-comparison-chart-#{source.id}-error",
             "Traffic could not be loaded."
           )

    refute has_element?(view, "#measure-detail-change")
    refute render(view) =~ "not completely covered"
  end

  test "the Measure MVP never renders Goal configuration or conversions", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :measure})

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, source))

    refute has_element?(view, "#measure-goals")
    refute has_element?(view, "#measure-goal-form")
    refute has_element?(view, "#measure-goal-submit")
  end

  test "a Source id outside this project 404s, never 403", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)

    {other_org, other_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_scope, other_org)

    {other_source, _secret} =
      source_fixture(other_scope, other_org, other_project, %{type: :measure})

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, other_source))
    end
  end

  test "an unknown Source id 404s", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn
      |> log_in(owner)
      |> live(
        ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/measure/does-not-exist"
      )
    end
  end

  test "detail preserves analysis filters and evidence without mutation controls or secrets", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, secret} = source_fixture(scope, org, project, %{type: :measure})

    {:ok, view, html} =
      conn
      |> log_in(owner)
      |> live(detail_path(org, project, source, %{window: "30d", metrics: "visits,pageviews"}))

    refute_mutation_controls(view)

    assert has_element?(view, "#measure-comparison-panel-#{source.id}")
    assert has_element?(view, "#measure-detail-metric-visits")
    refute has_element?(view, "#measure-detail-hostname-form")
    refute has_element?(view, "#measure-detail-install")
    refute has_element?(view, "#rotate-measure-detail-source")
    refute has_element?(view, "#revoke-measure-detail-source")
    refute has_element?(view, "#measure-share-form")
    refute has_element?(view, "[phx-click='generate_measure_share']")
    refute has_element?(view, "[phx-click='rotate_measure_share']")
    refute html =~ secret
    refute html =~ source.measure_token
  end
end
