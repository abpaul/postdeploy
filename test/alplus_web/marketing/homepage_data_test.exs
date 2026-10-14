defmodule AlplusWeb.Marketing.HomepageDataTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.{Changelog, Observe, PublicPages, Scope, Status}
  alias Alplus.Measure.{AnalyticsEngine, DashboardShare, PublicCache, Rollups}
  alias Alplus.Monitoring.{DailyRollup, MonitorCheck}
  alias Alplus.Observe.Issue
  alias AlplusWeb.Marketing.HomepageData

  @former_static_metrics ["186ms", "99.98%", "2,410", "6,984", "v2.4.1"]
  @preview_values ["Example project", "Example API", "Example site", "Example monitor coverage"]

  setup do
    PublicCache.clear()
    on_exit(&PublicCache.clear/0)
    :ok
  end

  test "real vendor data wins when the development preview flag is enabled" do
    set_preview_flag(true)
    vendor = vendor_fixture()
    _public = complete_public_evidence(vendor)
    outsider = non_vendor_evidence(vendor)

    data = HomepageData.load()

    assert data.state == :ready
    assert data.identity == %{name: "Public Vendor", slug: "public-vendor"}
    assert data.monitor.state == :ready
    assert data.measure.pageviews == 37
    assert data.status.state == :ready
    assert data.changelog.state == :ready
    refute data.state == :preview

    for preview_value <- @preview_values do
      refute inspect(data) =~ preview_value
    end

    refute inspect(data) =~ vendor.project.id
    refute inspect(data) =~ outsider.project.id
  end

  test "keeps the unavailable projection when the vendor lookup fails and preview is enabled" do
    set_preview_flag(true)

    unavailable = HomepageData.project_from_resolution({:error, :unavailable})

    assert unavailable.state == :unavailable
    assert unavailable.monitor.state == :unavailable
    assert unavailable.measure.state == :unavailable
    assert unavailable.observe.state == :unavailable
    assert unavailable.status.state == :unavailable
    assert unavailable.changelog.state == :unavailable

    for preview_value <- @preview_values do
      refute inspect(unavailable) =~ preview_value
    end

    assert HomepageData.project_from_resolution({:error, :not_found}).state == :preview
  end

  test "keeps the latest check latency and daily trend buckets on the status and share path" do
    vendor = vendor_fixture()
    public = complete_public_evidence(vendor)

    Ash.Seed.seed!(MonitorCheck, %{
      org_id: vendor.org.id,
      environment: "production",
      project_id: vendor.project.id,
      monitor_id: public.monitor.id,
      status: "up",
      checked_at: DateTime.utc_now(),
      latency_ms: 233
    })

    data = HomepageData.load()

    assert data.status.state == :ready
    assert data.monitor.response_time_ms == 233
    assert data.metrics.monitor.response_time_ms == 233
    assert data.measure.state == :ready
    assert data.measure.trend != []

    assert Enum.all?(
             data.measure.trend,
             &match?(%{bucket: %Date{}, pageviews: n} when is_integer(n), &1)
           )

    assert Enum.sum(Enum.map(data.measure.trend, & &1.pageviews)) == data.measure.pageviews
  end

  test "gives each monitor a full window strip, not a single bar", %{conn: conn} do
    vendor = vendor_fixture()
    _public = complete_public_evidence(vendor)

    data = HomepageData.load()
    [row | _] = data.monitor.rows

    assert length(row.windows) == 36, "one tick per hour over the last 36 hours"
    assert Enum.all?(row.windows, &(&1.state in [:up, :degraded, :down, :none]))
    assert Enum.any?(row.windows, &(&1.state == :none)), "hours without checks stay empty"
    refute inspect(row.windows) =~ vendor.project.id

    html = html_response(get(conn, ~p"/"), 200)
    [card] = Regex.run(~r/id="monitor".*?id="measure"/s, html)

    ticks = Regex.scan(~r/rounded-\[3px\]/, card)
    assert length(ticks) == 36, "the detail card draws the whole strip"
    assert card =~ "-36h"
    assert card =~ "milliseconds for each hour in the last 36 hours"
  end

  test "colours the hero chart by what the metric means, not by the chart shape", %{conn: conn} do
    vendor = vendor_fixture()
    _public = complete_public_evidence(vendor)

    chart = fn html ->
      [markup] = Regex.run(~r/id="console-preview-panel-monitor".*?id="product"/s, html)
      markup
    end

    uptime = chart.(html_response(get(conn, ~p"/?metric=uptime"), 200))
    response = chart.(html_response(get(build_conn(), ~p"/?metric=response"), 200))
    errors = chart.(html_response(get(build_conn(), ~p"/?metric=errors"), 200))

    # Uptime is operational state: the green, amber and red palette, never brand.
    assert uptime =~ "bg-status-live" or uptime =~ "bg-status-neutral"
    refute uptime =~ "bg-interactive-primary"

    # Response time is a measurement: brand chartreuse, never operational green.
    assert response =~ "bg-interactive-primary" or response =~ "bg-surface-sunken"
    refute response =~ "bg-status-live"

    # Errors stay quiet until a bucket holds one.
    refute errors =~ "bg-status-live"
    refute errors =~ "bg-interactive-primary"
  end

  test "colours each published day by its own state, so downtime cannot read as healthy", %{
    conn: conn
  } do
    vendor = vendor_fixture()
    _public = complete_public_evidence(vendor)

    data = HomepageData.load()
    [component | _] = data.status.components
    yesterday = Date.add(Date.utc_today(), -1)

    states = Enum.map(component.history, &Map.get(&1, :state))
    assert Enum.all?(states, &(&1 in [:up, :degraded, :down, :maintenance, :unknown]))

    assert %{state: :down} =
             Enum.find(component.history, &(Map.get(&1, :day) == yesterday))

    assert Enum.any?(component.history, &(Map.get(&1, :state) == :unknown)),
           "days without evidence must not claim a state"

    html = html_response(get(conn, ~p"/"), 200)
    [card] = Regex.run(~r/id="status".*?id="console-preview-panel-changelog"/s, html)

    assert card =~ "bg-status-error"
    assert card =~ "Daily uptime for Public API, in percent"
    assert card =~ "<caption>"
  end

  test "loads a ready projection from the designated vendor's persisted public records" do
    vendor = vendor_fixture()
    public = complete_public_evidence(vendor)
    outsider = non_vendor_evidence(vendor)

    data = HomepageData.load()

    assert data.state == :ready
    assert data.identity == %{name: "Public Vendor", slug: "public-vendor"}

    assert %{
             state: :ready,
             rows: [
               %{name: "Public API", state: :up, uptime: 98.75, history: api_history},
               %{name: "Public Worker", state: :up, uptime: 96.25, history: worker_history}
             ],
             headline: %{total: 2, operational: 2, uptime: 97.5},
             uptime_label: "Weighted production uptime, last 90 days"
           } = data.monitor

    assert is_list(api_history)
    assert is_list(worker_history)
    assert length(data.metrics.monitor_history) == 7
    assert Enum.all?(data.metrics.monitor_history, &(&1 == 97.5))

    assert %{
             state: :ready,
             pageviews: 37,
             visitors: 11,
             top_pages: [
               %{label: "/public-pricing", value: "/public-pricing", count: 37, pageviews: 37} | _
             ]
           } = data.measure

    assert %{state: :ready, open_issues: 1} = data.observe

    assert %{
             state: :ready,
             components: [
               %{name: "Public API", uptime: 98.75},
               %{name: "Public Worker", uptime: 96.25}
             ]
           } = data.status

    assert %{state: :ready, entries: [%{title: "Public vendor release"}]} = data.changelog

    rendered = inspect(data)

    for private_value <- [
          vendor.org.id,
          vendor.project.id,
          public.monitor.id,
          public.measure_source.id,
          public.observe_source.id,
          public.issue.id,
          public.share.id,
          public.share.token_prefix,
          outsider.project.id,
          outsider.monitor.id,
          outsider.measure_source.id,
          outsider.observe_source.id,
          "PRIVATE changelog source",
          "PRIVATE observe context",
          "Private outsider monitor",
          "Private outsider release",
          "Private outsider issue",
          "private-analytics.internal"
        ] do
      refute rendered =~ private_value
    end

    refute data.metrics.monitor.value in @former_static_metrics
    refute data.metrics.measure.value in @former_static_metrics
  end

  test "renders only public vendor values and excludes a data-rich non-vendor project", %{
    conn: conn
  } do
    vendor = vendor_fixture()
    _public = complete_public_evidence(vendor)
    outsider = non_vendor_evidence(vendor)

    html = html_response(get(conn, ~p"/"), 200)

    # The rendered copy belongs to the template slice. This test asserts the
    # published values reach the page and no private value does.
    for public_value <- ["Public Vendor", "public-vendor", "Public API", "/public-pricing"] do
      assert html =~ public_value
    end

    for private_value <- [
          vendor.org.id,
          vendor.project.id,
          outsider.project.id,
          outsider.monitor.id,
          outsider.measure_source.id,
          outsider.observe_source.id,
          "PRIVATE changelog source",
          "PRIVATE observe context",
          "Private outsider monitor",
          "Private outsider release",
          "9,001"
        ] do
      refute html =~ private_value
    end

    for metric <- @former_static_metrics do
      refute html =~ metric
    end
  end

  test "reports partial Measure coverage when live and durable public rollups differ" do
    vendor = vendor_fixture()
    {source, _token} = source_fixture(vendor.scope, vendor.org, vendor.project, %{type: :measure})

    _share =
      Ash.create!(
        DashboardShare,
        %{org_id: vendor.org.id, project_id: vendor.project.id, source_id: source.id},
        actor: vendor.scope
      )

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    :ok =
      AnalyticsEngine.record(%{
        org_id: vendor.org.id,
        project_id: vendor.project.id,
        source_id: source.id,
        hour: now,
        pageviews: 3,
        visitors: 2,
        visits: 2,
        bounces: 0,
        duration_seconds: 0
      })

    :ok = AnalyticsEngine.Batcher.flush()

    Rollups.record!(
      %{id: vendor.project.id, org_id: vendor.org.id},
      source.id,
      source.environment,
      %{type: "pageview", path: "/durable", hostname: "example.test"},
      %{pageviews: 5, visitors: 4, visits: 4, bounces: 0, duration_seconds: 0},
      DateTime.add(now, -3_600, :second)
    )

    PublicCache.clear()
    data = HomepageData.load()

    # The Measure section reads analytics_days for every range, so the durable
    # daily rollup is the published figure.
    assert data.measure.pageviews == 5
    assert data.measure.visitors == 4
  end

  test "keeps partial persisted evidence explicitly unavailable instead of restoring static metrics",
       %{
         conn: conn
       } do
    vendor = vendor_fixture()
    publish_component_without_monitor(vendor)

    data = HomepageData.load()
    html = html_response(get(conn, ~p"/"), 200)

    # The public identity and status component are published, while Monitor,
    # Measure, Observe, and Changelog have no public records yet.
    assert data.state == :ready

    assert %{
             state: :ready,
             rows: [
               %{
                 name: "Published service monitor",
                 type: "monitor",
                 state: :unknown,
                 uptime: nil,
                 history: history
               }
             ],
             headline: %{total: 1, operational: 0}
           } = data.monitor

    assert is_list(history)

    assert data.measure == %{
             state: :empty,
             pageviews: nil,
             visitors: nil,
             trend: [],
             top_pages: [],
             ranges: ["7d", "14d", "30d"],
             range: "7d"
           }

    assert %{state: :empty, open_issues: 0} = data.observe
    assert data.changelog == %{state: :empty, entries: []}
    assert data.metrics.monitor.value == "Unavailable"
    assert data.metrics.measure == %{value: nil, visitors: nil}
    assert html =~ "Published service monitor"

    for metric <- @former_static_metrics do
      refute html =~ metric
    end
  end

  test "handles a vendor with no published status page and no Measure share" do
    vendor = vendor_fixture()

    data = HomepageData.load()

    assert data.status == %{state: :empty, status: :unknown, components: []}

    assert data.monitor == %{
             state: :empty,
             rows: [],
             headline: %{total: 0, operational: 0},
             history: [],
             selected: nil
           }

    assert data.measure == %{
             state: :empty,
             pageviews: nil,
             visitors: nil,
             trend: [],
             top_pages: [],
             ranges: ["7d", "14d", "30d"],
             range: "7d"
           }

    assert %{state: :empty, open_issues: 0} = data.observe
    assert data.identity == %{name: "Public Vendor", slug: "public-vendor"}
    refute inspect(data) =~ vendor.project.id
  end

  test "uses vendor monitor and Measure aggregates without a status page or share", %{conn: conn} do
    vendor = vendor_fixture()

    %{monitor: monitor, measure_source: measure_source} =
      vendor_without_workspace_evidence(vendor)

    outsider = sibling_without_workspace_evidence(vendor)

    data = HomepageData.load()
    html = html_response(get(conn, ~p"/"), 200)

    assert data.status.state == :empty
    assert data.monitor.state == :ready

    assert [%{name: "Vendor HTTP", state: :up, uptime: 99.5, response_time_ms: nil}] =
             data.monitor.rows

    assert data.metrics.monitor.value == "99.5%"
    assert data.metrics.monitor.response_time_ms == 142
    assert data.measure.state == :ready
    assert data.measure.pageviews == 12
    assert data.measure.visitors == 8

    assert [%{label: "/vendor", value: "/vendor", count: 12, pageviews: 12}] =
             data.measure.top_pages

    refute inspect(data) =~ monitor.id
    refute inspect(data) =~ measure_source.id
    refute inspect(data) =~ outsider.project.id
    refute inspect(data) =~ outsider.monitor.id
    refute inspect(data) =~ outsider.measure_source.id
    refute inspect(data) =~ "Outsider fallback project"

    refute Enum.any?(data.monitor.rows, &(&1.name == "Outsider fallback HTTP"))
    refute Enum.any?(data.monitor.rows, &(&1.uptime == 12.34))
    refute data.metrics.monitor.value == "12.34%"
    refute data.metrics.monitor.response_time_ms == 987
    refute data.measure.pageviews == 9_001
    refute Enum.any?(data.measure.top_pages, &(&1.value == "/outsider-fallback"))
    refute Enum.any?(data.measure.top_pages, &(&1.count == 9_001))

    for vendor_value <- ["Vendor HTTP", "/vendor"] do
      assert html =~ vendor_value
    end

    for outsider_value <- [
          "Outsider fallback project",
          "Outsider fallback HTTP",
          "12.34%",
          "987ms",
          "9,001",
          "/outsider-fallback"
        ] do
      refute html =~ outsider_value
    end
  end

  test "uses the empty public projection when preview is disabled and no vendor exists", %{
    conn: conn
  } do
    set_preview_flag(false)
    data = HomepageData.load()
    html = html_response(get(conn, ~p"/"), 200)

    assert data.state == :empty
    assert data.identity == %{name: nil, slug: nil}
    assert data.monitor.state == :empty
    assert data.measure.state == :empty
    assert data.observe.state == :empty
    assert data.status.state == :empty
    assert data.changelog.state == :empty
    assert html =~ "PostDeploy project"

    for metric <- @former_static_metrics do
      refute html =~ metric
    end
  end

  test "uses the example preview projection when enabled and no vendor exists", %{conn: conn} do
    set_preview_flag(true)
    data = HomepageData.load()
    html = html_response(get(conn, ~p"/"), 200)

    assert data.state == :preview
    assert data.identity == %{name: "Example project", slug: "example"}
    assert data.monitor.state == :ready
    assert data.measure.state == :ready
    assert data.observe.state == :ready
    assert data.status.state == :ready
    assert data.changelog.state == :ready

    assert Enum.map(data.monitor.rows, & &1.name) == ["Example API", "Example site"]
    assert Enum.all?(data.monitor.rows, &(&1.type == "monitor" and &1.state == :up))
    assert data.monitor.uptime_label == "Uptime, last 90 days"
    assert Enum.map(data.measure.top_pages, & &1.path) == ["/", "/pricing", "/changelog"]
    assert data.status.status == :operational
    assert Enum.map(data.status.components, & &1.name) == ["Example API", "Example site"]
    assert Enum.all?(data.status.components, &is_float(&1.uptime))

    assert Enum.map(data.changelog.entries, & &1.title) == [
             "Example monitor coverage",
             "Example status update"
           ]

    assert Enum.map(data.changelog.entries, & &1.published_at) == ["2026-08-20", "2026-08-18"]

    # The preview map must have the same keys as the real projection so the
    # template needs no special casing.
    assert Enum.sort(Map.keys(data.monitor)) == Enum.sort(Map.keys(reference_monitor_keys()))
    assert Enum.sort(Map.keys(data.metrics)) == [:measure, :monitor, :monitor_history, :observe]
    assert Enum.sort(Map.keys(data.metrics.monitor)) == [:response_time_ms, :value, :visitors]
    assert data.metrics.observe.open_issues == 1
    assert data.metrics.monitor_history != []

    refute inspect(data) =~ "Illustrative"
    assert html =~ ~s(data-state="preview")
    assert html =~ "Example API"

    for private_text <- ["Acme Dev Co", "Acme customer", "private project", "PRIVATE"] do
      refute html =~ private_text
    end
  end

  defp reference_monitor_keys do
    %{
      state: nil,
      rows: [],
      headline: %{},
      response_time_ms: nil,
      history: [],
      uptime_label: nil,
      selected: nil
    }
  end

  test "reports a ready monitor section from real rollups and checks without a status page" do
    vendor = vendor_fixture()
    %{monitor: monitor} = vendor_without_workspace_evidence(vendor)
    _outsider = sibling_without_workspace_evidence(vendor)

    data = HomepageData.load()

    assert data.status.state == :empty
    assert data.monitor.state == :ready
    refute data.monitor.state == :unavailable

    assert [%{name: "Vendor HTTP", type: "monitor", state: :up, uptime: 99.5}] = data.monitor.rows
    assert data.monitor.headline == %{total: 1, operational: 1, uptime: 99.5}
    assert data.monitor.response_time_ms == 142
    assert data.monitor.uptime_label == "Weighted production uptime, last 90 days"
    assert data.metrics.monitor.response_time_ms == 142
    refute inspect(data) =~ monitor.id
  end

  test "reports a ready measure section from an active production source without a share" do
    vendor = vendor_fixture()
    %{measure_source: source} = vendor_without_workspace_evidence(vendor)
    outsider = sibling_without_workspace_evidence(vendor)

    data = HomepageData.load()

    assert data.measure.state == :ready
    refute data.measure.state == :unavailable
    assert data.measure.pageviews == 12
    assert data.measure.visitors == 8
    assert [%{bucket: %Date{}, pageviews: 12, visitors: 8}] = data.measure.trend

    assert [%{label: "/vendor", path: "/vendor", value: "/vendor", count: 12, pageviews: 12}] =
             data.measure.top_pages

    refute inspect(data) =~ source.id
    refute inspect(data) =~ outsider.measure_source.id
    refute Enum.any?(data.measure.top_pages, &(&1.path == "/outsider-fallback"))
  end

  test "publishes changelog evidence when no status page and no share exist" do
    vendor = vendor_fixture()
    _evidence = vendor_without_workspace_evidence(vendor)
    publish_vendor_entry(vendor, "Vendor release without a workspace")

    data = HomepageData.load()

    assert data.status.state == :empty
    assert data.changelog.state == :ready
    assert [%{title: "Vendor release without a workspace"}] = data.changelog.entries
    assert data.state == :ready
    refute data.state == :unavailable
    refute data.state == :partial
  end

  test "reports an empty uptime, not an unavailable one, for monitors without rollups" do
    vendor = vendor_fixture()

    {:ok, monitor} =
      Alplus.Monitoring.create_monitor(
        %{
          org_id: vendor.org.id,
          project_id: vendor.project.id,
          environment: "production",
          type: "http",
          name: "Vendor monitor without rollups"
        },
        actor: vendor.scope
      )

    Ash.Seed.update!(monitor, %{last_known_status: "up"})
    PublicCache.clear()

    data = HomepageData.load()

    assert data.monitor.state == :ready
    assert [%{name: "Vendor monitor without rollups", uptime: nil}] = data.monitor.rows
    assert data.monitor.headline.uptime == nil
    assert data.monitor.history == []
    assert data.metrics.monitor_history == []
    assert data.measure.state == :empty
    assert data.observe.state == :empty
    refute data.monitor.state == :unavailable
    refute data.measure.state == :unavailable
    refute data.observe.state == :unavailable
  end

  test "exposes raw daily counts in the measure trend so the chart can scale from its peak" do
    vendor = vendor_fixture()
    %{measure_source: source} = vendor_without_workspace_evidence(vendor)

    record_pageviews(vendor, source, "/peak", 30, -2)
    PublicCache.clear()

    data = HomepageData.load()

    counts = Enum.map(data.measure.trend, & &1.pageviews)

    assert length(data.measure.trend) == 2
    assert Enum.max(counts) == 30
    assert Enum.sort(counts) == [12, 30]
    assert data.measure.pageviews == 42
  end

  test "loads all thirty days of traffic across the five public Measure sources" do
    vendor = vendor_fixture()

    sources =
      for index <- 1..5 do
        {source, _token} =
          source_fixture(vendor.scope, vendor.org, vendor.project, %{
            type: :measure,
            name: "Public Measure #{index}"
          })

        {source, index}
      end

    for {source, source_index} <- sources, day_offset <- 0..29 do
      record_pageviews(vendor, source, "/site-#{source_index}", source_index, -day_offset)
    end

    PublicCache.clear()

    data = HomepageData.load(%{"traffic" => "30d"})

    assert data.measure.range == "30d"
    assert length(data.measure.trend) == 30
    assert data.measure.pageviews == 450
    assert data.measure.visitors == 450
    assert Enum.all?(data.measure.trend, &(&1.pageviews == 15 and &1.visitors == 15))
  end

  test "bounds the measure trend to seven days and the monitor history to the last ninety days" do
    vendor = vendor_fixture()
    %{monitor: monitor, measure_source: source} = vendor_without_workspace_evidence(vendor)

    for offset <- [-20, -12, -8] do
      record_pageviews(vendor, source, "/old", 5, offset)
    end

    for offset <- [-120, -95] do
      seed_rollup(vendor, monitor, Date.add(Date.utc_today(), offset), 0.5)
    end

    PublicCache.clear()

    data = HomepageData.load()

    today = Date.utc_today()
    oldest_trend_day = Date.add(today, -6)
    oldest_history_day = Date.add(today, -89)

    assert length(data.measure.trend) <= 7
    assert Enum.all?(data.measure.trend, &(Date.compare(&1.bucket, oldest_trend_day) != :lt))
    assert data.measure.pageviews == 12

    assert length(data.monitor.history) <= 90
    assert Enum.all?(data.monitor.history, &(Date.compare(&1.day, oldest_history_day) != :lt))
    assert length(data.measure.top_pages) <= 5
  end

  test "caps the open issue count and flags it as a lower bound" do
    vendor = vendor_fixture()

    {observe_source, _secret} =
      source_fixture(vendor.scope, vendor.org, vendor.project, %{type: :observe})

    now = DateTime.utc_now()

    for index <- 1..100 do
      Ash.Seed.seed!(Issue, %{
        org_id: vendor.org.id,
        project_id: vendor.project.id,
        source_id: observe_source.id,
        environment: observe_source.environment,
        fingerprint: "sha256:" <> String.pad_leading("#{index}", 64, "c"),
        level: "error",
        status: :open,
        title: "Capped issue #{index}",
        first_seen_at: now,
        last_seen_at: now,
        event_count: 1
      })
    end

    PublicCache.clear()

    data = HomepageData.load()

    assert data.observe.state == :ready
    assert data.observe.open_issues == 100
    assert data.observe.open_issues_lower_bound == true
    refute inspect(data) =~ "Capped issue"
  end

  describe "hero selection" do
    setup do
      vendor = vendor_fixture()
      evidence = hero_evidence(vendor)
      PublicCache.clear()
      %{vendor: vendor, evidence: evidence}
    end

    test "each range buckets the hero chart from the matching source" do
      hourly = HomepageData.load(%{"range" => "24h"})

      assert hourly.selection.range == "24h"
      assert hourly.overview.ranges == ["24h", "7d", "30d"]
      assert length(hourly.overview.chart.points) == 24
      assert hourly.overview.chart.axis_start == "-24h"
      assert hourly.overview.chart.axis_end == "now"
      assert Enum.all?(hourly.overview.chart.points, &(&1.label =~ ~r/^\d{2}:00$/))

      # The 24 hour uptime chart is bucketed from checks, so the hour that
      # holds the failed check reports a degraded bucket.
      assert Enum.any?(hourly.overview.chart.points, &(&1.state == :degraded))
      assert Enum.any?(hourly.overview.chart.points, &(&1.state == :up))
      assert Enum.any?(hourly.overview.chart.points, &(&1.state == :none))

      weekly = HomepageData.load(%{"range" => "7d"})

      assert length(weekly.overview.chart.points) == 7
      assert weekly.overview.chart.axis_start == "-7d"
      assert Enum.all?(weekly.overview.chart.points, &(&1.label =~ ~r/^\d{4}-\d{2}-\d{2}$/))

      # The 7 day and 30 day uptime charts are bucketed from daily rollups,
      # so the half-day rollup appears as one degraded day.
      assert Enum.any?(weekly.overview.chart.points, &(&1.value == 50.0))

      monthly = HomepageData.load(%{"range" => "30d"})

      assert length(monthly.overview.chart.points) == 30
      assert monthly.overview.chart.axis_start == "-30d"
      assert Enum.any?(monthly.overview.chart.points, &(&1.value == 50.0))
    end

    test "each metric selects its own chart shape, unit and column label" do
      expected = [
        {"uptime", :uptime, :ticks, "percent", "Uptime, percent"},
        {"response", :response, :bars, "ms", "Average response, milliseconds"},
        {"traffic", :traffic, :wave, "pageviews", "Traffic, pageviews"},
        {"errors", :errors, :bars, "issues", "Issues active, count"}
      ]

      for {param, id, kind, unit, column_label} <- expected do
        data = HomepageData.load(%{"metric" => param})

        assert data.selection.metric == id
        assert data.overview.chart.kind == kind
        assert data.overview.chart.unit == unit
        assert data.overview.chart.column_label == column_label
        assert data.overview.chart.table_caption =~ column_label
        assert Enum.map(data.overview.tiles, & &1.id) == [:uptime, :response, :traffic, :errors]
        assert Enum.count(data.overview.tiles, & &1.selected?) == 1
        assert Enum.find(data.overview.tiles, & &1.selected?).id == id
      end
    end

    test "unknown, missing and malformed parameters fall back to the defaults" do
      default = HomepageData.load()

      assert default.selection == %{
               range: "24h",
               metric: :uptime,
               monitor: 0,
               traffic_range: "7d"
             }

      hostile = %{
        "range" => "999d",
        "metric" => "../etc",
        "monitor" => "-4",
        "traffic" => "7 OR 1=1"
      }

      assert HomepageData.load(hostile).selection == default.selection
      assert HomepageData.load(%{"monitor" => "abc"}).selection.monitor == 0
      assert HomepageData.load(%{"monitor" => "3.5"}).selection.monitor == 0
      assert HomepageData.load(%{"range" => ["7d"]}).selection.range == "24h"
      assert HomepageData.load(%{"metric" => nil}).selection.metric == :uptime
      assert HomepageData.load(%{"traffic" => "24h"}).selection.traffic_range == "7d"
    end

    test "monitor selection picks the row at the normalised index and exposes no id", %{
      evidence: evidence
    } do
      first = HomepageData.load(%{"monitor" => "0"})
      second = HomepageData.load(%{"monitor" => "1"})

      names = Enum.map(first.monitor.rows, & &1.name)
      assert names == ["Vendor API", "Vendor Worker"]
      assert Enum.map(second.monitor.rows, & &1.name) == names

      assert first.monitor.selected.name == "Vendor API"
      assert first.selection.monitor == 0
      assert Enum.count(first.monitor.rows, & &1.selected?) == 1

      assert second.monitor.selected.name == "Vendor Worker"
      assert second.selection.monitor == 1

      # An index past the last row clamps onto the last row, so exactly one
      # row stays selected.
      clamped = HomepageData.load(%{"monitor" => "17"})
      assert clamped.selection.monitor == 1
      assert clamped.monitor.selected.name == "Vendor Worker"

      assert first.monitor.selected.type_label == "HTTP, 60s"
      assert second.monitor.selected.type_label == "HTTP, 30s"
      assert first.monitor.selected.checks_recent == 4
      assert first.monitor.selected.caption == "1 failed check, recovered"
      assert second.monitor.selected.caption == "No checks in the last 24 hours"

      refute inspect(first.monitor) =~ evidence.monitor.id
      refute inspect(first.monitor) =~ evidence.worker.id
    end

    test "the measure range changes pageviews, visitors and the trend length" do
      week = HomepageData.load(%{"traffic" => "7d"})
      fortnight = HomepageData.load(%{"traffic" => "14d"})
      month = HomepageData.load(%{"traffic" => "30d"})

      assert week.measure.ranges == ["7d", "14d", "30d"]
      assert week.measure.range == "7d"
      assert fortnight.measure.range == "14d"

      assert week.measure.pageviews == 40
      assert fortnight.measure.pageviews == 240
      assert month.measure.pageviews == 1_240

      assert week.measure.visitors < fortnight.measure.visitors
      assert fortnight.measure.visitors < month.measure.visitors

      assert length(week.measure.trend) == 1
      assert length(fortnight.measure.trend) == 2
      assert length(month.measure.trend) == 3
    end
  end

  test "an empty window renders zero-valued buckets and an honest caption" do
    vendor = vendor_fixture()
    _evidence = vendor_without_workspace_evidence(vendor)
    PublicCache.clear()

    traffic = HomepageData.load(%{"range" => "24h", "metric" => "traffic"})

    assert traffic.overview.chart.state == :empty
    refute traffic.overview.chart.state == :unavailable
    assert length(traffic.overview.chart.points) == 24
    assert Enum.all?(traffic.overview.chart.points, &(&1.value == 0 and &1.state == :none))
    assert traffic.overview.chart.caption == "No traffic recorded in this window"
    assert Enum.find(traffic.overview.tiles, &(&1.id == :traffic)).value == nil
    assert Enum.find(traffic.overview.tiles, &(&1.id == :traffic)).sub == "No traffic recorded"

    errors = HomepageData.load(%{"range" => "7d", "metric" => "errors"})

    assert errors.overview.chart.caption == "No issues were active in this window"
    assert Enum.all?(errors.overview.chart.points, &(&1.value == 0))
    assert Enum.find(errors.overview.tiles, &(&1.id == :errors)).tone == :ink
  end

  test "a range longer than the stored history says how much history exists" do
    vendor = vendor_fixture()
    %{monitor: monitor} = vendor_without_workspace_evidence(vendor)

    # The fixture already rolled up today, so three more days make four.
    for offset <- [-3, -2, -1] do
      seed_rollup(vendor, monitor, Date.add(Date.utc_today(), offset), 1.0)
    end

    PublicCache.clear()

    monthly = HomepageData.load(%{"range" => "30d"})

    assert monthly.overview.chart.caption == "4 days of history available"
    assert length(monthly.overview.chart.points) == 30
    assert Enum.count(monthly.overview.chart.points, &(&1.state == :none)) == 26
  end

  test "the hero reads exclude a data-rich sibling project" do
    vendor = vendor_fixture()
    _evidence = hero_evidence(vendor)
    outsider = sibling_hero_evidence(vendor)
    PublicCache.clear()

    for range <- ["24h", "7d", "30d"], metric <- ["uptime", "response", "traffic", "errors"] do
      data = HomepageData.load(%{"range" => range, "metric" => metric})
      values = data.overview.chart.points |> Enum.map(& &1.value) |> Enum.filter(&is_number/1)

      refute 9_001 in values
      refute 8_765 in values
      refute Enum.any?(values, &(&1 == 4_242))
      refute inspect(data) =~ outsider.project.id
      refute inspect(data) =~ "Outsider hero HTTP"
      refute inspect(data) =~ "Outsider hero issue"
    end

    traffic = HomepageData.load(%{"traffic" => "30d"})
    refute traffic.measure.pageviews == 9_001
    refute Enum.any?(traffic.measure.top_pages, &(&1.path == "/outsider-hero"))
  end

  test "no issue content, identifier or tenant id appears anywhere in the projection" do
    vendor = vendor_fixture()
    evidence = hero_evidence(vendor)
    outsider = sibling_hero_evidence(vendor)
    PublicCache.clear()

    for range <- ["24h", "7d", "30d"], metric <- ["uptime", "response", "traffic", "errors"] do
      rendered = inspect(HomepageData.load(%{"range" => range, "metric" => metric}))

      for private_value <- [
            vendor.org.id,
            vendor.project.id,
            evidence.monitor.id,
            evidence.worker.id,
            evidence.measure_source.id,
            evidence.observe_source.id,
            evidence.issue.id,
            outsider.project.id,
            "Vendor hero issue",
            "PRIVATE hero context",
            "Outsider hero issue"
          ] do
        refute rendered =~ private_value
      end
    end
  end

  test "the query count does not grow with more monitors, sources and issues" do
    vendor = vendor_fixture()
    _evidence = hero_evidence(vendor)
    PublicCache.clear()

    baseline = count_queries(fn -> HomepageData.load(%{"range" => "7d"}) end)

    grow_hero_evidence(vendor)
    PublicCache.clear()

    grown = count_queries(fn -> HomepageData.load(%{"range" => "7d"}) end)

    assert grown == baseline

    # The hero switch costs a bounded number of extra queries per range, and
    # a metric switch costs none.
    for range <- ["24h", "7d", "30d"] do
      PublicCache.clear()
      _warm = HomepageData.load(%{"range" => range})

      for metric <- ["uptime", "response", "traffic", "errors"] do
        assert count_queries(fn -> HomepageData.load(%{"range" => range, "metric" => metric}) end) ==
                 0
      end
    end

    PublicCache.clear()
    _base = HomepageData.load(%{"range" => "24h"})
    assert count_queries(fn -> HomepageData.load(%{"range" => "7d"}) end) <= 3
    assert count_queries(fn -> HomepageData.load(%{"traffic" => "30d"}) end) <= 2
  end

  defp count_queries(fun) do
    parent = self()
    ref = make_ref()
    handler_id = "homepage-query-count-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:alplus, :repo, :query],
      fn _event, _measurements, _metadata, _config -> send(parent, {ref, :query}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain_queries(ref, 0)
  end

  defp drain_queries(ref, count) do
    receive do
      {^ref, :query} -> drain_queries(ref, count + 1)
    after
      0 -> count
    end
  end

  defp hero_evidence(vendor) do
    monitor = hero_monitor(vendor, vendor.project, vendor.scope, "Vendor API", 60)
    worker = hero_monitor(vendor, vendor.project, vendor.scope, "Vendor Worker", 30)
    now = DateTime.utc_now()

    # Anchor the mixed hour to the middle of its bucket. Seeding by offset alone
    # put the failed check and its neighbour in different hours whenever the
    # clock sat near the top of an hour, which made the degraded bucket vanish.
    mixed_hour =
      now
      |> DateTime.add(-7_200, :second)
      |> Map.merge(%{minute: 30, second: 0, microsecond: {0, 6}})

    # Three checks in three different hours of the last day, one of them failed.
    seed_check(vendor, vendor.project, monitor, DateTime.add(now, -3_600, :second), "up", 120)
    seed_check(vendor, vendor.project, monitor, mixed_hour, "down", 900)
    seed_check(vendor, vendor.project, monitor, DateTime.add(mixed_hour, 60, :second), "up", 130)
    seed_check(vendor, vendor.project, monitor, DateTime.add(now, -10_800, :second), "up", 140)

    # Eight days of rollups, one of them a half day.
    for offset <- 0..7 do
      ratio = if offset == 2, do: 0.5, else: 1.0
      seed_rollup(vendor, monitor, Date.add(Date.utc_today(), -offset), ratio)
    end

    {measure_source, _token} =
      source_fixture(vendor.scope, vendor.org, vendor.project, %{
        type: :measure,
        name: "Vendor hero measure"
      })

    # 40 pageviews inside 7 days, 200 more inside 14 days, 1,000 more inside 30 days.
    record_pageviews(vendor, measure_source, "/hero", 40, -1)
    record_pageviews(vendor, measure_source, "/hero", 200, -9)
    record_pageviews(vendor, measure_source, "/hero", 1_000, -20)
    seed_analytics_hour(vendor, measure_source, DateTime.add(now, -3_600, :second), 17, 9)

    {observe_source, _secret} =
      source_fixture(vendor.scope, vendor.org, vendor.project, %{
        type: :observe,
        name: "Vendor hero observe"
      })

    issue =
      seed_issue(
        vendor,
        vendor.project,
        observe_source,
        "Vendor hero issue",
        "PRIVATE hero context",
        DateTime.add(now, -7_200, :second),
        "d"
      )

    PublicCache.clear()

    %{
      monitor: monitor,
      worker: worker,
      measure_source: measure_source,
      observe_source: observe_source,
      issue: issue
    }
  end

  defp grow_hero_evidence(vendor) do
    now = DateTime.utc_now()

    for index <- 1..3 do
      extra = hero_monitor(vendor, vendor.project, vendor.scope, "Vendor extra #{index}", 60)
      seed_check(vendor, vendor.project, extra, DateTime.add(now, -3_600, :second), "up", 111)
      seed_rollup(vendor, extra, Date.utc_today(), 1.0)
    end

    # A project holds one production Measure source, so traffic grows through
    # more page rows on the same source instead.
    {:ok, [source_id | _]} = Alplus.Measure.PublicEvidence.source_ids(vendor_actor())

    for index <- 1..4 do
      Rollups.record!(
        %{id: vendor.project.id, org_id: vendor.org.id},
        source_id,
        "production",
        %{type: "pageview", path: "/extra-#{index}", hostname: "vendor.example"},
        %{pageviews: 3, visitors: 3, visits: 3, bounces: 0, duration_seconds: 1},
        DateTime.add(now, -86_400, :second)
      )
    end

    {observe_source, _secret} =
      source_fixture(vendor.scope, vendor.org, vendor.project, %{
        type: :observe,
        name: "Vendor extra observe",
        environment: "staging"
      })

    for index <- 1..5 do
      seed_issue(
        vendor,
        vendor.project,
        %{observe_source | environment: "production"},
        "Vendor extra issue #{index}",
        "PRIVATE extra context",
        DateTime.add(now, -3_600, :second),
        "e#{index}"
      )
    end

    :ok
  end

  defp vendor_actor do
    {:ok, %{actor: actor}} = Alplus.Changelog.Public.resolve_vendor()
    actor
  end

  defp sibling_hero_evidence(vendor) do
    project = project_fixture(vendor.scope, vendor.org, %{name: "Outsider hero project"})
    scope = Scope.put_project(vendor.scope, project.id)
    now = DateTime.utc_now()

    monitor = hero_monitor(vendor, project, scope, "Outsider hero HTTP", 60)

    seed_check(vendor, project, monitor, DateTime.add(now, -3_600, :second), "up", 4_242)

    Ash.Seed.seed!(DailyRollup, %{
      org_id: vendor.org.id,
      project_id: project.id,
      environment: "production",
      monitor_id: monitor.id,
      day: Date.utc_today(),
      uptime_ratio: 0.1234,
      monitored_microseconds: 2_000_000,
      downtime_microseconds: 1_753_200,
      check_count: 9_001
    })

    {measure_source, _token} =
      source_fixture(scope, vendor.org, project, %{
        type: :measure,
        name: "Outsider hero measure",
        environment: "production"
      })

    Rollups.record!(
      %{id: project.id, org_id: vendor.org.id},
      measure_source.id,
      measure_source.environment,
      %{type: "pageview", path: "/outsider-hero", hostname: "outsider.example"},
      %{pageviews: 9_001, visitors: 8_765, visits: 8_765, bounces: 0, duration_seconds: 1},
      now
    )

    seed_analytics_hour(vendor, measure_source, now, 9_001, 8_765, project)

    {observe_source, _secret} =
      source_fixture(scope, vendor.org, project, %{type: :observe, name: "Outsider hero observe"})

    for index <- 1..9 do
      seed_issue(
        vendor,
        project,
        observe_source,
        "Outsider hero issue #{index}",
        "PRIVATE outsider hero context",
        DateTime.add(now, -3_600, :second),
        "f#{index}"
      )
    end

    PublicCache.clear()

    %{project: project, monitor: monitor, measure_source: measure_source}
  end

  defp hero_monitor(vendor, project, scope, name, interval_seconds) do
    {:ok, monitor} =
      Alplus.Monitoring.create_monitor(
        %{
          org_id: vendor.org.id,
          project_id: project.id,
          environment: "production",
          type: "http",
          name: name
        },
        actor: scope
      )

    Ash.create!(
      Alplus.Monitoring.HttpConfig,
      %{
        monitor_id: monitor.id,
        org_id: vendor.org.id,
        url: "https://hero.example/health",
        method: "GET",
        expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
        interval_seconds: interval_seconds,
        timeout_seconds: 5
      },
      action: :create,
      actor: scope
    )

    Ash.Seed.update!(monitor, %{last_known_status: "up"})
    monitor
  end

  defp seed_check(vendor, project, monitor, checked_at, status, latency_ms) do
    Ash.Seed.seed!(MonitorCheck, %{
      org_id: vendor.org.id,
      project_id: project.id,
      environment: "production",
      monitor_id: monitor.id,
      status: status,
      checked_at: checked_at,
      latency_ms: latency_ms
    })
  end

  defp seed_analytics_hour(vendor, source, at, pageviews, visitors, project \\ nil) do
    :ok =
      AnalyticsEngine.record(%{
        org_id: vendor.org.id,
        project_id: (project || vendor.project).id,
        source_id: source.id,
        hour: DateTime.truncate(at, :second),
        pageviews: pageviews,
        visitors: visitors,
        visits: visitors,
        bounces: 0,
        duration_seconds: 1
      })

    :ok = AnalyticsEngine.Batcher.flush()
  end

  defp seed_issue(vendor, project, source, title, context, last_seen_at, salt) do
    Ash.Seed.seed!(Issue, %{
      org_id: vendor.org.id,
      project_id: project.id,
      source_id: source.id,
      environment: source.environment,
      fingerprint: "sha256:" <> String.pad_leading(salt, 64, "0"),
      level: "error",
      status: :open,
      title: title,
      first_seen_at: last_seen_at,
      last_seen_at: last_seen_at,
      event_count: 1,
      context_summary: %{"request_context" => context}
    })
  end

  defp vendor_fixture do
    {org, owner_scope} = org_fixture(scope_fixture())

    project =
      project_fixture(owner_scope, org, %{
        name: "Vendor private project"
      })

    scope = Scope.put_project(owner_scope, project.id)

    {:ok, status_page} =
      Status.create_page(scope, %{
        org_id: org.id,
        project_id: project.id,
        public_slug: "public-vendor",
        title: "Public Vendor"
      })

    {:ok, _changelog} =
      Changelog.create_changelog(
        %{
          org_id: org.id,
          project_id: project.id,
          public_title: "Public Vendor",
          public_slug: "public-vendor"
        },
        actor: scope
      )

    {:ok, _vendor} = Changelog.designate_vendor_by_public_token(project.public_token)

    {:ok, identity} = PublicPages.get_for_project(scope, project.id)
    {:ok, _published_identity} = PublicPages.publish(scope, identity)

    %{org: org, project: project, scope: scope, status_page: status_page}
  end

  defp complete_public_evidence(vendor) do
    {:ok, monitor} =
      Alplus.Monitoring.create_monitor(
        %{
          org_id: vendor.org.id,
          project_id: vendor.project.id,
          environment: "production",
          type: "http",
          name: "Public API"
        },
        actor: vendor.scope
      )

    Ash.Seed.update!(monitor, %{last_known_status: "up"})

    # Seven observed days: the public page publishes a percentage only once
    # a week of evidence exists, and the homepage reads the same records.
    for offset <- 1..7 do
      Ash.Seed.seed!(DailyRollup, %{
        org_id: vendor.org.id,
        project_id: vendor.project.id,
        environment: "production",
        monitor_id: monitor.id,
        day: Date.add(Date.utc_today(), -offset),
        uptime_ratio: 0.9875,
        monitored_microseconds: 4_000_000,
        downtime_microseconds: 50_000,
        check_count: 1
      })
    end

    {:ok, component} =
      Status.create_component(vendor.scope, %{
        org_id: vendor.org.id,
        project_id: vendor.project.id,
        status_page_id: vendor.status_page.id,
        name: "Public API"
      })

    :ok = Status.link_monitor(vendor.scope, component, monitor.id)

    {:ok, worker} =
      Alplus.Monitoring.create_monitor(
        %{
          org_id: vendor.org.id,
          project_id: vendor.project.id,
          environment: "production",
          type: "http",
          name: "Public Worker"
        },
        actor: vendor.scope
      )

    Ash.Seed.update!(worker, %{last_known_status: "up"})

    # Seven observed days: the public page publishes a percentage only once
    # a week of evidence exists, and the homepage reads the same records.
    for offset <- 1..7 do
      Ash.Seed.seed!(DailyRollup, %{
        org_id: vendor.org.id,
        project_id: vendor.project.id,
        environment: "production",
        monitor_id: worker.id,
        day: Date.add(Date.utc_today(), -offset),
        uptime_ratio: 0.9625,
        monitored_microseconds: 4_000_000,
        downtime_microseconds: 150_000,
        check_count: 1
      })
    end

    {:ok, worker_component} =
      Status.create_component(vendor.scope, %{
        org_id: vendor.org.id,
        project_id: vendor.project.id,
        status_page_id: vendor.status_page.id,
        name: "Public Worker"
      })

    :ok = Status.link_monitor(vendor.scope, worker_component, worker.id)
    {:ok, _page} = Status.publish_page(vendor.scope, vendor.status_page)

    {measure_source, _measure_token} =
      source_fixture(vendor.scope, vendor.org, vendor.project, %{
        type: :measure,
        name: "Public Analytics",
        hostname: "private-analytics.internal"
      })

    share =
      Ash.create!(
        DashboardShare,
        %{
          org_id: vendor.org.id,
          project_id: vendor.project.id,
          source_id: measure_source.id
        },
        actor: vendor.scope
      )

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    :ok =
      AnalyticsEngine.record(%{
        org_id: vendor.org.id,
        project_id: vendor.project.id,
        source_id: measure_source.id,
        hour: now,
        pageviews: 37,
        visitors: 11,
        visits: 11,
        bounces: 0,
        duration_seconds: 30
      })

    :ok = AnalyticsEngine.Batcher.flush()

    :ok =
      AnalyticsEngine.record(%{
        org_id: vendor.org.id,
        project_id: vendor.project.id,
        source_id: measure_source.id,
        hour: DateTime.add(now, -8 * 3_600 * 24, :second),
        pageviews: 1,
        visitors: 1,
        visits: 1,
        bounces: 0,
        duration_seconds: 1
      })

    :ok = AnalyticsEngine.Batcher.flush()

    Rollups.record!(
      %{id: vendor.project.id, org_id: vendor.org.id},
      measure_source.id,
      measure_source.environment,
      %{type: "pageview", path: "/public-pricing", hostname: "private-analytics.internal"},
      %{pageviews: 37, visitors: 11, visits: 11, bounces: 0, duration_seconds: 30},
      now
    )

    {observe_source, _observe_secret} =
      source_fixture(vendor.scope, vendor.org, vendor.project, %{
        type: :observe,
        name: "Public Observe"
      })

    now = DateTime.utc_now()

    issue =
      Ash.create!(
        Issue,
        %{
          org_id: vendor.org.id,
          project_id: vendor.project.id,
          source_id: observe_source.id,
          environment: observe_source.environment,
          fingerprint: "sha256:" <> String.duplicate("a", 64),
          level: "error",
          title: "Public issue",
          first_seen_at: now,
          last_seen_at: now,
          event_count: 7,
          context_summary: %{"request_context" => "PRIVATE observe context"}
        },
        action: :record,
        authorize?: false
      )

    {:ok, _release} =
      Observe.create_release(
        %{
          org_id: vendor.org.id,
          project_id: vendor.project.id,
          source_id: observe_source.id,
          environment: observe_source.environment,
          version: "2026.08.27",
          released_at: now,
          commit_sha: "abcdef1"
        },
        actor: vendor.scope
      )

    entry =
      changelog_draft(vendor, "Public vendor release", "PRIVATE changelog source")

    {:ok, _published_entry} = Changelog.publish_entry(entry, 1, actor: vendor.scope)
    PublicCache.clear()

    %{
      monitor: monitor,
      measure_source: measure_source,
      observe_source: observe_source,
      issue: issue,
      share: share
    }
  end

  defp vendor_without_workspace_evidence(vendor) do
    {:ok, monitor} =
      Alplus.Monitoring.create_monitor(
        %{
          org_id: vendor.org.id,
          project_id: vendor.project.id,
          environment: "production",
          type: "http",
          name: "Vendor HTTP"
        },
        actor: vendor.scope
      )

    Ash.Seed.update!(monitor, %{last_known_status: "up"})

    Ash.Seed.seed!(DailyRollup, %{
      org_id: vendor.org.id,
      project_id: vendor.project.id,
      environment: "production",
      monitor_id: monitor.id,
      day: Date.utc_today(),
      uptime_ratio: 0.995,
      monitored_microseconds: 2_000_000,
      downtime_microseconds: 10_000,
      check_count: 10
    })

    Ash.Seed.seed!(MonitorCheck, %{
      org_id: vendor.org.id,
      environment: "production",
      project_id: vendor.project.id,
      monitor_id: monitor.id,
      status: "up",
      checked_at: DateTime.utc_now(),
      latency_ms: 142
    })

    {measure_source, _token} =
      source_fixture(vendor.scope, vendor.org, vendor.project, %{
        type: :measure,
        name: "Vendor Measure"
      })

    Rollups.record!(
      %{id: vendor.project.id, org_id: vendor.org.id},
      measure_source.id,
      measure_source.environment,
      %{type: "pageview", path: "/vendor", hostname: "vendor.example"},
      %{pageviews: 12, visitors: 8, visits: 8, bounces: 0, duration_seconds: 3},
      DateTime.utc_now()
    )

    %{monitor: monitor, measure_source: measure_source}
  end

  defp sibling_without_workspace_evidence(vendor) do
    project = project_fixture(vendor.scope, vendor.org, %{name: "Outsider fallback project"})
    scope = Scope.put_project(vendor.scope, project.id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, monitor} =
      Alplus.Monitoring.create_monitor(
        %{
          org_id: vendor.org.id,
          project_id: project.id,
          environment: "production",
          type: "http",
          name: "Outsider fallback HTTP"
        },
        actor: scope
      )

    Ash.Seed.update!(monitor, %{last_known_status: "up"})

    Ash.Seed.seed!(DailyRollup, %{
      org_id: vendor.org.id,
      project_id: project.id,
      environment: "production",
      monitor_id: monitor.id,
      day: Date.utc_today(),
      uptime_ratio: 0.1234,
      monitored_microseconds: 2_000_000,
      downtime_microseconds: 1_753_200,
      check_count: 9_001
    })

    Ash.Seed.seed!(MonitorCheck, %{
      org_id: vendor.org.id,
      project_id: project.id,
      environment: "production",
      monitor_id: monitor.id,
      status: "up",
      checked_at: now,
      latency_ms: 987
    })

    {measure_source, _token} =
      source_fixture(scope, vendor.org, project, %{
        type: :measure,
        name: "Outsider fallback Measure",
        environment: "production"
      })

    Rollups.record!(
      %{id: project.id, org_id: vendor.org.id},
      measure_source.id,
      measure_source.environment,
      %{type: "pageview", path: "/outsider-fallback", hostname: "outsider.example"},
      %{pageviews: 9_001, visitors: 8_765, visits: 8_765, bounces: 0, duration_seconds: 1},
      now
    )

    PublicCache.clear()

    %{project: project, monitor: monitor, measure_source: measure_source}
  end

  defp non_vendor_evidence(vendor) do
    project = project_fixture(vendor.scope, vendor.org, %{name: "Private outsider project"})
    scope = Scope.put_project(vendor.scope, project.id)

    {:ok, monitor} =
      Alplus.Monitoring.create_monitor(
        %{
          org_id: vendor.org.id,
          project_id: project.id,
          type: "http",
          name: "Private outsider monitor"
        },
        actor: scope
      )

    Ash.Seed.update!(monitor, %{last_known_status: "up"})

    {measure_source, _measure_token} =
      source_fixture(scope, vendor.org, project, %{
        type: :measure,
        name: "Private outsider analytics"
      })

    _share =
      Ash.create!(
        DashboardShare,
        %{
          org_id: vendor.org.id,
          project_id: project.id,
          source_id: measure_source.id
        },
        actor: scope
      )

    Rollups.record!(
      %{id: project.id, org_id: vendor.org.id},
      measure_source.id,
      measure_source.environment,
      %{type: "pageview", path: "/private", hostname: "private-outsider.internal"},
      %{pageviews: 9_001, visitors: 9_001, visits: 9_001, bounces: 0, duration_seconds: 1},
      DateTime.utc_now()
    )

    {observe_source, _observe_secret} =
      source_fixture(scope, vendor.org, project, %{
        type: :observe,
        name: "Private outsider observe"
      })

    now = DateTime.utc_now()

    _issue =
      Ash.create!(
        Issue,
        %{
          org_id: vendor.org.id,
          project_id: project.id,
          source_id: observe_source.id,
          environment: observe_source.environment,
          fingerprint: "sha256:" <> String.duplicate("b", 64),
          level: "error",
          title: "Private outsider issue",
          first_seen_at: now,
          last_seen_at: now,
          event_count: 9_001,
          context_summary: %{"request_context" => "PRIVATE outsider context"}
        },
        action: :record,
        authorize?: false
      )

    {:ok, _release} =
      Observe.create_release(
        %{
          org_id: vendor.org.id,
          project_id: project.id,
          source_id: observe_source.id,
          environment: observe_source.environment,
          version: "Private outsider release",
          released_at: now,
          commit_sha: "bcdef12"
        },
        actor: scope
      )

    PublicCache.clear()

    %{
      project: project,
      monitor: monitor,
      measure_source: measure_source,
      observe_source: observe_source
    }
  end

  defp publish_component_without_monitor(vendor) do
    {:ok, monitor} =
      Alplus.Monitoring.create_monitor(
        %{
          org_id: vendor.org.id,
          environment: "production",
          project_id: vendor.project.id,
          type: "http",
          name: "Published service monitor"
        },
        actor: vendor.scope
      )

    {:ok, component} =
      Status.create_component(vendor.scope, %{
        org_id: vendor.org.id,
        project_id: vendor.project.id,
        status_page_id: vendor.status_page.id,
        name: "Published service without monitor"
      })

    :ok = Status.link_monitor(vendor.scope, component, monitor.id)
    {:ok, _page} = Status.publish_page(vendor.scope, vendor.status_page)
    PublicCache.clear()
  end

  defp changelog_draft(vendor, title, private_source_label) do
    {:ok, entry} =
      Changelog.upsert_draft(
        %{
          project_id: vendor.project.id,
          grant_id: Alplus.Id.generate(:mcp_oauth_grant),
          external_id: "homepage-#{System.unique_integer([:positive])}",
          markdown: "---\ntitle: #{title}\nversion: 2026.08.27\n---\nPublic release notes",
          sources: [
            %{
              kind: "release",
              url: "https://example.test/private-release",
              label: private_source_label
            }
          ]
        },
        actor: vendor.scope
      )

    entry
  end

  defp publish_vendor_entry(vendor, title) do
    entry = changelog_draft(vendor, title, "PRIVATE changelog source")
    {:ok, published} = Changelog.publish_entry(entry, 1, actor: vendor.scope)
    PublicCache.clear()
    published
  end

  defp record_pageviews(vendor, source, path, pageviews, day_offset) do
    Rollups.record!(
      %{id: vendor.project.id, org_id: vendor.org.id},
      source.id,
      source.environment,
      %{type: "pageview", path: path, hostname: "vendor.example"},
      %{
        pageviews: pageviews,
        visitors: pageviews,
        visits: pageviews,
        bounces: 0,
        duration_seconds: 1
      },
      DateTime.add(DateTime.utc_now(), day_offset * 86_400, :second)
    )
  end

  defp seed_rollup(vendor, monitor, day, uptime_ratio) do
    Ash.Seed.seed!(DailyRollup, %{
      org_id: vendor.org.id,
      project_id: vendor.project.id,
      environment: "production",
      monitor_id: monitor.id,
      day: day,
      uptime_ratio: uptime_ratio,
      monitored_microseconds: 1_000_000,
      downtime_microseconds: round(1_000_000 * (1 - uptime_ratio)),
      check_count: 1
    })
  end

  defp set_preview_flag(value) do
    previous = Application.get_env(:alplus, :homepage_preview_when_unconfigured)
    Application.put_env(:alplus, :homepage_preview_when_unconfigured, value)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:alplus, :homepage_preview_when_unconfigured)
      else
        Application.put_env(:alplus, :homepage_preview_when_unconfigured, previous)
      end
    end)
  end
end
