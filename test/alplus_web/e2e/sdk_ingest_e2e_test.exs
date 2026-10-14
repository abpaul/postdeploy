defmodule AlplusWeb.SdkIngestE2ETest do
  @moduledoc """
  End-to-end seam test (issue #19): the Elixir SDK builds a wire envelope
  through the published capture path (`test: true`, then `PostDeploy.Test.raw/2`)
  and that JSON is POSTed to the real `POST /e/errors` / `POST /e/sessions`
  routes. Asserts a real Issue + error_event row lands, dedup holds across
  two identical-stack posts, and a session envelope rolls up into
  `SessionRollup` / crash-free.
  """

  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Observe.{Issue, SessionHealth, SessionRollup}
  alias Alplus.Scope

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    # `environment` is derived from the CREDENTIAL at ingest, never from the
    # client-supplied item field (ARCHITECTURE.md, and both ingest
    # controllers' own doc comments) -- setting it here keeps the SDK
    # config's `environment: "test"` consistent with what actually lands on
    # the row, so the Ash reads below can filter by it.
    {source, secret} = source_fixture(owner_scope, org, project, %{environment: "test"})

    :ets.delete_all_objects(Alplus.Observe.RateLimiter)

    start_supervised!(
      {PostDeploy,
       key: secret,
       environment: "test",
       release: "1.0.0",
       test: true,
       integrations: [],
       flush_interval_ms: 0}
    )

    PostDeploy.Test.reset!()

    %{
      org: org,
      owner_scope: owner_scope,
      project: project,
      source: source,
      secret: secret,
      scope: Scope.put_project(owner_scope, project.id)
    }
  end

  defp raise_and_rescue do
    raise RuntimeError, "e2e contract boom"
  rescue
    exception -> {exception, __STACKTRACE__}
  end

  defp post_error_envelope(conn, secret, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{secret}")
    |> post("/e/errors", body)
  end

  defp post_session_envelope(conn, secret, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{secret}")
    |> post("/e/sessions", body)
  end

  defp sdk_error_body(opts \\ []) do
    name = Keyword.get(opts, :name, PostDeploy.Client)
    {exception, stacktrace} = raise_and_rescue()
    PostDeploy.Test.reset!(name)

    PostDeploy.capture_exception(exception,
      name: name,
      stacktrace: stacktrace,
      tags: %{"suite" => "e2e"},
      user: %{"id" => "user_e2e", "email" => "e2e@example.com"}
    )

    PostDeploy.flush(name: name, timeout: 1_000)
    [body] = PostDeploy.Test.raw(name, :errors)
    body
  end

  defp sdk_session_body(status) do
    PostDeploy.Test.reset!()
    PostDeploy.Session.clear()
    PostDeploy.Session.start()
    if status == :crashed, do: PostDeploy.mark_session_crashed()
    PostDeploy.close_session()
    PostDeploy.flush(timeout: 1_000)
    [body] = PostDeploy.Test.raw(:sessions)
    body
  end

  test "an SDK-built exception envelope writes a real Issue + error_event", %{
    conn: conn,
    secret: secret,
    project: project,
    scope: scope
  } do
    response = post_error_envelope(conn, secret, sdk_error_body())

    assert response.status == 202
    assert %{"accepted" => 1, "dropped" => 0} = json_response(response, 202)

    assert %{rows: [[1]]} =
             Alplus.Repo.query!("SELECT count(*) FROM error_events WHERE project_id = $1", [
               project.id
             ])

    issues =
      Issue
      |> Ash.Query.for_read(:list_for_project, %{project_id: project.id}, actor: scope)
      |> Ash.read!(actor: scope)

    assert [issue] = issues
    assert issue.event_count == 1
    assert issue.title =~ "e2e contract boom"
  end

  test "the same raised stack posted twice groups into one issue with two events", %{
    conn: conn,
    secret: secret,
    project: project,
    scope: scope
  } do
    assert post_error_envelope(conn, secret, sdk_error_body()).status == 202
    assert post_error_envelope(build_conn(), secret, sdk_error_body()).status == 202

    assert %{rows: [[1, 2]]} =
             Alplus.Repo.query!(
               "SELECT count(*), max(event_count) FROM issues WHERE project_id = $1",
               [project.id]
             )

    issues =
      Issue
      |> Ash.Query.for_read(:list_for_project, %{project_id: project.id}, actor: scope)
      |> Ash.read!(actor: scope)

    assert [issue] = issues
    assert issue.event_count == 2
  end

  test "a real ingest key rejects an envelope built for a different key", %{
    conn: conn,
    secret: secret
  } do
    {org, owner_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(owner_scope, org)
    {_source, other_secret} = source_fixture(owner_scope, org, other_project)

    mismatch = :"e2e_mismatch_#{System.unique_integer([:positive])}"

    start_supervised!(
      {PostDeploy,
       name: mismatch,
       key: other_secret,
       environment: "test",
       release: "1.0.0",
       test: true,
       integrations: [],
       flush_interval_ms: 0}
    )

    body = sdk_error_body(name: mismatch)
    response = post_error_envelope(conn, secret, body)
    assert response.status == 400
  end

  test "an SDK-built session envelope rolls up into SessionRollup", %{
    conn: conn,
    secret: secret,
    project: project,
    source: source,
    scope: scope
  } do
    assert post_session_envelope(conn, secret, sdk_session_body(:healthy)).status == 202
    assert post_session_envelope(build_conn(), secret, sdk_session_body(:crashed)).status == 202

    rollups =
      SessionRollup
      |> Ash.Query.for_read(
        :list_for_release,
        %{project_id: project.id, source_id: source.id, release: "1.0.0"},
        actor: scope
      )
      |> Ash.read!(actor: scope)

    total_sessions = Enum.sum_by(rollups, & &1.sessions_count)
    total_crashed = Enum.sum_by(rollups, & &1.crashed_count)

    assert total_sessions == 2
    assert total_crashed == 1
  end

  test "crash-free % is computed end-to-end from SDK-built session envelopes", %{
    conn: conn,
    secret: secret,
    source: source,
    scope: scope
  } do
    min_sessions = SessionHealth.min_sessions()

    healthy_conn =
      Enum.reduce(1..(min_sessions - 1), conn, fn _n, acc_conn ->
        assert post_session_envelope(acc_conn, secret, sdk_session_body(:healthy)).status == 202
        build_conn()
      end)

    assert post_session_envelope(healthy_conn, secret, sdk_session_body(:crashed)).status == 202

    assert {:ok, %{sessions: sessions, crashed: 1, crash_free_pct: pct}} =
             SessionHealth.crash_free(scope, "1.0.0", source.id)

    assert sessions == min_sessions
    assert_in_delta pct, (min_sessions - 1) / min_sessions * 100, 0.01
  end
end
