defmodule AlplusWeb.ErrorIngestControllerTest do
  use AlplusWeb.ConnCase, async: false
  use Oban.Testing, repo: Alplus.Repo

  import Alplus.OrgsFixtures

  alias Alplus.Notifications.{AlertRule, DeliveryWorker}
  alias Alplus.Scope

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

  test "accepts the unmodified SDK envelope shape", %{conn: conn, secret: secret} do
    event_id = "err_0198f0a1-7c01-7000-8000-000000000001"
    response = post_envelope(conn, secret, envelope(secret, [exception_item(event_id)]))

    assert response.status == 202

    assert json_response(response, 202) == %{
             "accepted" => 1,
             "dropped" => 0,
             "event_ids" => [event_id],
             "dropped_reason" => nil
           }
  end

  test "rejects missing or invalid bearer keys", %{
    conn: conn,
    secret: secret
  } do
    missing =
      post_envelope(
        conn,
        nil,
        envelope(secret, [exception_item("err_0198f0a1-7c01-7000-8000-000000000002")])
      )

    assert missing.status == 401

    invalid =
      post_envelope(
        build_conn(),
        "alp_not-a-real-key",
        envelope(secret, [exception_item("err_0198f0a1-7c01-7000-8000-000000000003")])
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

    Ash.update!(source, %{}, action: :revoke, actor: Scope.put_project(owner_scope, project.id))

    response =
      post_envelope(
        conn,
        revoked_secret,
        envelope(revoked_secret, [exception_item("err_0198f0a1-7c01-7000-8000-000000000004")])
      )

    assert response.status == 401
    assert_receive :invalid_key_tarpit
  end

  test "rejects a mismatched redundant header key", %{conn: conn, secret: secret} do
    response =
      post_envelope(
        conn,
        secret,
        envelope("alp_different", [exception_item("err_0198f0a1-7c01-7000-8000-000000000005")])
      )

    assert response.status == 400
    assert json_response(response, 400)["error"]["code"] == "parameter_invalid"
  end

  test "rejects oversized and malformed envelopes", %{conn: conn, secret: secret} do
    oversized =
      ~s({"header":{"sdk":{"name":"sdk","version":"0.3.0"}},"items":[]}) <>
        String.duplicate(" ", 1_048_576)

    assert post_raw(conn, secret, oversized).status == 413

    malformed = post_raw(build_conn(), secret, "not json", "text/plain")
    assert malformed.status == 400
  end

  test "drops malformed items while accepting valid siblings", %{conn: conn, secret: secret} do
    event_id = "err_0198f0a1-7c01-7000-8000-000000000006"

    invalid = %{
      "id" => "err_0198f0a1-7c01-7000-8000-000000000007",
      "type" => "message",
      "timestamp" => "2026-08-11T12:00:00Z",
      "level" => "info"
    }

    response = post_envelope(conn, secret, envelope(secret, [exception_item(event_id), invalid]))

    assert json_response(response, 202) == %{
             "accepted" => 1,
             "dropped" => 1,
             "dropped_reason" => "malformed",
             "event_ids" => [event_id]
           }
  end

  test "limits each API key and returns retry-after", %{conn: conn, secret: secret, org: org} do
    subscribed_fixture(org)

    Enum.each(1..Alplus.Billing.Package.limit(:api_rate_limit_per_minute), fn number ->
      event_id =
        "err_0198f0a1-7c01-7000-8000-#{String.pad_leading(Integer.to_string(number), 12, "0")}"

      response = post_envelope(conn, secret, envelope(secret, [exception_item(event_id)]))
      assert response.status == 202
    end)

    response =
      post_envelope(
        build_conn(),
        secret,
        envelope(secret, [exception_item("err_0198f0a1-7c01-7000-8000-000000000008")])
      )

    assert response.status == 429
    assert [retry_after] = get_resp_header(response, "retry-after")
    assert String.to_integer(retry_after) > 0
  end

  test "an expired trial returns 402 without storing an Observe event", %{
    conn: conn,
    org: org,
    secret: secret
  } do
    Alplus.Repo.query!("UPDATE organizations SET trial_ends_at = $1 WHERE id = $2", [
      ~U[2000-01-01 00:00:00.000000Z],
      org.id
    ])

    response =
      post_envelope(
        conn,
        secret,
        envelope(secret, [exception_item("err_0198f0a1-7c01-7000-8000-000000000009")])
      )

    assert response.status == 402
    assert json_response(response, 402)["error"]["code"] == "plan_inactive"

    assert [[0]] =
             Alplus.Repo.query!("SELECT count(*) FROM error_events WHERE org_id = $1", [org.id]).rows
  end

  test "groups the same stack into one issue while storing both unique events", %{
    conn: conn,
    secret: secret,
    project: project
  } do
    first_id = "err_0198f0a1-7c01-7000-8000-000000000010"
    second_id = "err_0198f0a1-7c01-7000-8000-000000000011"

    assert post_envelope(conn, secret, envelope(secret, [exception_item(first_id)])).status == 202

    assert post_envelope(build_conn(), secret, envelope(secret, [exception_item(second_id)])).status ==
             202

    assert %{rows: [[1, 2]]} =
             Alplus.Repo.query!(
               "SELECT count(*), max(event_count) FROM issues WHERE project_id = $1",
               [project.id]
             )

    assert %{rows: [[2]]} =
             Alplus.Repo.query!("SELECT count(*) FROM error_events WHERE project_id = $1", [
               project.id
             ])
  end

  test "does not create another event for a duplicate client id", %{
    conn: conn,
    secret: secret,
    project: project
  } do
    event_id = "err_0198f0a1-7c01-7000-8000-000000000012"
    body = envelope(secret, [exception_item(event_id)])

    assert post_envelope(conn, secret, body).status == 202
    duplicate = post_envelope(build_conn(), secret, body)

    assert json_response(duplicate, 202) == %{
             "accepted" => 0,
             "dropped" => 1,
             "dropped_reason" => "duplicate",
             "event_ids" => []
           }

    assert %{rows: [[1]]} =
             Alplus.Repo.query!("SELECT count(*) FROM error_events WHERE project_id = $1", [
               project.id
             ])
  end

  test "a second org posting the same client event id is accepted, not deduplicated away", %{
    conn: conn,
    secret: secret,
    project: project
  } do
    event_id = "err_0198f0a1-7c01-7000-8000-000000000013"
    body = envelope(secret, [exception_item(event_id)])

    assert post_envelope(conn, secret, body).status == 202

    {other_org, other_owner_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_owner_scope, other_org)
    {_other_source, other_secret} = source_fixture(other_owner_scope, other_org, other_project)

    other_response =
      post_envelope(
        build_conn(),
        other_secret,
        envelope(other_secret, [exception_item(event_id)])
      )

    assert json_response(other_response, 202) == %{
             "accepted" => 1,
             "dropped" => 0,
             "dropped_reason" => nil,
             "event_ids" => [event_id]
           }

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM error_events WHERE event_id = $1 AND project_id = $2",
               [event_id, project.id]
             )

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM error_events WHERE event_id = $1 AND project_id = $2",
               [event_id, other_project.id]
             )
  end

  test "two different sources in DIFFERENT projects posting the same client event id are both accepted",
       %{
         conn: conn,
         secret: secret,
         owner_scope: owner_scope,
         org: org,
         project: project
       } do
    event_id = "err_0198f0a1-7c01-7000-8000-000000000014"
    body = envelope(secret, [exception_item(event_id)])

    assert post_envelope(conn, secret, body).status == 202

    subscribed_fixture(org)
    other_project = project_fixture(owner_scope, org)

    {_staging_source, staging_secret} =
      source_fixture(owner_scope, org, other_project, %{environment: "staging"})

    staging_response =
      post_envelope(
        build_conn(),
        staging_secret,
        envelope(staging_secret, [exception_item(event_id)])
      )

    assert json_response(staging_response, 202) == %{
             "accepted" => 1,
             "dropped" => 0,
             "dropped_reason" => nil,
             "event_ids" => [event_id]
           }

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM error_events WHERE event_id = $1 AND project_id = $2",
               [event_id, project.id]
             )

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM error_events WHERE event_id = $1 AND project_id = $2",
               [event_id, other_project.id]
             )

    # A repeat from the SAME (staging) source still dedups.
    duplicate =
      post_envelope(
        build_conn(),
        staging_secret,
        envelope(staging_secret, [exception_item(event_id)])
      )

    assert json_response(duplicate, 202) == %{
             "accepted" => 0,
             "dropped" => 1,
             "dropped_reason" => "duplicate",
             "event_ids" => []
           }
  end

  test "two different sources in the SAME project reusing an event id are both accepted, with distinct issues",
       %{
         conn: conn,
         secret: secret,
         owner_scope: owner_scope,
         org: org,
         project: project
       } do
    event_id = "err_0198f0a1-7c01-7000-8000-000000000015"
    body = envelope(secret, [exception_item(event_id)])

    assert post_envelope(conn, secret, body).status == 202

    {staging_source, staging_secret} =
      source_fixture(owner_scope, org, project, %{environment: "staging"})

    staging_response =
      post_envelope(
        build_conn(),
        staging_secret,
        envelope(staging_secret, [exception_item(event_id)])
      )

    assert json_response(staging_response, 202) == %{
             "accepted" => 1,
             "dropped" => 0,
             "dropped_reason" => nil,
             "event_ids" => [event_id]
           }

    assert %{rows: [[2]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM error_events WHERE event_id = $1 AND project_id = $2",
               [event_id, project.id]
             )

    assert %{rows: [[2]]} =
             Alplus.Repo.query!(
               "SELECT count(DISTINCT issue_id) FROM error_events WHERE event_id = $1 AND project_id = $2",
               [event_id, project.id]
             )

    assert %{rows: [[staging_issue_source_id]]} =
             Alplus.Repo.query!(
               "SELECT source_id FROM issues WHERE project_id = $1 AND environment = 'staging'",
               [project.id]
             )

    assert staging_issue_source_id == staging_source.id

    # A repeat from the SAME (staging) source still dedups.
    duplicate =
      post_envelope(
        build_conn(),
        staging_secret,
        envelope(staging_secret, [exception_item(event_id)])
      )

    assert json_response(duplicate, 202) == %{
             "accepted" => 0,
             "dropped" => 1,
             "dropped_reason" => "duplicate",
             "event_ids" => []
           }
  end

  test "persists an oversized item in an outbox before storing its bounded event projection", %{
    conn: conn,
    secret: secret,
    project: project
  } do
    previous_pid = Application.get_env(:alplus, :observe_payload_store_test_pid)
    Application.put_env(:alplus, :observe_payload_store_test_pid, self())

    on_exit(fn ->
      if previous_pid do
        Application.put_env(:alplus, :observe_payload_store_test_pid, previous_pid)
      else
        Application.delete_env(:alplus, :observe_payload_store_test_pid)
      end
    end)

    event_id = "err_0198f0a1-7c01-7000-8000-000000000016"

    item =
      exception_item(event_id)
      |> put_in(["exception", "stacktrace", "frames"], Enum.map(1..4, &frame/1))
      |> Map.put("contexts", %{"request" => %{"body" => String.duplicate("x", 256 * 1024)}})
      |> Map.put("tags", %{"build" => "main"})
      |> Map.put("breadcrumbs", [%{"category" => "navigation", "message" => "checkout"}])

    assert post_envelope(conn, secret, envelope(secret, [item])).status == 202

    key = "events/#{project.id}/#{event_id}.json"

    assert %{rows: [[outbox_id, ^key, payload]]} =
             Alplus.Repo.query!(
               "SELECT id, payload_s3_key, payload FROM observe_error_payload_outboxes WHERE event_id = $1",
               [event_id]
             )

    assert Jason.decode!(payload) == item
    assert :ok = perform_job(Alplus.Observe.PayloadStorageWorker, %{"outbox_id" => outbox_id})
    assert_receive {:observe_payload_stored, ^key, ^payload}

    assert %{rows: [[^key, nil, nil, nil, frames]]} =
             Alplus.Repo.query!(
               "SELECT payload_s3_key, context, tags, breadcrumbs, frames FROM error_events WHERE event_id = $1",
               [event_id]
             )

    # All 4 original frames stay inline (below the 50-frame writer cap) --
    # overflow is a payload_s3_key pointer, never a truncated projection.
    assert length(frames) == 4
  end

  test "groups an overflowing item with a small twin of the same stack into one issue", %{
    conn: conn,
    secret: secret,
    project: project
  } do
    previous_pid = Application.get_env(:alplus, :observe_payload_store_test_pid)
    Application.put_env(:alplus, :observe_payload_store_test_pid, self())

    on_exit(fn ->
      if previous_pid do
        Application.put_env(:alplus, :observe_payload_store_test_pid, previous_pid)
      else
        Application.delete_env(:alplus, :observe_payload_store_test_pid)
      end
    end)

    small_id = "err_0198f0a1-7c01-7000-8000-000000000017"
    overflow_id = "err_0198f0a1-7c01-7000-8000-000000000018"
    shared_frames = Enum.map(1..4, &frame/1)

    small_item =
      put_in(exception_item(small_id), ["exception", "stacktrace", "frames"], shared_frames)

    overflow_item =
      exception_item(overflow_id)
      |> put_in(["exception", "stacktrace", "frames"], shared_frames)
      |> Map.put("contexts", %{"request" => %{"body" => String.duplicate("x", 256 * 1024)}})
      |> Map.put("tags", %{"build" => "main"})
      |> Map.put("breadcrumbs", [%{"category" => "navigation", "message" => "checkout"}])

    assert post_envelope(conn, secret, envelope(secret, [small_item])).status == 202
    assert post_envelope(build_conn(), secret, envelope(secret, [overflow_item])).status == 202

    key = "events/#{project.id}/#{overflow_id}.json"

    assert %{rows: [[outbox_id, ^key]]} =
             Alplus.Repo.query!(
               "SELECT id, payload_s3_key FROM observe_error_payload_outboxes WHERE event_id = $1",
               [overflow_id]
             )

    assert :ok = perform_job(Alplus.Observe.PayloadStorageWorker, %{"outbox_id" => outbox_id})
    assert_receive {:observe_payload_stored, ^key, _payload}

    assert %{rows: [[1]]} =
             Alplus.Repo.query!("SELECT count(*) FROM issues WHERE project_id = $1", [project.id])

    assert %{rows: [[^key, nil, nil, nil]]} =
             Alplus.Repo.query!(
               "SELECT payload_s3_key, context, tags, breadcrumbs FROM error_events WHERE event_id = $1",
               [overflow_id]
             )
  end

  test "accepts an oversized event when S3 is unavailable and retains its outbox", %{
    conn: conn,
    secret: secret,
    project: project
  } do
    previous_store = Application.fetch_env!(:alplus, :observe_payload_store)
    Application.put_env(:alplus, :observe_payload_store, Alplus.Observe.PayloadStore.Unconfigured)

    on_exit(fn -> Application.put_env(:alplus, :observe_payload_store, previous_store) end)

    event_id = "err_0198f0a1-7c01-7000-8000-000000000019"

    item =
      exception_item(event_id)
      |> Map.put("contexts", %{"request" => %{"body" => String.duplicate("x", 256 * 1024)}})

    response = post_envelope(conn, secret, envelope(secret, [item]))

    assert response.status == 202

    assert %{rows: [[outbox_id]]} =
             Alplus.Repo.query!(
               "SELECT id FROM observe_error_payload_outboxes WHERE event_id = $1",
               [event_id]
             )

    assert {:error, {:payload_store_failed, :payload_store_unconfigured}} =
             perform_job(Alplus.Observe.PayloadStorageWorker, %{"outbox_id" => outbox_id})

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM error_events WHERE project_id = $1 AND event_id = $2",
               [project.id, event_id]
             )

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM observe_error_payload_outboxes WHERE id = $1",
               [outbox_id]
             )
  end

  test "fans out a quota alert after an over-ceiling envelope is committed", %{
    conn: conn,
    org: org,
    owner_scope: owner_scope,
    project: project,
    secret: secret
  } do
    scope = Scope.put_project(owner_scope, project.id)

    {:ok, channel} =
      Alplus.Notifications.create_channel(
        %{
          org_id: org.id,
          type: "email",
          name: "Quota alerts",
          config: %{"to" => "quota@example.test"}
        },
        scope
      )

    Ash.create!(
      AlertRule,
      %{
        org_id: org.id,
        project_id: project.id,
        module: "observe",
        trigger_type: "quota",
        channel_id: channel.id
      },
      action: :create,
      actor: scope
    )

    period_start = Date.beginning_of_month(Date.utc_today())
    subscribed_fixture(org)
    ceiling = div(Alplus.Billing.Package.limit(:error_events_per_month) * 13, 10)

    Alplus.Repo.query!(
      """
      INSERT INTO usage_periods (
        id, org_id, period_start, analytics_events, dropped_analytics_events,
        error_events, dropped_error_events, inserted_at, updated_at
      ) VALUES ($1, $2, $3, 0, 0, $4, 0, now(), now())
      """,
      [Alplus.Id.generate(:usage_period), org.id, period_start, ceiling]
    )

    event_id = "err_0198f0a1-7c01-7000-8000-000000000020"
    response = post_envelope(conn, secret, envelope(secret, [exception_item(event_id)]))

    assert json_response(response, 202) == %{
             "accepted" => 0,
             "dropped" => 1,
             "dropped_reason" => "quota",
             "event_ids" => []
           }

    assert_enqueued(
      worker: DeliveryWorker,
      args: %{
        "trigger" => "quota",
        "subject_type" => "project",
        "subject_id" => project.id
      }
    )
  end

  test "accepts source-context frames and stores user, mechanism, and causes", %{
    conn: conn,
    secret: secret
  } do
    event_id = "err_0198f0a1-7c01-7000-8000-000000000021"

    item =
      Map.merge(exception_item(event_id), %{
        "user" => %{"id" => "user_42", "email" => "person@example.com"},
        "mechanism" => "rack.middleware",
        "exception" => %{
          "type" => "WrapperError",
          "value" => "outer",
          "stacktrace" => %{
            "frames" => [
              %{
                "file" => "app/models/order.rb",
                "function" => "charge!",
                "lineno" => 42,
                "in_app" => true,
                "pre_context" => ["def charge!", "  amount = total"],
                "context_line" => "  gateway.charge(amount)",
                "post_context" => ["end"]
              }
            ]
          },
          "cause" => %{
            "type" => "Timeout::Error",
            "value" => "execution expired",
            "stacktrace" => %{
              "frames" => [%{"file" => "lib/gateway.rb", "function" => "post", "lineno" => 9}]
            }
          }
        }
      })

    response = post_envelope(conn, secret, envelope(secret, [item]))
    assert json_response(response, 202)["accepted"] == 1

    %{rows: [[user_id, user_email, mechanism, frames, causes]]} =
      Alplus.Repo.query!(
        "SELECT user_id, user_email, mechanism, frames, causes FROM error_events WHERE event_id = $1",
        [event_id]
      )

    assert user_id == "user_42"
    assert user_email == "person@example.com"
    assert mechanism == "rack.middleware"

    assert [%{"context_line" => "  gateway.charge(amount)", "pre_context" => pre}] = frames
    assert pre == ["def charge!", "  amount = total"]

    assert [%{"type" => "Timeout::Error", "value" => "execution expired", "frames" => [_]}] =
             causes
  end

  test "after-error breadcrumb data round-trips to the stored row (issue #47)", %{
    conn: conn,
    secret: secret
  } do
    item =
      Map.put(exception_item("err_0198f0a1-7c01-7000-8000-000000000022"), "breadcrumbs", [
        %{
          "category" => "console",
          "message" => "retrying gateway",
          "level" => "warning",
          "ts" => "2026-08-12T09:00:10.800Z",
          "data" => %{"after_error" => true}
        }
      ])

    assert json_response(post_envelope(conn, secret, envelope(secret, [item])), 202)["accepted"] ==
             1

    %{rows: [[breadcrumbs]]} =
      Alplus.Repo.query!("SELECT breadcrumbs FROM error_events WHERE event_id = $1", [
        "err_0198f0a1-7c01-7000-8000-000000000022"
      ])

    assert [%{"data" => %{"after_error" => true}, "message" => "retrying gateway"}] = breadcrumbs
  end

  test "still rejects a frame carrying an unknown key", %{conn: conn, secret: secret} do
    item =
      put_in(
        exception_item("err_0198f0a1-7c01-7000-8000-000000000023"),
        ["exception", "stacktrace", "frames"],
        [%{"file" => "a.rb", "lineno" => 1, "locals" => %{"x" => 1}}]
      )

    response = post_envelope(conn, secret, envelope(secret, [item]))

    assert json_response(response, 202) == %{
             "accepted" => 0,
             "dropped" => 1,
             "event_ids" => [],
             "dropped_reason" => "malformed"
           }
  end

  test "rejects a cause chain nested past the depth bound", %{conn: conn, secret: secret} do
    too_deep =
      Enum.reduce(1..5, %{"type" => "Root", "value" => "deepest"}, fn n, inner ->
        %{"type" => "Layer#{n}", "value" => "wrap", "cause" => inner}
      end)

    item =
      put_in(
        exception_item("err_0198f0a1-7c01-7000-8000-000000000024"),
        ["exception", "cause"],
        too_deep
      )

    response = post_envelope(conn, secret, envelope(secret, [item]))

    assert json_response(response, 202)["dropped_reason"] == "malformed"
  end

  describe "sourcemap symbolication" do
    # The Fake store's put/1 needs a test recipient, and get/1 reads
    # app-env-configured responses; both are process-global, matching this
    # file's async: false.
    setup do
      Application.put_env(:alplus, :observe_payload_store_test_pid, self())

      on_exit(fn ->
        Application.delete_env(:alplus, :observe_payload_store_test_pid)
        Application.delete_env(:alplus, :observe_payload_store_test_gets)
      end)

      :ok
    end

    defp source_map_body do
      Jason.encode!(%{
        "version" => 3,
        "sources" => ["webpack://app/src/checkout.ts"],
        "names" => ["chargeOrder", "boom"],
        "mappings" => "AAAAA,IACAC,SACA",
        "sourcesContent" => [
          "function chargeOrder() {\n  boom();\n}\nexport { chargeOrder };\n"
        ]
      })
    end

    defp upload_artifact(secret, release, name, body) do
      build_conn()
      |> put_req_header("authorization", "Bearer #{secret}")
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/e/artifacts?release=#{release}&name=#{name}", body)
    end

    test "an uploaded map remaps a minified frame to original source with context", %{
      conn: conn,
      secret: secret
    } do
      response = upload_artifact(secret, "9.9.9", "app-abc123.js.map", source_map_body())
      assert response.status == 201

      # Wire the Fake store's read side to return what the upload stored.
      assert_receive {:observe_payload_stored, storage_key, stored_map}

      Application.put_env(:alplus, :observe_payload_store_test_gets, %{
        storage_key => {:ok, stored_map}
      })

      item =
        Map.merge(exception_item("err_0198f0a1-7c01-7000-8000-000000000025"), %{
          "release" => "9.9.9",
          "exception" => %{
            "type" => "TypeError",
            "value" => "boom is not a function",
            "stacktrace" => %{
              "frames" => [
                %{
                  "file" => "https://cdn.test/assets/app-abc123.js",
                  "function" => "r",
                  "lineno" => 1,
                  "colno" => 6,
                  "in_app" => false
                }
              ]
            }
          }
        })

      assert json_response(post_envelope(conn, secret, envelope(secret, [item])), 202)[
               "accepted"
             ] == 1

      %{rows: [[frames]]} =
        Alplus.Repo.query!("SELECT frames FROM error_events WHERE event_id = $1", [
          "err_0198f0a1-7c01-7000-8000-000000000025"
        ])

      assert [frame] = frames
      assert frame["file"] == "webpack://app/src/checkout.ts"
      assert frame["lineno"] == 2
      assert frame["function"] == "boom"
      assert frame["in_app"] == true
      assert frame["context_line"] == "  boom();"
      assert frame["pre_context"] == ["function chargeOrder() {"]
    end

    test "an event with no release, or a frame with no matching map, passes through raw", %{
      conn: conn,
      secret: secret
    } do
      item =
        put_in(
          exception_item("err_0198f0a1-7c01-7000-8000-000000000026"),
          ["exception", "stacktrace", "frames"],
          [%{"file" => "https://cdn.test/assets/other.js", "lineno" => 1, "colno" => 5}]
        )

      assert json_response(post_envelope(conn, secret, envelope(secret, [item])), 202)[
               "accepted"
             ] == 1

      %{rows: [[frames]]} =
        Alplus.Repo.query!("SELECT frames FROM error_events WHERE event_id = $1", [
          "err_0198f0a1-7c01-7000-8000-000000000026"
        ])

      assert [%{"file" => "https://cdn.test/assets/other.js", "lineno" => 1}] = frames
    end

    test "the artifact endpoint rejects a body that is not a v3 source map", %{secret: secret} do
      response = upload_artifact(secret, "9.9.9", "app.js.map", "not a source map")
      assert response.status == 400
    end

    test "the artifact endpoint rejects a bad name and a missing release", %{secret: secret} do
      assert upload_artifact(secret, "9.9.9", "..%2Fescape.map", source_map_body()).status == 400
      assert upload_artifact(secret, "", "app.js.map", source_map_body()).status == 400
      assert upload_artifact(secret, "9.9.9", "app.js", source_map_body()).status == 400
    end

    test "the artifact endpoint rejects a missing bearer" do
      response =
        build_conn()
        |> put_req_header("content-type", "application/octet-stream")
        |> post("/e/artifacts?release=1.0.0&name=app.js.map", source_map_body())

      assert response.status == 401
    end

    test "the artifact endpoint rejects an invalid key" do
      response =
        build_conn()
        |> put_req_header("authorization", "Bearer alp_not-a-key")
        |> put_req_header("content-type", "application/octet-stream")
        |> post("/e/artifacts?release=1.0.0&name=app.js.map", source_map_body())

      assert response.status == 401
      assert_receive :invalid_key_tarpit
    end
  end

  defp post_envelope(conn, secret, envelope) do
    post_raw(conn, secret, Jason.encode!(envelope))
  end

  defp post_raw(conn, secret, body, content_type \\ "application/json") do
    conn = put_req_header(conn, "content-type", content_type)
    conn = if secret, do: put_req_header(conn, "authorization", "Bearer #{secret}"), else: conn
    post(conn, "/e/errors", body)
  end

  defp envelope(key, items) do
    %{
      "header" => %{
        "key" => key,
        "sdk" => %{"name" => "@alplus/sdk", "version" => "0.3.0", "platform" => "node"}
      },
      "items" => items
    }
  end

  defp exception_item(id) do
    %{
      "id" => id,
      "type" => "exception",
      "timestamp" => "2026-08-11T12:00:00Z",
      "level" => "error",
      "exception" => %{
        "type" => "TypeError",
        "value" => "boom",
        "stacktrace" => %{
          "frames" => [%{"file" => "/src/app.ts", "function" => "run", "lineno" => 4}]
        }
      }
    }
  end

  defp frame(number) do
    %{"file" => "/src/#{number}.ts", "function" => "step#{number}", "lineno" => number}
  end
end
