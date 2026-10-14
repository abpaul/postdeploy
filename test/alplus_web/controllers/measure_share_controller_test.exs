defmodule AlplusWeb.MeasureShareControllerTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Measure.{
    AnalyticsEngine,
    Dashboard,
    DashboardShare,
    PublicCache,
    PublicDashboard,
    RateLimiter,
    Rollups
  }

  alias Alplus.Scope

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)
    {source, _source_token} = source_fixture(scope, org, project, %{type: :measure})

    share =
      Ash.create!(
        DashboardShare,
        %{org_id: org.id, project_id: project.id, source_id: source.id},
        actor: scope
      )

    :ets.delete_all_objects(RateLimiter)
    PublicCache.clear()

    %{
      org: org,
      project: project,
      scope: scope,
      source: source,
      share: share,
      token: Ash.Resource.get_metadata(share, :token)
    }
  end

  test "the default public page fetches only headlines, chart, and pages", context do
    record_page!(context, "/pricing")

    response = get(context.conn, ~p"/share/#{context.token}?window=30d&metric=pageviews")

    assert html_response(response, 200)
    assert response.resp_body =~ ~s(id="measure-public-headlines")
    assert response.resp_body =~ ~s(id="measure-public-chart")
    assert response.resp_body =~ ~s(id="measure-public-panel-pages")
    assert response.resp_body =~ ~s(id="measure-public-breakdown-grid")
    assert response.resp_body =~ ~s(id="measure-public-source-identity")
    assert response.resp_body =~ ~s(id="measure-public-chart-title")
    refute response.resp_body =~ ~s(id="measure-public-headline-visitors")
    assert response.resp_body =~ ~s(id="measure-public-panel-pages-bars")
    assert response.resp_body =~ ~s(id="measure-public-panel-pages-table")
    assert response.resp_body =~ ~s(data-mobile-layout="stacked")
    refute response.resp_body =~ ~s(id="measure-public-panel-sources")
    refute response.resp_body =~ ~s(id="measure-public-panel-events")

    document = LazyHTML.from_document(response.resp_body)

    dashboard = LazyHTML.query(document, "#measure-public-dashboard")
    refute LazyHTML.text(dashboard) =~ context.token

    hrefs = LazyHTML.attribute(LazyHTML.query(dashboard, "[href]"), "href")
    anchor_hrefs = LazyHTML.attribute(LazyHTML.query(dashboard, "a[href]"), "href")
    assert hrefs != []
    assert Enum.all?(hrefs, &(not String.contains?(&1, context.token)))

    assert Enum.all?(anchor_hrefs, fn href ->
             href in ["/analytics", "/register"] or String.starts_with?(href, "?")
           end)

    assert "/analytics" in anchor_hrefs
    assert "/register" in anchor_hrefs

    cached_panels =
      Alplus.Measure.PublicCache
      |> :ets.tab2list()
      |> Enum.map(fn {{_share_id, _updated_at, _window, panel, _variant}, _value, _expires} ->
        panel
      end)

    assert Enum.sort(cached_panels) == [:chart, :headline_cards, :pages]
  end

  test "token-bearing share HTML is noindex and has no canonical", context do
    html =
      context.conn
      |> get(~p"/share/#{context.token}")
      |> html_response(200)

    document = LazyHTML.from_document(html)

    assert LazyHTML.attribute(LazyHTML.query(document, ~s(meta[name="robots"])), "content") ==
             ["noindex,nofollow"]

    assert document |> LazyHTML.query(~s(link[rel="canonical"])) |> Enum.empty?()
  end

  test "panel page parameters are bounded before loading and caching", context do
    response = get(context.conn, ~p"/share/#{context.token}?pages_page=999")

    assert html_response(response, 200)
    refute response.resp_body =~ "pages_page=26"

    cached_pages =
      Alplus.Measure.PublicCache
      |> :ets.tab2list()
      |> Enum.filter(fn {{_share_id, _updated_at, _window, panel, _variant}, _value, _expires} ->
        panel == :pages
      end)
      |> Enum.map(fn {{_share_id, _updated_at, _window, _panel, page}, _value, _expires} ->
        page
      end)

    assert cached_pages == [25]
  end

  test "public real-time charts prefer Analytics Engine points", context do
    :ok = AnalyticsEngine.Batcher.flush()
    :ok = AnalyticsEngine.DevAdapter.clear()
    on_exit(fn -> AnalyticsEngine.DevAdapter.clear() end)

    :ok =
      AnalyticsEngine.record(%{
        org_id: context.org.id,
        project_id: context.project.id,
        source_id: context.source.id,
        hour: DateTime.utc_now() |> DateTime.truncate(:second),
        pageviews: 3,
        visitors: 2,
        visits: 2,
        bounces: 0,
        duration_seconds: 0
      })

    :ok = AnalyticsEngine.Batcher.flush()
    PublicCache.clear()

    response = get(context.conn, ~p"/share/#{context.token}?window=24h")

    assert html_response(response, 200) =~ "Analytics Engine"
  end

  test "a public partial headline keeps its lower bound", context do
    :ok = AnalyticsEngine.Batcher.flush()
    :ok = AnalyticsEngine.DevAdapter.clear()
    on_exit(fn -> AnalyticsEngine.DevAdapter.clear() end)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    :ok =
      AnalyticsEngine.record(%{
        org_id: context.org.id,
        project_id: context.project.id,
        source_id: context.source.id,
        hour: now,
        pageviews: 3,
        visitors: 3,
        visits: 3,
        bounces: 0,
        duration_seconds: 0
      })

    :ok = AnalyticsEngine.Batcher.flush()
    Alplus.Repo.query!("ALTER TABLE analytics_hours RENAME TO analytics_hours_unavailable")

    actor = %Alplus.Measure.ShareActor{
      share_id: context.share.id,
      org_id: context.org.id,
      project_id: context.project.id,
      source_id: context.source.id,
      environment: context.source.environment,
      panels: context.share.panels
    }

    dashboard =
      PublicDashboard.load(
        context.share,
        context.source,
        actor,
        "24h",
        ["pageviews"],
        %{pages: 1, sources: 1, events: 1, countries: 1, browsers: 1}
      )

    assert dashboard.headline_cards.state == :partial
    assert dashboard.headline_cards.partial?
    refute dashboard.headline_cards.unavailable?
    assert dashboard.headline_cards.pageviews.value == nil
    assert dashboard.headline_cards.pageviews.known_value == 3
    assert dashboard.state == :partial
  end

  test "a public mixed chart keeps partial resolver metadata", context do
    :ok = AnalyticsEngine.Batcher.flush()
    :ok = AnalyticsEngine.DevAdapter.clear()
    on_exit(fn -> AnalyticsEngine.DevAdapter.clear() end)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    :ok =
      AnalyticsEngine.record(%{
        org_id: context.org.id,
        project_id: context.project.id,
        source_id: context.source.id,
        hour: now,
        pageviews: 3,
        visitors: 3,
        visits: 3,
        bounces: 0,
        duration_seconds: 0
      })

    :ok = AnalyticsEngine.Batcher.flush()
    insert_hour!(context, 2, DateTime.add(now, -3_600, :second))
    PublicCache.clear()

    response = get(context.conn, ~p"/share/#{context.token}?window=24h")
    assert html_response(response, 200)

    [{{_share_id, _updated_at, "24h", :chart, _metrics}, chart, _expires}] =
      :ets.match_object(PublicCache, {{context.share.id, :_, "24h", :chart, :_}, :_, :_})

    assert chart.data_source_key == :mixed_rollup
    assert chart.partial?
    assert chart.state == :partial
  end

  test "public comparisons hide prior values outside plan retention", context do
    subscribed_fixture(context.org)

    actor = %Alplus.Measure.ShareActor{
      share_id: context.share.id,
      org_id: context.org.id,
      project_id: context.project.id,
      source_id: context.source.id,
      environment: context.source.environment,
      panels: context.share.panels
    }

    old_now = DateTime.add(DateTime.utc_now(), -800 * 86_400, :second)
    headlines = Dashboard.headlines(context.source, "30d", actor, now: old_now)

    assert headlines.visits.value == nil
    assert headlines.visits.previous == nil
    assert headlines.pageviews.value == nil
    assert headlines.pageviews.previous == nil
  end

  test "an Ash-wrapped durable read failure renders an unavailable public state", context do
    database_error =
      Ash.Error.Unknown.exception(
        errors: [
          Ash.Error.Unknown.UnknownError.exception(
            error: DBConnection.ConnectionError.exception("forced durable read failure")
          )
        ]
      )

    actor = %Alplus.Measure.ShareActor{
      share_id: context.share.id,
      org_id: context.org.id,
      project_id: context.project.id,
      source_id: context.source.id,
      environment: context.source.environment,
      panels: context.share.panels
    }

    dashboard =
      PublicDashboard.load(
        context.share,
        context.source,
        actor,
        "30d",
        ["visits"],
        %{pages: 1, sources: 1, events: 1, countries: 1, browsers: 1},
        public_period_points: fn _window, _actor, _since, _until -> raise database_error end
      )

    assert dashboard.headline_cards.state == :unavailable
    assert dashboard.headline_cards.unavailable?
    assert dashboard.state == :unavailable
  end

  test "public metric cards select the one plotted metric", context do
    record_page!(context, "/pricing")

    response =
      get(
        context.conn,
        ~p"/share/#{context.token}?window=30d&metrics=visits,pageviews,bounce_rate,avg_duration"
      )

    assert html_response(response, 200)

    # One metric is plotted, and it is the first valid entry of the request.
    assert response.resp_body =~ ~s(data-metric="visits")
    refute response.resp_body =~ ~s(data-metric="pageviews")

    for metric <- ~w(visits pageviews bounce_rate avg_duration) do
      assert response.resp_body =~ ~s(id="measure-public-headline-#{metric}")
    end

    document = LazyHTML.from_document(response.resp_body)

    assert document
           |> LazyHTML.query(
             "#measure-public-headline-visits[aria-current='true'] [data-selected-indicator]"
           )
           |> LazyHTML.to_html() != ""

    # Selecting is exclusive: only the plotted metric is marked current.
    assert document
           |> LazyHTML.query("[aria-current='true'][id^='measure-public-headline-']")
           |> LazyHTML.to_html()
           |> then(&length(Regex.scan(~r/aria-current="true"/, &1))) == 1

    # Each card selects itself rather than toggling a comma-separated set. The
    # request's own list survives only on the panel pagination links, which
    # carry the reader's URL forward unchanged.
    for metric <- ~w(visits pageviews bounce_rate avg_duration) do
      assert response.resp_body =~ "metrics=#{metric}&amp;window=30d" or
               response.resp_body =~ "metrics=#{metric}&window=30d" or
               response.resp_body =~ "window=30d&amp;metrics=#{metric}" or
               response.resp_body =~ "window=30d&metrics=#{metric}"
    end
  end

  test "selected event and source panels render counts", context do
    share =
      Ash.update!(
        context.share,
        %{panels: [:headline_cards, :events, :sources]},
        action: :update_panels,
        actor: context.scope
      )

    token = rotate_token!(share, context.scope)
    project_ref = %{id: context.project.id, org_id: context.org.id}
    now = DateTime.utc_now()

    Rollups.record_event!(
      project_ref,
      context.source.id,
      context.source.environment,
      "signup",
      now
    )

    Rollups.record_dimension!(
      project_ref,
      context.source.id,
      context.source.environment,
      DateTime.to_date(now),
      "referrer",
      "google.com",
      %{pageviews: 1, visitors: 1, visits: 0}
    )

    Alplus.Repo.query!(
      """
      UPDATE analytics_dimensions
      SET visits = NULL
      WHERE org_id = $1 AND project_id = $2 AND source_id = $3
        AND environment = $4 AND date = $5 AND dimension = $6 AND value = $7
      """,
      [
        context.org.id,
        context.project.id,
        context.source.id,
        context.source.environment,
        DateTime.to_date(now),
        "referrer",
        "google.com"
      ]
    )

    response = get(context.conn, ~p"/share/#{token}?window=30d")
    assert html_response(response, 200)
    assert response.resp_body =~ ~s(id="measure-public-panel-events")
    assert response.resp_body =~ ~s(id="measure-public-panel-sources")
    assert response.resp_body =~ ~s(id="measure-public-panel-sources-partial")
    assert response.resp_body =~ "signup"
    assert response.resp_body =~ "google.com"
  end

  test "a capped panel labels its visible count as a lower bound", context do
    project_ref = %{id: context.project.id, org_id: context.org.id}
    date = Date.utc_today()

    for value <- ["/pricing", Rollups.other_value()] do
      Rollups.record_dimension!(
        project_ref,
        context.source.id,
        context.source.environment,
        date,
        "path",
        value,
        %{pageviews: 1, visitors: 1, visits: 1}
      )
    end

    response = get(context.conn, ~p"/share/#{context.token}?window=30d")
    assert html_response(response, 200) =~ "At least 2 values"
  end

  test "all four windows are available and an empty window explains retention", context do
    for window <- ~w(24h 7d 30d 90d) do
      response = get(build_conn(), ~p"/share/#{context.token}?window=#{window}")
      assert html_response(response, 200)
    end

    response = get(context.conn, ~p"/share/#{context.token}?window=90d")
    assert response.resp_body =~ "No retained data for this window"
    assert response.resp_body =~ ~s(data-state="empty")
  end

  test "daily public charts expose their UTC bucket dates", context do
    record_page!(context, "/pricing")
    today_label = Calendar.strftime(Date.utc_today(), "%b %-d UTC")

    for window <- ~w(30d 90d) do
      response = get(build_conn(), ~p"/share/#{context.token}?window=#{window}")
      assert html_response(response, 200) =~ today_label
    end
  end

  test "a missing public rate value renders as a chart gap", context do
    Rollups.record!(
      %{id: context.project.id, org_id: context.org.id},
      context.source.id,
      context.source.environment,
      %{type: "pageview", path: "/pricing", hostname: "example.com"},
      %{pageviews: 1, visitors: 0, visits: 0, bounces: 0, duration_seconds: 0},
      DateTime.utc_now()
    )

    response = get(context.conn, ~p"/share/#{context.token}?window=30d&metric=bounce_rate")

    assert html_response(response, 200)
    # A metric with no measured value keeps its plot slot and says so, rather
    # than drawing a zero line or a filled gray placeholder.
    assert response.resp_body =~ ~s(data-display-state="empty")
    assert response.resp_body =~ "No data in this range yet."
    refute response.resp_body =~ ~s(id="measure-public-bar-0")
  end

  test "rotation returns 404 for the previous URL", context do
    new_token = rotate_token!(context.share, context.scope)

    assert_raise AlplusWeb.NotFoundError, fn ->
      get(context.conn, ~p"/share/#{context.token}")
    end

    assert build_conn() |> get(~p"/share/#{new_token}") |> html_response(200)
  end

  test "the public page is limited per share", context do
    for _request <- 1..60, do: assert(:ok == RateLimiter.check_share(context.share.id))

    response = get(context.conn, ~p"/share/#{context.token}")
    assert response.status == 429
    assert [_retry_after] = get_resp_header(response, "retry-after")
  end

  test "the short-lived cache evaluates a panel load once", _context do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    key = {:test, System.unique_integer()}
    loader = fn -> Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) end

    assert PublicCache.fetch(key, loader) == 1
    assert PublicCache.fetch(key, loader) == 1
    assert Agent.get(counter, & &1) == 1
  end

  test "concurrent cache misses evaluate one panel load", _context do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    key = {:concurrent_test, System.unique_integer()}

    loader = fn ->
      Agent.update(counter, &(&1 + 1))
      Process.sleep(20)
      :loaded
    end

    results =
      1..10
      |> Task.async_stream(fn _request -> PublicCache.fetch(key, loader) end,
        max_concurrency: 10,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert results == List.duplicate(:loaded, 10)
    assert Agent.get(counter, & &1) == 1
  end

  defp record_page!(context, path) do
    Rollups.record!(
      %{id: context.project.id, org_id: context.org.id},
      context.source.id,
      context.source.environment,
      %{type: "pageview", path: path, hostname: "example.com"},
      %{pageviews: 2, visitors: 1, visits: 1, bounces: 0, duration_seconds: 30},
      DateTime.utc_now()
    )
  end

  defp insert_hour!(context, pageviews, hour) do
    Alplus.Repo.query!(
      """
      INSERT INTO analytics_hours
        (id, org_id, project_id, source_id, environment, hour, pageviews, visitors, visits, bounces,
         duration_seconds, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $7, $7, 0, 0, now(), now())
      """,
      [
        Ecto.UUID.generate() |> Ecto.UUID.dump!(),
        context.org.id,
        context.project.id,
        context.source.id,
        context.source.environment,
        hour,
        pageviews
      ]
    )
  end

  defp rotate_token!(share, scope) do
    share
    |> Ash.update!(%{}, action: :rotate, actor: scope)
    |> Ash.Resource.get_metadata(:token)
  end
end
