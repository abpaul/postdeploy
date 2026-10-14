defmodule AlplusWeb.ProductEventIngestControllerTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Repo

  setup do
    scope = scope_fixture()
    {org, owner_scope} = org_fixture(scope)
    subscribed_fixture(org)
    project = project_fixture(owner_scope, org)
    {source, secret} = source_fixture(owner_scope, org, project, %{type: :analytics})

    %{org: org, scope: owner_scope, project: project, source: source, secret: secret}
  end

  defp post_event(conn, secret, body) do
    conn
    |> put_req_header("authorization", "Bearer #{secret}")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/events", body)
  end

  defp post_batch(conn, secret, body) do
    conn
    |> put_req_header("authorization", "Bearer #{secret}")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/events/batch", body)
  end

  defp stored_events(project_id) do
    Repo.query!(
      """
      SELECT event_name, distinct_id, environment, properties, client_event_id
      FROM product_events WHERE project_id = $1 ORDER BY event_name
      """,
      [project_id]
    ).rows
  end

  describe "POST /v1/events" do
    test "accepts one event and stores it against the key's project", %{
      conn: conn,
      secret: secret,
      project: project,
      source: source
    } do
      conn =
        post_event(
          conn,
          secret,
          ~s({"event":"onboarding_completed","distinct_id":"anon_123","properties":{"variant":"short","step":3}})
        )

      assert %{"success" => true, "accepted" => 1} = json_response(conn, 202)

      assert [["onboarding_completed", "anon_123", environment, properties, nil]] =
               stored_events(project.id)

      assert environment == source.environment
      assert properties == %{"variant" => "short", "step" => 3}
    end

    test "records the event even with no distinct_id, under one shared identifier", %{
      conn: conn,
      secret: secret,
      project: project
    } do
      conn = post_event(conn, secret, ~s({"event":"first_open"}))

      assert %{"accepted" => 1} = json_response(conn, 202)
      assert [["first_open", distinct_id, _env, _props, nil]] = stored_events(project.id)
      assert distinct_id == Alplus.Analytics.Event.anonymous_distinct_id()
    end

    test "refuses a missing event name", %{conn: conn, secret: secret, project: project} do
      conn = post_event(conn, secret, ~s({"distinct_id":"anon_1"}))

      assert %{"error" => %{"code" => "invalid_event", "message" => message}} =
               json_response(conn, 400)

      assert message =~ "non-empty string"
      assert stored_events(project.id) == []
    end

    test "refuses malformed JSON", %{conn: conn, secret: secret} do
      conn = post_event(conn, secret, ~s({"event":))

      assert %{"error" => %{"code" => "invalid_payload"}} = json_response(conn, 400)
    end

    test "refuses an unknown key without touching the project", %{
      conn: conn,
      project: project
    } do
      conn = post_event(conn, "pda_not_a_real_key_at_all", ~s({"event":"first_open"}))

      assert %{"error" => %{"code" => "invalid_api_key"}} = json_response(conn, 401)
      assert stored_events(project.id) == []
    end

    test "refuses a missing key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/v1/events", ~s({"event":"first_open"}))

      assert %{"error" => %{"code" => "invalid_api_key"}} = json_response(conn, 401)
    end

    test "refuses an Observe ingest key on the analytics path", %{
      conn: conn,
      scope: scope,
      org: org,
      project: project
    } do
      {_observe_source, observe_secret} =
        source_fixture(scope, org, project, %{type: :observe, environment: "staging"})

      conn = post_event(conn, observe_secret, ~s({"event":"first_open"}))

      assert %{"error" => %{"code" => "invalid_api_key"}} = json_response(conn, 401)
      assert stored_events(project.id) == []
    end

    test "refuses a body over the request cap", %{conn: conn, secret: secret} do
      oversized =
        ~s({"event":"first_open","properties":{"blob":") <>
          String.duplicate("x", 300_000) <> ~s("}})

      conn = post_event(conn, secret, oversized)

      assert %{"error" => %{"code" => "body_too_large"}} = json_response(conn, 413)
    end

    test "refuses a property value over the string cap", %{conn: conn, secret: secret} do
      body =
        Jason.encode!(%{
          "event" => "first_open",
          "properties" => %{"note" => String.duplicate("x", 513)}
        })

      conn = post_event(conn, secret, body)

      assert %{"error" => %{"code" => "invalid_properties"}} = json_response(conn, 400)
    end

    test "refuses more properties than the cap", %{conn: conn, secret: secret} do
      properties = Map.new(1..41, fn index -> {"key_#{index}", index} end)
      body = Jason.encode!(%{"event" => "first_open", "properties" => properties})

      conn = post_event(conn, secret, body)

      assert %{"error" => %{"code" => "invalid_properties"}} = json_response(conn, 400)
    end

    test "refuses a nested property value", %{conn: conn, secret: secret} do
      body =
        Jason.encode!(%{"event" => "first_open", "properties" => %{"user" => %{"plan" => "pro"}}})

      conn = post_event(conn, secret, body)

      assert %{"error" => %{"code" => "invalid_properties"}} = json_response(conn, 400)
    end

    test "refuses a timestamp outside the accepted window", %{conn: conn, secret: secret} do
      body =
        Jason.encode!(%{
          "event" => "first_open",
          "timestamp" => DateTime.utc_now() |> DateTime.add(-120, :day) |> DateTime.to_iso8601()
        })

      conn = post_event(conn, secret, body)

      assert %{"error" => %{"code" => "invalid_timestamp"}} = json_response(conn, 400)
    end

    test "stores a supplied timestamp rather than the arrival time", %{
      conn: conn,
      secret: secret,
      project: project
    } do
      occurred = DateTime.utc_now() |> DateTime.add(-3, :day) |> DateTime.truncate(:second)

      body =
        Jason.encode!(%{
          "event" => "meal_logged",
          "distinct_id" => "anon_1",
          "timestamp" => DateTime.to_iso8601(occurred)
        })

      post_event(conn, secret, body)

      %{rows: [[stored]]} =
        Repo.query!("SELECT occurred_at FROM product_events WHERE project_id = $1", [project.id])

      assert DateTime.compare(DateTime.from_naive!(stored, "Etc/UTC"), occurred) == :eq
    end

    test "writes a repeated client event id once", %{
      conn: conn,
      secret: secret,
      project: project
    } do
      body = ~s({"id":"evt_0192abcd","event":"trial_started","distinct_id":"anon_9"})

      assert %{"accepted" => 1} = conn |> post_event(secret, body) |> json_response(202)

      assert %{"accepted" => 1} =
               build_conn() |> post_event(secret, body) |> json_response(202)

      assert [["trial_started", "anon_9", _env, _props, "evt_0192abcd"]] =
               stored_events(project.id)
    end
  end

  describe "POST /v1/events/batch" do
    test "accepts a batch and stores every event", %{
      conn: conn,
      secret: secret,
      project: project
    } do
      body =
        Jason.encode!(%{
          "events" => [
            %{"event" => "onboarding_started", "distinct_id" => "anon_123"},
            %{
              "event" => "onboarding_completed",
              "distinct_id" => "anon_123",
              "properties" => %{"variant" => "short"}
            }
          ]
        })

      conn = post_batch(conn, secret, body)

      assert %{"success" => true, "accepted" => 2} = json_response(conn, 202)
      assert length(stored_events(project.id)) == 2
    end

    test "refuses a batch over the event limit", %{conn: conn, secret: secret, project: project} do
      events = for index <- 1..101, do: %{"event" => "step_#{index}"}
      conn = post_batch(conn, secret, Jason.encode!(%{"events" => events}))

      assert %{"error" => %{"code" => "batch_too_large"}} = json_response(conn, 400)
      assert stored_events(project.id) == []
    end

    test "refuses an empty batch", %{conn: conn, secret: secret} do
      conn = post_batch(conn, secret, ~s({"events":[]}))

      assert %{"error" => %{"code" => "invalid_payload"}} = json_response(conn, 400)
    end

    test "writes nothing when one event in the batch is invalid", %{
      conn: conn,
      secret: secret,
      project: project
    } do
      body =
        Jason.encode!(%{
          "events" => [
            %{"event" => "onboarding_started", "distinct_id" => "anon_1"},
            %{"event" => "", "distinct_id" => "anon_1"}
          ]
        })

      conn = post_batch(conn, secret, body)

      assert %{"error" => %{"code" => "invalid_event"}} = json_response(conn, 400)
      assert stored_events(project.id) == []
    end
  end

  describe "limits" do
    test "answers 429 with Retry-After once the request budget is spent", %{
      conn: conn,
      secret: secret,
      source: source
    } do
      limit = min(Alplus.Billing.Package.limit(:api_rate_limit_per_minute), 600)

      for _index <- 1..limit do
        Alplus.Analytics.RateLimiter.check(source.id)
      end

      conn = post_event(conn, secret, ~s({"event":"first_open"}))

      assert %{"error" => %{"code" => "rate_limit_exceeded"}} = json_response(conn, 429)
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) >= 1
    end

    test "counts accepted events against the monthly quota", %{
      conn: conn,
      secret: secret,
      org: org
    } do
      body =
        Jason.encode!(%{
          "events" => [
            %{"event" => "first_open", "distinct_id" => "a"},
            %{"event" => "meal_logged", "distinct_id" => "a"}
          ]
        })

      post_batch(conn, secret, body)

      usage = Alplus.Billing.EventMeter.current(org.id, DateTime.utc_now())
      assert usage.product_events == 2
    end

    test "drops the events past the grace ceiling and reports how many", %{
      conn: conn,
      secret: secret,
      org: org,
      project: project
    } do
      ceiling =
        Alplus.Billing.Package.event_ceiling(
          Alplus.Billing.Package.limit(:product_events_per_month)
        )

      Repo.query!(
        """
        INSERT INTO usage_periods (id, org_id, period_start, product_events, inserted_at, updated_at)
        VALUES ($1, $2, date_trunc('month', now())::date, $3, now(), now())
        ON CONFLICT (org_id, period_start)
        DO UPDATE SET product_events = EXCLUDED.product_events
        """,
        [Alplus.Id.generate(:usage_period), org.id, ceiling]
      )

      conn = post_event(conn, secret, ~s({"event":"first_open","distinct_id":"a"}))

      assert %{"accepted" => 0, "dropped" => 1, "dropped_reason" => "quota"} =
               json_response(conn, 202)

      assert stored_events(project.id) == []
    end

    test "refuses ingest with 402 once the organization loses access", %{conn: conn} do
      scope = scope_fixture()
      {org, owner_scope} = org_fixture(scope)
      project = project_fixture(owner_scope, org)
      {_source, secret} = source_fixture(owner_scope, org, project, %{type: :analytics})

      # The key was issued while the trial ran. Ingest must refuse it the
      # moment the organization loses access, not at the next key rotation.
      Repo.query!("UPDATE organizations SET trial_ends_at = $1 WHERE id = $2", [
        ~U[2000-01-01 00:00:00.000000Z],
        org.id
      ])

      conn = post_event(conn, secret, ~s({"event":"first_open"}))

      assert %{"error" => %{"code" => "plan_inactive"}} = json_response(conn, 402)
      assert stored_events(project.id) == []
    end
  end

  describe "cross-origin access" do
    test "answers a browser preflight without a credential", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://app.example.com")
        |> put_req_header("access-control-request-method", "POST")
        |> options("/v1/events")

      assert response(conn, 204)
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]

      assert get_resp_header(conn, "access-control-allow-headers") == [
               "authorization, content-type"
             ]
    end
  end

  describe "tenant isolation" do
    test "a key from one project never writes into another", %{
      conn: conn,
      scope: scope,
      org: org,
      secret: secret,
      project: project
    } do
      other_project = project_fixture(scope, org, %{name: "Other"})

      post_event(conn, secret, ~s({"event":"first_open","distinct_id":"anon_1"}))

      assert length(stored_events(project.id)) == 1
      assert stored_events(other_project.id) == []
    end
  end
end
