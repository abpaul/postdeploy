defmodule AlplusWeb.IngestPreambleTest do
  # Not async: stubs the invalid-key tarpit through application config.
  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Billing.Package
  alias Alplus.Observe.RateLimiter
  alias Alplus.Ingest.Admission
  alias Alplus.Projects.ProjectDomain
  alias Alplus.Scope

  # Every ingest path whose credential is an Authorization bearer.
  @bearer_paths ["/e/errors", "/e/sessions", "/e/artifacts"]

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    {source, secret} = source_fixture(owner_scope, org, project)
    {_measure_source, token} = source_fixture(owner_scope, org, project, %{type: :measure})

    Ash.create!(
      ProjectDomain,
      %{org_id: org.id, project_id: project.id, hostname: "app.example.test"},
      action: :create,
      actor: Scope.put_project(owner_scope, project.id)
    )

    :ets.delete_all_objects(Alplus.Observe.RateLimiter)
    :ets.delete_all_objects(Alplus.Measure.RateLimiter)

    previous_tarpit = Application.get_env(:alplus, :observe_invalid_key_tarpit)
    previous_tarpit_ms = Application.get_env(:alplus, :observe_invalid_key_tarpit_ms)
    Application.put_env(:alplus, :observe_invalid_key_tarpit, {__MODULE__, :tarpit})

    on_exit(fn ->
      if previous_tarpit do
        Application.put_env(:alplus, :observe_invalid_key_tarpit, previous_tarpit)
      else
        Application.delete_env(:alplus, :observe_invalid_key_tarpit)
      end

      if previous_tarpit_ms do
        Application.put_env(:alplus, :observe_invalid_key_tarpit_ms, previous_tarpit_ms)
      else
        Application.delete_env(:alplus, :observe_invalid_key_tarpit_ms)
      end
    end)

    %{
      org: org,
      owner_scope: owner_scope,
      project: project,
      source: source,
      secret: secret,
      token: token
    }
  end

  def tarpit(_milliseconds) do
    send(self(), :invalid_key_tarpit)
    :ok
  end

  test "an invalid bearer key tarpits before any database work on the error path", %{conn: conn} do
    response =
      conn
      |> put_req_header("authorization", "Bearer alp_not-a-real-key")
      |> put_req_header("content-type", "application/json")
      |> post("/e/errors", Jason.encode!(%{"items" => []}))

    assert response.status == 401
    assert json_response(response, 401)["error"]["code"] == "invalid_api_key"
    assert_receive :invalid_key_tarpit
  end

  test "missing and unknown bearer keys both wait for the 250 ms rejection floor" do
    Application.put_env(:alplus, :observe_invalid_key_tarpit, {Alplus.Observe.Tarpit, :sleep})
    Application.put_env(:alplus, :observe_invalid_key_tarpit_ms, 250)

    for {label, bearer} <- [{"missing", nil}, {"unknown", "alp_not-a-real-key"}],
        path <- @bearer_paths do
      started_at = System.monotonic_time(:microsecond)

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")

      conn =
        if bearer do
          put_req_header(conn, "authorization", "Bearer " <> bearer)
        else
          conn
        end

      response = post(conn, path, "{}")
      elapsed_us = System.monotonic_time(:microsecond) - started_at

      assert response.status == 401, "#{label} #{path} answered #{response.status}"
      assert json_response(response, 401)["error"]["code"] == "invalid_api_key"
      assert elapsed_us >= 250_000, "#{label} #{path} took #{elapsed_us} µs"
    end
  end

  test "a burst of 128 missing bearers cannot consume error admission", %{secret: secret} do
    statuses =
      1..128
      |> Task.async_stream(
        fn _attempt ->
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> post("/e/errors", "{}")
          |> Map.fetch!(:status)
        end,
        max_concurrency: 128,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, status} -> status end)

    assert statuses == List.duplicate(401, 128)
    assert Admission.snapshot()[{:errors, :global}] == 0

    body =
      Jason.encode!(%{
        "header" => %{
          "key" => secret,
          "sdk" => %{"name" => "sdk", "version" => "0.3.0"}
        },
        "items" => [
          %{
            "id" => "err_00000000-0000-7000-8000-000000000128",
            "type" => "message",
            "timestamp" => "2026-08-30T00:00:00Z",
            "level" => "info",
            "message" => "admission probe"
          }
        ]
      })

    response =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> secret)
      |> put_req_header("content-type", "application/json")
      |> post("/e/errors", body)

    assert response.status == 202
    assert Admission.snapshot()[{:errors, :global}] == 0
  end

  test "an oversized error envelope is capped before envelope parsing", %{
    conn: conn,
    secret: secret
  } do
    response =
      conn
      |> put_req_header("authorization", "Bearer " <> secret)
      |> put_req_header("content-type", "text/plain")
      |> post("/e/errors", String.duplicate("x", 1_048_577))

    assert response.status == 413
    assert json_response(response, 413)["error"]["code"] == "body_too_large"
  end

  test "an oversized session envelope hits the same cap", %{conn: conn, secret: secret} do
    response =
      conn
      |> put_req_header("authorization", "Bearer " <> secret)
      |> put_req_header("content-type", "text/plain")
      |> post("/e/sessions", String.duplicate("x", 1_048_577))

    assert response.status == 413
    assert json_response(response, 413)["error"]["code"] == "body_too_large"
  end

  test "an unknown measure site token tarpits and stays wire-identical to a rejected one", %{
    conn: conn
  } do
    # The global Measure lane has sixteen slots. An unauthenticated beacon used
    # to take one before its token resolved and hold it through the tarpit.
    admissions = capture_admissions(:measure)

    response =
      conn
      |> put_req_header("content-type", "text/plain")
      |> post(
        "/m",
        Jason.encode!(%{
          "site" => "msr_00000000000000000000000000",
          "url" => "https://app.example.test/"
        })
      )

    assert response.status == 204
    assert response.resp_body == ""
    assert_receive :invalid_key_tarpit
    assert [] = admissions.()
  end

  test "a known measure site token takes one global and one tenant lease", %{
    conn: conn,
    token: token
  } do
    admissions = capture_admissions(:measure)

    conn
    |> put_req_header("content-type", "text/plain")
    |> put_req_header("origin", "https://app.example.test")
    |> post("/m", Jason.encode!(%{site: token, url: "https://app.example.test/"}))

    assert [:global, :tenant] = admissions.()
  end

  # Returns a closure that lists the admission scopes accepted on `lane`
  # since the call, in order.
  defp capture_admissions(lane) do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:alplus, :ingest, :admission, :accepted],
      fn _event, _measurements, %{lane: ^lane, scope: scope}, _config ->
        send(parent, {ref, scope})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    fn -> collect(ref, []) end
  end

  defp collect(ref, acc) do
    receive do
      {^ref, scope} -> collect(ref, [scope | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a real browser beacon (text/plain body) authenticates and writes from the capped body", %{
    conn: conn,
    project: project,
    token: token
  } do
    response =
      conn
      |> put_req_header("content-type", "text/plain")
      |> put_req_header("origin", "https://app.example.test")
      |> post(
        "/m",
        Jason.encode!(%{site: token, url: "https://app.example.test/"})
      )

    assert response.status == 204

    # The preamble reads the body once. A second read would return no bytes,
    # the envelope would fail validation, and no row would land here.
    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM analytics_hours WHERE project_id = $1",
               [project.id]
             )
  end

  test "malformed JSON with no bearer answers 401 and tarpits before parsing" do
    for path <- @bearer_paths do
      response =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(path, "{\"items\": [")

      assert response.status == 401, "#{path} answered #{response.status}"
      assert json_response(response, 401)["error"]["code"] == "invalid_api_key"
      assert_receive :invalid_key_tarpit
    end
  end

  test "malformed JSON with an invalid bearer answers 401 and tarpits" do
    for path <- @bearer_paths do
      response =
        build_conn()
        |> put_req_header("authorization", "Bearer alp_not-a-real-key")
        |> put_req_header("content-type", "application/json")
        |> post(path, "{\"items\": [")

      assert response.status == 401, "#{path} answered #{response.status}"
      assert json_response(response, 401)["error"]["code"] == "invalid_api_key"
      assert_receive :invalid_key_tarpit
    end
  end

  test "a percent-encoded spelling of an ingest path cannot opt out of the preamble" do
    # `Phoenix.Router` routes on a percent-decoded copy of the path, so these
    # reach the same controllers. The parser must stay skipped for them too.
    for path <- ["/e/error%73", "/%65/errors", "/e/session%73", "/e/artifact%73"] do
      response =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(path, "{\"items\": [")

      assert response.status == 401, "#{path} answered #{response.status}"
      assert json_response(response, 401)["error"]["code"] == "invalid_api_key"
    end
  end

  test "a measure beacon that carries its payload in the query string still writes", %{
    project: project,
    token: token
  } do
    response =
      build_conn()
      |> put_req_header("content-type", "text/plain")
      |> put_req_header("origin", "https://app.example.test")
      |> post("/m?site=#{token}&url=https%3A%2F%2Fapp.example.test%2Fpricing", "")

    assert response.status == 204

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM analytics_hours WHERE project_id = $1",
               [project.id]
             )
  end

  test "a malformed measure body is rejected, never replaced by the query string", %{
    project: project,
    token: token
  } do
    # Authenticating from one payload and writing another let a body that
    # failed its own validation store whatever the query string said.
    response =
      build_conn()
      |> put_req_header("content-type", "text/plain")
      |> put_req_header("origin", "https://app.example.test")
      |> post("/m?site=#{token}&url=https%3A%2F%2Fapp.example.test%2Fpricing", "not json")

    assert response.status == 400
    assert json_response(response, 400)["error"]["code"] == "parameter_invalid"

    assert %{rows: [[0]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM analytics_hours WHERE project_id = $1",
               [project.id]
             )
  end

  test "an HTML Accept header cannot replace the published 401" do
    # `:accepts` raises 406. It must run after the credential, or a browser's
    # Accept header turns a missing bearer into the wrong answer.
    for path <- @bearer_paths do
      response =
        build_conn()
        |> put_req_header("accept", "text/html")
        |> put_req_header("content-type", "application/json")
        |> post(path, "{}")

      assert response.status == 401, "#{path} answered #{response.status}"
      assert json_response(response, 401)["error"]["code"] == "invalid_api_key"
    end
  end

  test "an HTML Accept header cannot let an unknown measure token skip its tarpit" do
    response =
      build_conn()
      |> put_req_header("accept", "text/html")
      |> put_req_header("content-type", "text/plain")
      |> post(
        "/m",
        Jason.encode!(%{
          "site" => "msr_00000000000000000000000000",
          "url" => "https://app.example.test/"
        })
      )

    assert response.status == 204
    assert_receive :invalid_key_tarpit
  end

  test "a rate-limited client is rejected before the server reads its body", %{
    conn: conn,
    org: org,
    source: source,
    secret: secret
  } do
    subscribed_fixture(org)

    for _attempt <- 1..Package.limit(:api_rate_limit_per_minute),
        do: :ok = RateLimiter.check(source.id)

    # This body is both malformed and over the 1 MiB cap. Reading it first
    # would answer 400 or 413; the limiter answers 429 because it runs first.
    response =
      conn
      |> put_req_header("authorization", "Bearer " <> secret)
      |> put_req_header("content-type", "application/json")
      |> post("/e/errors", "{" <> String.duplicate("x", 1_048_577))

    assert response.status == 429
    assert json_response(response, 429)["error"]["code"] == "rate_limit_exceeded"
    assert get_resp_header(response, "retry-after") != []
    refute Map.has_key?(response.assigns, :raw_body)
  end

  test "an artifact between 8 MiB and 20 MiB uploads under a JSON content type", %{
    secret: secret
  } do
    previous = Application.get_env(:alplus, :observe_payload_store_test_pid)
    Application.put_env(:alplus, :observe_payload_store_test_pid, self())

    on_exit(fn ->
      if previous do
        Application.put_env(:alplus, :observe_payload_store_test_pid, previous)
      else
        Application.delete_env(:alplus, :observe_payload_store_test_pid)
      end
    end)

    body = source_map_of_about(9 * 1024 * 1024)
    assert byte_size(body) in (8 * 1024 * 1024)..(20 * 1024 * 1024)

    response =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> secret)
      |> put_req_header("content-type", "application/json")
      |> post("/e/artifacts?release=9.9.9&name=big.js.map", body)

    assert response.status == 201
    assert json_response(response, 201)["name"] == "big.js.map"
  end

  defp source_map_of_about(bytes) do
    Jason.encode!(%{
      "version" => 3,
      "sources" => ["webpack://app/src/big.ts"],
      "mappings" => "AAAA",
      "sourcesContent" => [String.duplicate("a", bytes)]
    })
  end
end
