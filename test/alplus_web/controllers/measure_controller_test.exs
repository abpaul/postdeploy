defmodule AlplusWeb.MeasureControllerTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures
  import ExUnit.CaptureLog

  alias Alplus.Projects.ProjectDomain
  alias Alplus.Scope
  alias Alplus.Billing.Package
  alias Alplus.Measure.Goal
  alias Alplus.Billing.EventMeter

  @measure_contract Path.expand("../../../sdks/contract/measure_event.json", __DIR__)
  @external_resource @measure_contract

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    Ash.create!(
      ProjectDomain,
      %{org_id: org.id, project_id: project.id, hostname: "app.example.test"},
      action: :create,
      actor: scope
    )

    {source, token} =
      source_fixture(owner_scope, org, project, %{type: :measure, environment: "staging"})

    :ets.delete_all_objects(Alplus.Measure.RateLimiter)

    %{org: org, project: project, scope: scope, source: source, token: token}
  end

  test "accepted hits and valid rejected hits have identical 204 responses", %{
    conn: conn,
    project: project,
    token: token
  } do
    accepted =
      post_hit(conn, token, "https://app.example.test/pricing", "https://app.example.test")

    unknown =
      post_hit(
        build_conn(),
        "msr_00000000000000000000000000",
        "https://app.example.test/pricing",
        "https://app.example.test"
      )

    missing_origin = post_hit(build_conn(), token, "https://app.example.test/pricing", nil)

    mismatched_origin =
      post_hit(
        build_conn(),
        token,
        "https://app.example.test/pricing",
        "https://wrong.example.test"
      )

    for response <- [accepted, unknown, missing_origin, mismatched_origin] do
      assert response.status == 204
      assert response.resp_body == ""
      refute get_resp_header(response, "access-control-allow-origin") != []
    end

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM analytics_hours WHERE org_id = $1 AND project_id = $2",
               [project.org_id, project.id]
             )
  end

  test "two sites sharing a project and environment stay isolated through the real ingest path",
       %{
         conn: conn,
         org: org,
         project: project,
         scope: scope,
         source: site_a,
         token: token_a
       } do
    {site_b, token_b} =
      source_fixture(scope, org, project, %{type: :measure, environment: "staging"})

    assert site_a.environment == site_b.environment
    assert site_a.id != site_b.id

    assert post_hit(conn, token_a, "https://app.example.test/a", "https://app.example.test").status ==
             204

    assert post_hit(
             build_conn(),
             token_b,
             "https://app.example.test/b",
             "https://app.example.test"
           ).status == 204

    assert post_hit(
             build_conn(),
             token_b,
             "https://app.example.test/b-2",
             "https://app.example.test"
           ).status == 204

    # One request to site A, then two requests to site B, all sharing one
    # project, environment, remote IP, user agent, and 30-minute window
    # (ADR 0002). This is the seam a source-unscoped `VisitorHash` or
    # visit-state key would break: site A's single hit must land as its
    # own bounce, and site B's second hit must correct site B's bounce
    # without ever touching site A's counters.
    assert %{rows: [[1, 1, 1, 1]]} =
             Alplus.Repo.query!(
               "SELECT pageviews, visitors, visits, bounces FROM analytics_hours WHERE source_id = $1",
               [site_a.id]
             )

    assert %{rows: [[2, 1, 1, 0]]} =
             Alplus.Repo.query!(
               "SELECT pageviews, visitors, visits, bounces FROM analytics_hours WHERE source_id = $1",
               [site_b.id]
             )

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT pageviews FROM analytics_days WHERE source_id = $1",
               [site_a.id]
             )

    assert %{rows: [[2]]} =
             Alplus.Repo.query!(
               "SELECT pageviews FROM analytics_days WHERE source_id = $1",
               [site_b.id]
             )

    assert %{rows: [["/a"]]} =
             Alplus.Repo.query!(
               "SELECT value FROM analytics_dimensions WHERE source_id = $1 AND dimension = 'path'",
               [site_a.id]
             )

    assert %{rows: rows} =
             Alplus.Repo.query!(
               "SELECT value FROM analytics_dimensions WHERE source_id = $1 AND dimension = 'path' ORDER BY value",
               [site_b.id]
             )

    assert rows == [["/b"], ["/b-2"]]

    assert %{rows: [["/a", 1]]} =
             Alplus.Repo.query!(
               "SELECT value, visits FROM analytics_dimensions WHERE source_id = $1 AND dimension = 'landing_page'",
               [site_a.id]
             )

    assert %{rows: [["/b", 1]]} =
             Alplus.Repo.query!(
               "SELECT value, visits FROM analytics_dimensions WHERE source_id = $1 AND dimension = 'landing_page'",
               [site_b.id]
             )

    {totals_a, "PostgreSQL rollups", false} =
      Alplus.Measure.Dashboard.totals(site_a, "30d", scope)

    {totals_b, "PostgreSQL rollups", false} =
      Alplus.Measure.Dashboard.totals(site_b, "30d", scope)

    assert totals_a.pageviews == 1
    assert totals_b.pageviews == 2
  end

  test "daily visitors survive visit expiry, state loss, and UTC rollover", %{
    project: project,
    source: source
  } do
    origin = "https://app.example.test"
    body = %{"site" => source.measure_token, "url" => "#{origin}/pricing", "type" => "pageview"}
    ip = {203, 0, 113, 10}
    user_agent = "Visitor lifecycle fixture"
    first = ~U[2031-04-17 00:00:00Z]

    salt_days = [
      DateTime.to_date(first),
      first |> DateTime.add(24 * 60 * 60, :second) |> DateTime.to_date()
    ]

    Enum.each(salt_days, &:ets.delete(Alplus.Measure.VisitorSalt, &1))
    on_exit(fn -> Enum.each(salt_days, &:ets.delete(Alplus.Measure.VisitorSalt, &1)) end)

    totals = fn ->
      %{rows: [[visitors, visits]]} =
        Alplus.Repo.query!(
          "SELECT COALESCE(sum(visitors), 0)::bigint, COALESCE(sum(visits), 0)::bigint FROM analytics_days WHERE project_id = $1 AND source_id = $2",
          [project.id, source.id]
        )

      {visitors, visits}
    end

    record = fn now ->
      assert :accepted =
               Alplus.Measure.Ingest.record(
                 source,
                 origin,
                 body,
                 ip,
                 user_agent,
                 nil,
                 now
               )

      totals.()
    end

    snapshots = [
      record.(first),
      record.(DateTime.add(first, 10 * 60, :second)),
      record.(DateTime.add(first, 41 * 60, :second))
    ]

    :sys.replace_state(Alplus.Measure.VisitorState, fn state ->
      :ets.delete_all_objects(state.table)
      state
    end)

    snapshots =
      snapshots ++
        [
          record.(DateTime.add(first, 42 * 60, :second)),
          record.(DateTime.add(first, 24 * 60 * 60, :second))
        ]

    {visitor_deltas, visit_deltas, _last} =
      Enum.reduce(snapshots, {[], [], {0, 0}}, fn {visitors, visits},
                                                  {visitor_deltas, visit_deltas,
                                                   {prior_visitors, prior_visits}} ->
        {
          visitor_deltas ++ [visitors - prior_visitors],
          visit_deltas ++ [visits - prior_visits],
          {visitors, visits}
        }
      end)

    assert visitor_deltas == [1, 0, 0, 0, 1]
    assert visit_deltas == [1, 0, 1, 1, 1]

    assert :accepted =
             Alplus.Measure.Ingest.record(
               source,
               origin,
               body,
               {203, 0, 113, 11},
               user_agent,
               nil,
               DateTime.add(first, 24 * 60 * 60 + 1, :second)
             )

    assert %{rows: [[2]]} =
             Alplus.Repo.query!(
               "SELECT visitors FROM analytics_days WHERE project_id = $1 AND source_id = $2 AND date = $3",
               [project.id, source.id, ~D[2031-04-18]]
             )

    assert %{rows: [[2]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM measure_visitor_seen WHERE day = $1",
               [~D[2031-04-18]]
             )
  end

  test "an unrevoked but unknown token is rejected wire-identically to a revoked one", %{
    project: project,
    scope: scope,
    source: source,
    token: token
  } do
    Ash.update!(source, %{}, action: :revoke, actor: scope)

    revoked =
      post_hit(
        build_conn(),
        token,
        "https://app.example.test/pricing",
        "https://app.example.test"
      )

    unknown =
      post_hit(
        build_conn(),
        "msr_00000000000000000000000000",
        "https://app.example.test/pricing",
        "https://app.example.test"
      )

    assert revoked.status == unknown.status
    assert revoked.resp_body == unknown.resp_body
    assert revoked.status == 204

    assert %{rows: [[0]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM analytics_hours WHERE project_id = $1",
               [project.id]
             )
  end

  test "attributes a hit to the token's Source project and environment", %{
    conn: conn,
    org: org,
    project: project,
    token: token
  } do
    assert post_hit(conn, token, "https://app.example.test/pricing", "https://app.example.test").status ==
             204

    assert %{rows: [[project_id, "staging"]]} =
             Alplus.Repo.query!(
               "SELECT project_id, environment FROM analytics_hours WHERE org_id = $1",
               [org.id]
             )

    assert project_id == project.id
  end

  test "malformed input returns 400 and never writes a rollup", %{conn: conn, project: project} do
    response =
      conn
      |> put_req_header("content-type", "text/plain")
      |> post("/m", "not-json")

    assert response.status == 400

    assert %{rows: [[0]]} =
             Alplus.Repo.query!("SELECT count(*) FROM analytics_hours WHERE project_id = $1", [
               project.id
             ])
  end

  test "a second pageview corrects a bounce without persisting request data", %{
    conn: conn,
    project: project,
    token: token
  } do
    url = "https://app.example.test/private-path?email=never-store"
    origin = "https://app.example.test"

    assert post_hit(conn, token, url, origin).status == 204
    assert post_hit(build_conn(), token, url, origin).status == 204

    assert %{rows: [[2, 1, 1, 0]]} =
             Alplus.Repo.query!(
               "SELECT pageviews, visitors, visits, bounces FROM analytics_hours WHERE project_id = $1",
               [project.id]
             )

    assert %{rows: [[columns]]} =
             Alplus.Repo.query!(
               "SELECT array_to_string(array_agg(column_name ORDER BY column_name), ',') FROM information_schema.columns WHERE table_name = 'analytics_hours'"
             )

    refute columns =~ "url"
    refute columns =~ "referrer"
    refute columns =~ "user_agent"
    refute columns =~ "visitor_hash"
    refute columns =~ "props"
  end

  test "records the first pageview as one durable landing-page visit", %{
    conn: conn,
    source: source,
    token: token
  } do
    assert post_hit(conn, token, "https://app.example.test/pricing", "https://app.example.test").status ==
             204

    assert post_hit(
             build_conn(),
             token,
             "https://app.example.test/docs",
             "https://app.example.test"
           ).status ==
             204

    assert %{rows: [["/pricing", 1, 1]]} =
             Alplus.Repo.query!(
               """
               SELECT value, visits, pageviews FROM analytics_dimensions
               WHERE source_id = $1 AND dimension = 'landing_page'
               """,
               [source.id]
             )

    assert %{rows: [["direct", 1, 2]]} =
             Alplus.Repo.query!(
               """
               SELECT value, visits, pageviews FROM analytics_dimensions
               WHERE source_id = $1 AND dimension = 'referrer'
               """,
               [source.id]
             )

    assert %{rows: [[columns]]} =
             Alplus.Repo.query!(
               "SELECT array_to_string(array_agg(column_name ORDER BY column_name), ',') FROM information_schema.columns WHERE table_name = 'analytics_dimensions'"
             )

    refute columns =~ "url"
    refute columns =~ "referrer"
    refute columns =~ "visitor_hash"
  end

  test "accepts a registered custom event, meters it, and discards properties", %{
    conn: conn,
    org: org,
    project: project,
    scope: scope,
    source: source,
    token: token
  } do
    Ash.create!(
      Alplus.Measure.CustomEventDefinition,
      %{org_id: org.id, project_id: project.id, name: "signup"},
      actor: scope
    )

    body = @measure_contract |> File.read!() |> Jason.decode!() |> Map.put("site", token)

    response =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "https://app.example.test")
      |> post("/m", Jason.encode!(body))

    assert response.status == 204

    assert %{rows: [[0, 1]]} =
             Alplus.Repo.query!(
               "SELECT (SELECT count(*) FROM analytics_hours), (SELECT count(*) FROM analytics_dimensions)"
             )

    assert %{rows: [["signup", 1, 0, 0]]} =
             Alplus.Repo.query!(
               "SELECT value, pageviews, visitors, visits FROM analytics_dimensions WHERE source_id = $1 AND dimension = 'event'",
               [source.id]
             )

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT analytics_events FROM usage_periods WHERE org_id = $1",
               [org.id]
             )

    assert %{rows: [[columns]]} =
             Alplus.Repo.query!(
               "SELECT array_to_string(array_agg(column_name ORDER BY column_name), ',') FROM information_schema.columns WHERE table_name = 'analytics_dimensions'"
             )

    refute columns =~ "props"
  end

  test "rejects unknown custom events before quota or rollup writes", %{
    conn: conn,
    org: org,
    token: token
  } do
    response =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "https://app.example.test")
      |> post(
        "/m",
        Jason.encode!(%{
          "site" => token,
          "url" => "https://app.example.test/pricing",
          "type" => "custom_event",
          "name" => "unknown"
        })
      )

    assert response.status == 400

    assert %{rows: [[0, 0]]} =
             Alplus.Repo.query!(
               "SELECT (SELECT count(*) FROM analytics_hours), (SELECT count(*) FROM analytics_dimensions)"
             )

    assert %{rows: []} =
             Alplus.Repo.query!(
               "SELECT analytics_events FROM usage_periods WHERE org_id = $1",
               [org.id]
             )
  end

  test "limits a public site to the plan's writes per minute", %{
    conn: conn,
    token: token,
    org: org
  } do
    subscribed_fixture(org)

    Enum.each(1..Alplus.Billing.Package.limit(:api_rate_limit_per_minute), fn _ ->
      assert post_hit(conn, token, "https://app.example.test/", "https://app.example.test").status ==
               204
    end)

    response = post_hit(conn, token, "https://app.example.test/", "https://app.example.test")
    assert response.status == 429
    assert [retry_after] = get_resp_header(response, "retry-after")
    assert String.to_integer(retry_after) > 0
  end

  test "an expired trial returns 402 without storing a Measure event", %{
    conn: conn,
    org: org,
    token: token
  } do
    Alplus.Repo.query!("UPDATE organizations SET trial_ends_at = $1 WHERE id = $2", [
      ~U[2000-01-01 00:00:00.000000Z],
      org.id
    ])

    response = post_hit(conn, token, "https://app.example.test/", "https://app.example.test")

    assert response.status == 402
    assert json_response(response, 402)["error"]["code"] == "plan_inactive"

    assert [[0]] =
             Alplus.Repo.query!("SELECT count(*) FROM analytics_hours WHERE org_id = $1", [org.id]).rows
  end

  test "does not record configured conversions in the Measure MVP", %{
    conn: conn,
    org: org,
    project: project,
    scope: scope,
    token: token
  } do
    {:ok, goal} =
      Ash.create(
        Goal,
        %{
          org_id: org.id,
          project_id: project.id,
          name: "Pricing",
          kind: "pageview",
          path: "/pricing"
        },
        actor: scope
      )

    assert post_hit(
             conn,
             token,
             "https://app.example.test/pricing",
             "https://app.example.test"
           ).status ==
             204

    assert post_hit(
             build_conn(),
             token,
             "https://app.example.test/pricing",
             "https://app.example.test"
           ).status ==
             204

    assert %{rows: []} =
             Alplus.Repo.query!("SELECT conversions FROM goal_conversions WHERE goal_id = $1", [
               goal.id
             ])
  end

  test "silently drops Measure writes after the 130 percent quota ceiling", %{
    conn: conn,
    org: org,
    project: project,
    token: token
  } do
    now = DateTime.utc_now()
    subscribed_fixture(org)
    limit = Package.limit(:analytics_events_per_month)
    ceiling = div(limit * 13, 10)

    Alplus.Repo.query!(
      """
      INSERT INTO usage_periods
        (id, org_id, period_start, analytics_events, dropped_analytics_events, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 0, now(), now())
      """,
      [
        Alplus.Id.generate(:usage_period),
        org.id,
        EventMeter.month_start(DateTime.to_date(now)),
        ceiling
      ]
    )

    response = post_hit(conn, token, "https://app.example.test/", "https://app.example.test")

    assert response.status == 204
    assert response.resp_body == ""

    assert %{rows: [[0]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM analytics_hours WHERE org_id = $1 AND project_id = $2",
               [org.id, project.id]
             )

    assert %{rows: [[^ceiling, 1]]} =
             Alplus.Repo.query!(
               """
               SELECT analytics_events, dropped_analytics_events
               FROM usage_periods WHERE org_id = $1 AND period_start = $2
               """,
               [org.id, EventMeter.month_start(DateTime.to_date(now))]
             )
  end

  describe "referrer, country, and browser dimensions" do
    test "a hit with Referer, cf-ipcountry, and User-Agent produces the right dimension rows", %{
      conn: conn,
      project: project,
      token: token
    } do
      response =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://app.example.test")
        |> put_req_header("referer", "https://google.com/search?q=al+plus")
        |> put_req_header("cf-ipcountry", "us")
        |> put_req_header(
          "user-agent",
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        )
        |> post(
          "/m",
          Jason.encode!(%{
            "site" => token,
            "url" => "https://app.example.test/pricing",
            "referrer" => "https://google.com/search?q=al+plus"
          })
        )

      assert response.status == 204

      assert %{rows: rows} =
               Alplus.Repo.query!(
                 "SELECT dimension, value FROM analytics_dimensions WHERE project_id = $1 AND dimension IN ('referrer', 'country', 'browser') ORDER BY dimension",
                 [project.id]
               )

      assert rows == [["browser", "Chrome"], ["country", "US"], ["referrer", "google.com"]]
    end

    test "a same-domain referrer records as direct", %{conn: conn, project: project, token: token} do
      response =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://app.example.test")
        |> post(
          "/m",
          Jason.encode!(%{
            "site" => token,
            "url" => "https://app.example.test/pricing",
            "referrer" => "https://app.example.test/blog"
          })
        )

      assert response.status == 204

      assert %{rows: [["direct"]]} =
               Alplus.Repo.query!(
                 "SELECT value FROM analytics_dimensions WHERE project_id = $1 AND dimension = 'referrer'",
                 [project.id]
               )
    end

    test "a referrer on another of the project's own allow-listed domains is direct, not just the origin domain",
         %{conn: conn, org: org, project: project, scope: scope, token: token} do
      Ash.create!(
        ProjectDomain,
        %{org_id: org.id, project_id: project.id, hostname: "blog.example.test"},
        action: :create,
        actor: scope
      )

      response =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://app.example.test")
        |> post(
          "/m",
          Jason.encode!(%{
            "site" => token,
            "url" => "https://app.example.test/pricing",
            "referrer" => "https://blog.example.test/post"
          })
        )

      assert response.status == 204

      assert %{rows: [["direct"]]} =
               Alplus.Repo.query!(
                 "SELECT value FROM analytics_dimensions WHERE project_id = $1 AND dimension = 'referrer'",
                 [project.id]
               )
    end

    test "a referrer host outside the project's allowlist records as its own host", %{
      conn: conn,
      project: project,
      token: token
    } do
      response =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://app.example.test")
        |> post(
          "/m",
          Jason.encode!(%{
            "site" => token,
            "url" => "https://app.example.test/pricing",
            "referrer" => "https://news.ycombinator.com/item?id=1"
          })
        )

      assert response.status == 204

      assert %{rows: [["news.ycombinator.com"]]} =
               Alplus.Repo.query!(
                 "SELECT value FROM analytics_dimensions WHERE project_id = $1 AND dimension = 'referrer'",
                 [project.id]
               )
    end

    test "a rejected hit (unknown token) is wire-identical whether or not it carries dimension headers",
         %{token: token} do
      accepted =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://app.example.test")
        |> put_req_header("cf-ipcountry", "us")
        |> post(
          "/m",
          Jason.encode!(%{"site" => token, "url" => "https://app.example.test/"})
        )

      rejected_unknown_token =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://app.example.test")
        |> put_req_header("cf-ipcountry", "us")
        |> post(
          "/m",
          Jason.encode!(%{
            "site" => "msr_00000000000000000000000000",
            "url" => "https://app.example.test/"
          })
        )

      assert accepted.status == rejected_unknown_token.status
      assert accepted.resp_body == rejected_unknown_token.resp_body
    end

    test "no raw referrer, IP, or user agent is ever persisted — only the derived dimensions",
         %{conn: conn, project: project, token: token} do
      response =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://app.example.test")
        |> put_req_header("referer", "https://google.com/search?q=secret-query")
        |> put_req_header("cf-ipcountry", "us")
        |> put_req_header("user-agent", "Mozilla/5.0 Secret-Device-Identifier/1.0")
        |> post(
          "/m",
          Jason.encode!(%{
            "site" => token,
            "url" => "https://app.example.test/pricing",
            "referrer" => "https://google.com/search?q=secret-query"
          })
        )

      assert response.status == 204

      assert %{rows: [[columns]]} =
               Alplus.Repo.query!(
                 "SELECT array_to_string(array_agg(column_name ORDER BY column_name), ',') FROM information_schema.columns WHERE table_name = 'analytics_dimensions'"
               )

      refute columns =~ "ip"
      refute columns =~ "user_agent"

      assert %{rows: values} =
               Alplus.Repo.query!(
                 "SELECT value FROM analytics_dimensions WHERE project_id = $1",
                 [project.id]
               )

      flat_values = Enum.map(values, &hd/1)
      refute Enum.any?(flat_values, &(&1 =~ "secret-query"))
      refute Enum.any?(flat_values, &(&1 =~ "Secret-Device-Identifier"))
      refute Enum.any?(flat_values, &(&1 =~ "search?q="))
    end

    test "the cardinality cap folds referrer, country, and browser into (other), same as path",
         %{project: project, source: source} do
      deltas = %{pageviews: 1, visitors: 1, visits: 1, bounces: 0, duration_seconds: 0}
      date = Date.utc_today()
      project_ref = %{id: project.id, org_id: project.org_id}

      for dimension <- ~w(referrer country browser) do
        Enum.each(1..1_001, fn number ->
          Alplus.Measure.Rollups.record_dimension!(
            project_ref,
            source.id,
            "staging",
            date,
            dimension,
            "value-#{number}",
            deltas
          )
        end)

        assert %{rows: [[1_000]]} =
                 Alplus.Repo.query!(
                   "SELECT count(*) FROM analytics_dimensions WHERE project_id = $1 AND dimension = $2 AND value != $3",
                   [project.id, dimension, Alplus.Measure.Rollups.other_value()]
                 )

        assert %{rows: [[1]]} =
                 Alplus.Repo.query!(
                   "SELECT pageviews FROM analytics_dimensions WHERE project_id = $1 AND dimension = $2 AND value = $3",
                   [project.id, dimension, Alplus.Measure.Rollups.other_value()]
                 )
      end
    end
  end

  test "POST /m does not write the peer IP to the application log", %{
    conn: conn,
    token: token
  } do
    log =
      capture_log(fn ->
        conn
        |> Map.put(:remote_ip, {203, 0, 113, 99})
        |> post_hit(token, "https://app.example.test/pricing", "https://app.example.test")
      end)

    refute log =~ "203.0.113.99"
    refute log =~ "203, 0, 113, 99"
  end

  defp post_hit(conn, site, url, origin) do
    conn = put_req_header(conn, "content-type", "application/json")
    conn = if origin, do: put_req_header(conn, "origin", origin), else: conn

    post(
      conn,
      "/m",
      Jason.encode!(%{"site" => site, "url" => url, "props" => %{"email" => "never-store"}})
    )
  end
end
