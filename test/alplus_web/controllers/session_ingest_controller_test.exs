defmodule AlplusWeb.SessionIngestControllerTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    {_source, secret} = source_fixture(owner_scope, org, project)

    :ets.delete_all_objects(Alplus.Observe.RateLimiter)

    previous_tarpit = Application.get_env(:alplus, :observe_invalid_key_tarpit)
    Application.put_env(:alplus, :observe_invalid_key_tarpit, {__MODULE__, :tarpit})

    on_exit(fn ->
      if previous_tarpit do
        Application.put_env(:alplus, :observe_invalid_key_tarpit, previous_tarpit)
      else
        Application.delete_env(:alplus, :observe_invalid_key_tarpit)
      end
    end)

    %{org: org, owner_scope: owner_scope, project: project, secret: secret}
  end

  def tarpit(_milliseconds) do
    send(self(), :invalid_key_tarpit)
    :ok
  end

  test "accepts the documented session wire shape and rolls it up", %{
    conn: conn,
    secret: secret,
    project: project
  } do
    response =
      post_envelope(
        conn,
        secret,
        envelope(secret, [session_item("ses_018f2b3c4d5e7f809012345678900a")])
      )

    assert response.status == 202

    assert json_response(response, 202) == %{
             "accepted" => 1,
             "dropped" => 0,
             "dropped_reason" => nil
           }

    assert %{rows: [["1.2.3", "production", 1, 0, 0]]} =
             Alplus.Repo.query!(
               "SELECT release, environment, sessions_count, errored_count, crashed_count FROM observe_session_rollups WHERE project_id = $1",
               [project.id]
             )
  end

  test "the dedup guard row carries no session outcome, only the claim (issue #12 decision #4)",
       %{conn: conn, secret: secret, project: project} do
    post_envelope(conn, secret, envelope(secret, [session_item("ses_no_raw_row")]))

    # The guard table only ever has `session_id`/`org_id`/`project_id`/
    # `received_at` columns (see the migration) -- there is no `status`,
    # `release`, or `duration_ms` column anywhere for it to leak into.
    # Aggregate-only persistence is a schema property, verified here by
    # confirming exactly one claim row exists per accepted session (the
    # dedup contract), not a raw per-session archive.
    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM observe_session_deduplications WHERE project_id = $1",
               [project.id]
             )
  end

  test "rejects missing or invalid bearer keys", %{
    conn: conn,
    secret: secret
  } do
    missing = post_envelope(conn, nil, envelope(secret, [session_item("ses_missing")]))
    assert missing.status == 401

    invalid =
      post_envelope(
        build_conn(),
        "alp_not-a-real-key",
        envelope(secret, [session_item("ses_invalid")])
      )

    assert invalid.status == 401
    assert_receive :invalid_key_tarpit
  end

  test "rejects a revoked source's secret", %{
    conn: conn,
    org: org,
    owner_scope: owner_scope,
    project: project
  } do
    {source, revoked_secret} =
      source_fixture(owner_scope, org, project, %{environment: "staging"})

    Ash.update!(source, %{},
      action: :revoke,
      actor: Alplus.Scope.put_project(owner_scope, project.id)
    )

    response =
      post_envelope(
        conn,
        revoked_secret,
        envelope(revoked_secret, [session_item("ses_revoked")])
      )

    assert response.status == 401
    assert_receive :invalid_key_tarpit
  end

  test "rejects a mismatched redundant header key", %{conn: conn, secret: secret} do
    response =
      post_envelope(conn, secret, envelope("alp_different", [session_item("ses_mismatch")]))

    assert response.status == 400
    assert json_response(response, 400)["error"]["code"] == "parameter_invalid"
  end

  test "rejects oversized and malformed envelopes", %{conn: conn, secret: secret} do
    oversized =
      ~s({"header":{"sdk":{"name":"sdk","version":"0.1.0"}},"items":[]}) <>
        String.duplicate(" ", 1_048_576)

    assert post_raw(conn, secret, oversized).status == 413

    malformed = post_raw(build_conn(), secret, "not json", "text/plain")
    assert malformed.status == 400
  end

  test "drops a malformed item while accepting a valid sibling", %{conn: conn, secret: secret} do
    invalid = %{"id" => "ses_bad", "status" => "not_a_real_status"}

    response =
      post_envelope(conn, secret, envelope(secret, [session_item("ses_good"), invalid]))

    assert json_response(response, 202) == %{
             "accepted" => 1,
             "dropped" => 1,
             "dropped_reason" => "malformed"
           }
  end

  test "a retried session id is idempotent: counted once, second reply is a no-op 202", %{
    conn: conn,
    secret: secret,
    project: project
  } do
    body = envelope(secret, [session_item("ses_retry_me")])

    assert post_envelope(conn, secret, body).status == 202
    duplicate = post_envelope(build_conn(), secret, body)

    assert json_response(duplicate, 202) == %{
             "accepted" => 0,
             "dropped" => 1,
             "dropped_reason" => "duplicate"
           }

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT sessions_count FROM observe_session_rollups WHERE project_id = $1",
               [project.id]
             )
  end

  test "an errored session increments errored_count, a crashed session increments crashed_count",
       %{conn: conn, secret: secret, project: project} do
    post_envelope(
      conn,
      secret,
      envelope(secret, [session_item("ses_errored_one", status: "errored")])
    )

    post_envelope(
      build_conn(),
      secret,
      envelope(secret, [session_item("ses_crashed_one", status: "crashed")])
    )

    assert %{rows: [[2, 1, 1]]} =
             Alplus.Repo.query!(
               "SELECT sessions_count, errored_count, crashed_count FROM observe_session_rollups WHERE project_id = $1",
               [project.id]
             )
  end

  test "environment is derived from the credential, never the client-supplied item field", %{
    conn: conn,
    secret: secret,
    project: project
  } do
    item = session_item("ses_env_spoof") |> Map.put("environment", "staging")
    post_envelope(conn, secret, envelope(secret, [item]))

    assert %{rows: [["production"]]} =
             Alplus.Repo.query!(
               "SELECT environment FROM observe_session_rollups WHERE project_id = $1",
               [project.id]
             )
  end

  test "limits each API key and returns retry-after", %{conn: conn, secret: secret, org: org} do
    subscribed_fixture(org)

    Enum.each(1..Alplus.Billing.Package.limit(:api_rate_limit_per_minute), fn number ->
      response = post_envelope(conn, secret, envelope(secret, [session_item("ses_#{number}")]))
      assert response.status == 202
    end)

    response =
      post_envelope(build_conn(), secret, envelope(secret, [session_item("ses_limited")]))

    assert response.status == 429
    assert [retry_after] = get_resp_header(response, "retry-after")
    assert String.to_integer(retry_after) > 0
  end

  test "does not share a rate-limit budget with POST /e/errors on the same key", %{
    conn: conn,
    secret: secret
  } do
    Enum.each(1..Alplus.Billing.Package.limit(:api_rate_limit_per_minute), fn number ->
      response =
        conn
        |> put_req_header("authorization", "Bearer #{secret}")
        |> put_req_header("content-type", "application/json")
        |> post("/e/errors", Jason.encode!(error_envelope(secret, "err_rl_#{number}")))

      assert response.status == 202
    end)

    response =
      post_envelope(build_conn(), secret, envelope(secret, [session_item("ses_after_error_rl")]))

    assert response.status == 202
  end

  defp post_envelope(conn, secret, envelope) do
    post_raw(conn, secret, Jason.encode!(envelope))
  end

  defp post_raw(conn, secret, body, content_type \\ "application/json") do
    conn = put_req_header(conn, "content-type", content_type)
    conn = if secret, do: put_req_header(conn, "authorization", "Bearer #{secret}"), else: conn
    post(conn, "/e/sessions", body)
  end

  defp envelope(key, items) do
    %{
      "header" => %{
        "key" => key,
        "sdk" => %{"name" => "alplus-elixir", "version" => "0.1.0", "platform" => "elixir"}
      },
      "items" => items
    }
  end

  defp error_envelope(key, event_id) do
    %{
      "header" => %{
        "key" => key,
        "sdk" => %{"name" => "alplus-elixir", "version" => "0.1.0", "platform" => "elixir"}
      },
      "items" => [
        %{
          "id" => event_id,
          "type" => "message",
          "timestamp" => "2026-08-12T12:00:00Z",
          "level" => "info",
          "message" => "rate limit filler"
        }
      ]
    }
  end

  defp session_item(id, opts \\ []) do
    %{
      "id" => id,
      "status" => Keyword.get(opts, :status, "healthy"),
      "release" => Keyword.get(opts, :release, "1.2.3")
    }
  end
end
