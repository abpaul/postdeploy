defmodule AlplusWeb.SentryIngestControllerTest do
  use AlplusWeb.ConnCase, async: false
  use Oban.Testing, repo: Alplus.Repo

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

    %{project: project, secret: secret}
  end

  def tarpit(_milliseconds) do
    send(self(), :invalid_key_tarpit)
    :ok
  end

  describe "events captured from the real SDKs" do
    test "sentry-ruby: crash site first, cause chain, source context", %{
      project: project,
      secret: secret
    } do
      event_id =
        post_fixture(
          "ruby_exception",
          "Sentry sentry_version=7, sentry_timestamp=1791036524, sentry_key=#{secret}, sentry_client=sentry-ruby/7.1.0"
        )

      assert [
               [
                 "RuntimeError",
                 "checkout failed",
                 [crash_site | _],
                 [%{"type" => "Timeout::Error", "value" => "execution expired"}],
                 "production",
                 "error",
                 "1.4.2",
                 "42",
                 "person@example.com",
                 "sentry.ruby",
                 %{"team" => "payments"},
                 [%{"category" => "http", "message" => "POST /charge"}],
                 issue_id
               ]
             ] = stored(event_id, project)

      assert %{
               "file" => "app.rb",
               "function" => "rescue in charge",
               "lineno" => 17,
               "in_app" => true,
               "context_line" => "    raise \"checkout failed\""
             } = crash_site

      assert issue(issue_id) == ["RuntimeError: checkout failed", "app.rb:rescue in charge"]
    end

    test "sentry-elixir: exception and message events", %{project: project, secret: secret} do
      auth =
        "Sentry sentry_version=5, sentry_client=sentry-elixir/13.5.1, sentry_timestamp=1791036650, sentry_key=#{secret}"

      exception_id = post_fixture("elixir_exception", auth)

      assert [
               [
                 "RuntimeError",
                 "checkout failed: bad amount 12",
                 [%{"file" => "app.exs", "function" => "Checkout.charge/1", "lineno" => 8} | _],
                 nil,
                 "production",
                 "error",
                 "1.4.2",
                 "42",
                 "person@example.com",
                 "sentry-elixir",
                 %{"team" => "payments"},
                 [%{"category" => "http", "message" => "POST /charge"}],
                 _issue_id
               ]
             ] = stored(exception_id, project)

      message_id = post_fixture("elixir_message", auth)

      assert [["queue depth is 12", "warning"]] =
               Alplus.Repo.query!(
                 "SELECT message, level FROM error_events WHERE event_id = $1 AND project_id = $2",
                 [message_id, project.id]
               ).rows
    end

    test "sentry-rust: a panic groups on the application frame", %{
      project: project,
      secret: secret
    } do
      auth =
        "Sentry sentry_key=#{secret}, sentry_version=7, sentry_timestamp=1791036632.465297, sentry_client=sentry.rust/0.49.3"

      event_id = post_fixture("rust_panic", auth)

      assert [
               [
                 "panic",
                 "worker exploded",
                 frames,
                 nil,
                 "production",
                 "fatal",
                 "pdcap@1.4.2",
                 "42",
                 "person@example.com",
                 "sentry.rust",
                 %{"team" => "payments"},
                 [%{"message" => "POST /charge"}],
                 issue_id
               ]
             ] = stored(event_id, project)

      assert [%{"function" => "pdcap::main", "lineno" => 22}, %{"function" => "_main"}] =
               Enum.filter(frames, & &1["in_app"])

      assert issue(issue_id) == [
               "panic: worker exploded",
               "/private/tmp/pd-sentry/rs/src/main.rs:pdcap::main"
             ]
    end

    test "sentry-rust: an error logged through tracing keeps its fields", %{
      project: project,
      secret: secret
    } do
      auth =
        "Sentry sentry_key=#{secret}, sentry_version=7, sentry_timestamp=1791036632.465297, sentry_client=sentry.rust/0.49.3"

      event_id = post_fixture("rust_message", auth)

      assert [["controller_error", "error", context]] =
               Alplus.Repo.query!(
                 "SELECT message, level, context FROM error_events WHERE event_id = $1 AND project_id = $2",
                 [event_id, project.id]
               ).rows

      assert %{"error.msg" => "checkout failed"} = context["Rust Tracing Fields"]
    end

    test "sentry.javascript.node: query-string key, user, tag and release", %{
      project: project,
      secret: secret
    } do
      response =
        build_conn()
        |> put_req_header("content-type", "application/x-sentry-envelope")
        |> post(
          "/api/1/envelope/?sentry_version=7&sentry_key=#{secret}&sentry_client=sentry.javascript.node%2F11.6.0",
          fixture("js_exception")
        )

      assert %{"id" => event_id} = json_response(response, 200)

      assert [
               [
                 "Error",
                 "Payment provider timed out",
                 [%{"file" => "/srv/app/app.mjs", "in_app" => true} | _],
                 nil,
                 "production",
                 "error",
                 "1.0.0",
                 "user_123",
                 "jane@example.com",
                 "sentry.javascript.node",
                 %{"plan" => "pro"},
                 _breadcrumbs,
                 _issue_id
               ]
             ] = stored(event_id, project)
    end
  end

  describe "Observe keys as Sentry DSN public keys" do
    setup do
      {org, owner_scope} = org_fixture(scope_fixture())
      project = project_fixture(owner_scope, org)

      %{
        org: org,
        project: project,
        owner_scope: Alplus.Scope.put_project(owner_scope, project.id)
      }
    end

    test "every minted and rotated key is accepted by the Sentry SDK and ingests", %{
      org: org,
      project: project,
      owner_scope: scope
    } do
      pairs =
        for n <- 1..16 do
          {source, minted} = source_fixture(scope, org, project, %{environment: "dsn-#{n}"})

          rotated =
            Ash.update!(source, %{grace_period_seconds: 0}, action: :rotate, actor: scope)

          {minted, Ash.Resource.get_metadata(rotated, :secret)}
        end

      for {minted, replacement} <- pairs, key <- [minted, replacement] do
        assert byte_size(key) == 47
        assert sdk_dsn_public_key?(key), "Sentry SDKs reject the DSN for a minted or rotated key"
      end

      for {_minted, replacement} <- pairs do
        assert %{"id" => _} = replacement |> post_js_exception() |> json_response(200)
      end
    end

    test "a stored key that contains a hyphen authenticates before and during rotation", %{
      org: org,
      project: project,
      owner_scope: scope
    } do
      {source, _minted} = source_fixture(scope, org, project)
      legacy = "obs_ab-cdefgH1J2k3L4m5N6o7P8q9R0s1T2u3V4w5X6y7Z8"
      refute sdk_dsn_public_key?(legacy)

      source =
        Ash.Seed.update!(source, %{
          secret_hash: Alplus.Security.BearerToken.hash(legacy),
          secret_prefix: Alplus.Security.BearerToken.short_prefix(legacy)
        })

      assert %{"id" => _} = legacy |> post_js_exception() |> json_response(200)

      rotated = Ash.update!(source, %{grace_period_seconds: 3600}, action: :rotate, actor: scope)
      replacement = Ash.Resource.get_metadata(rotated, :secret)

      assert sdk_dsn_public_key?(replacement)
      assert %{"id" => _} = legacy |> post_js_exception() |> json_response(200)
      assert %{"id" => _} = replacement |> post_js_exception() |> json_response(200)
    end
  end

  test "maps a multi-item envelope with a length-less item", %{
    conn: conn,
    project: project,
    secret: secret
  } do
    event_id = "fc6d8c0c43fc4630ad850ee518f1b9d0"

    body =
      envelope(event_id, [
        {"session", %{"sid" => "abc", "status" => "ok"}},
        {"event", exception_event()}
      ])

    assert json_response(post_envelope(conn, secret, body), 200) == %{"id" => event_id}

    assert [[[%{"function" => "charge", "pre_context" => ["  def charge"]} | _], "rails"]] =
             Alplus.Repo.query!(
               "SELECT frames, mechanism FROM error_events WHERE event_id = $1 AND project_id = $2",
               [event_id, project.id]
             ).rows
  end

  test "accepts a gzip body, a query-string key, and a message event with a Unix timestamp", %{
    project: project,
    secret: secret
  } do
    event_id = "0b5f7d0e2a7e4f0c9d6a1f3b8c2e4a61"

    event = %{
      "event_id" => event_id,
      "timestamp" => 1_790_000_000.25,
      "level" => "debug",
      "logentry" => %{"formatted" => "queue depth is 12"}
    }

    response =
      build_conn()
      |> put_req_header("content-type", "application/x-sentry-envelope")
      |> put_req_header("content-encoding", "gzip")
      |> post(
        "/api/1/envelope/?sentry_key=#{secret}",
        :zlib.gzip(envelope(event_id, [{"event", event}]))
      )

    assert json_response(response, 200) == %{"id" => event_id}

    assert [["queue depth is 12", "info", occurred_at]] =
             Alplus.Repo.query!(
               "SELECT message, level, occurred_at FROM error_events WHERE event_id = $1 AND project_id = $2",
               [event_id, project.id]
             ).rows

    assert DateTime.to_unix(DateTime.from_naive!(occurred_at, "Etc/UTC")) == 1_790_000_000
  end

  test "discards item types other than event", %{
    conn: conn,
    project: project,
    secret: secret
  } do
    event_id = "9a1c5e3f7b2d4a6c8e0f1a2b3c4d5e6f"

    body =
      envelope(event_id, [
        {"session", %{"sid" => "abc", "status" => "ok"}},
        {"transaction", %{"type" => "transaction", "spans" => []}},
        {"client_report", %{"discarded_events" => []}}
      ])

    response = post_envelope(conn, secret, body)

    assert json_response(response, 200) == %{"id" => event_id}

    assert [[0]] =
             Alplus.Repo.query!("SELECT count(*) FROM error_events WHERE project_id = $1", [
               project.id
             ]).rows
  end

  test "stores a retried event once", %{project: project, secret: secret} do
    event_id = "1f2e3d4c5b6a47988796a5b4c3d2e1f0"
    body = envelope(event_id, [{"event", exception_event()}])

    assert post_envelope(build_conn(), secret, body).status == 200
    assert post_envelope(build_conn(), secret, body).status == 200

    assert [[1]] =
             Alplus.Repo.query!(
               "SELECT count(*) FROM error_events WHERE event_id = $1 AND project_id = $2",
               [event_id, project.id]
             ).rows
  end

  test "rejects a missing or unknown key", %{conn: conn} do
    body = envelope("7c8d9e0f1a2b4c3d8e7f6a5b4c3d2e1f", [{"event", exception_event()}])

    assert post_envelope(conn, nil, body).status == 401
    assert_receive :invalid_key_tarpit

    assert post_envelope(build_conn(), "obs_not-a-real-key", body).status == 401
    assert_receive :invalid_key_tarpit
  end

  test "rejects a key of another source type", %{conn: conn} do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    {_source, analytics_key} = source_fixture(owner_scope, org, project, %{type: :analytics})

    body = envelope("5a6b7c8d9e0f4a1b8c2d3e4f5a6b7c8d", [{"event", exception_event()}])

    assert post_envelope(conn, analytics_key, body).status == 401
  end

  test "stores an event whose timestamps are out of range", %{
    conn: conn,
    project: project,
    secret: secret
  } do
    event_id = "2b3c4d5e6f7a4b8c9d0e1f2a3b4c5d6e"

    event = %{
      "message" => "clock is wrong",
      "timestamp" => 1.0e305,
      "breadcrumbs" => [%{"message" => "x", "timestamp" => false}, %{"timestamp" => 1.0e305}]
    }

    response = post_envelope(conn, secret, envelope(event_id, [{"event", event}]))

    assert json_response(response, 200) == %{"id" => event_id}

    assert [["clock is wrong"]] =
             Alplus.Repo.query!(
               "SELECT message FROM error_events WHERE event_id = $1 AND project_id = $2",
               [event_id, project.id]
             ).rows
  end

  test "rejects a truncated gzip body, an unknown encoding, and an item flood", %{secret: secret} do
    body = envelope("3c4d5e6f7a8b4c9d8e0f1a2b3c4d5e6f", [{"event", exception_event()}])
    gzip = :zlib.gzip(body)

    post_encoded = fn encoding, bytes ->
      build_conn()
      |> put_req_header("content-encoding", encoding)
      |> post_envelope(secret, bytes)
    end

    assert post_encoded.("gzip", binary_part(gzip, 0, byte_size(gzip) - 12)).status == 400
    assert post_encoded.("br", body).status == 415

    flood = IO.iodata_to_binary([~s({"event_id":null}\n), List.duplicate("{}\n\n", 5_000)])
    assert post_envelope(build_conn(), secret, flood).status == 400
  end

  test "rejects a body that is not an envelope", %{conn: conn, secret: secret} do
    assert json_response(post_envelope(conn, secret, "not json\n"), 400) == %{
             "error" => %{"type" => "invalid_request_error", "code" => "validation_failed"}
           }
  end

  # The fixtures hold the bytes each SDK sent to a local listener on
  # 2026-10-03 (JavaScript: 2026-10-12), minus `modules`, `debug_meta` and
  # host details. Each test sends the key in the form that SDK used.
  defp fixture(name),
    do: File.read!(Path.join([__DIR__, "../../support/fixtures/sentry", name <> ".envelope"]))

  defp post_js_exception(secret) do
    build_conn()
    |> put_req_header("content-type", "application/x-sentry-envelope")
    |> post(
      "/api/1/envelope/?sentry_version=7&sentry_key=#{secret}&sentry_client=sentry.javascript.node%2F11.6.0",
      fixture("js_exception")
    )
  end

  # `@sentry/core` 11.6.0 reads the DSN public key with `(\w+)` and discards a
  # DSN whose key holds any other character.
  defp sdk_dsn_public_key?(key), do: Regex.match?(~r/\A\w+\z/, key)

  defp post_fixture(name, auth) do
    response =
      build_conn()
      |> put_req_header("content-type", "application/x-sentry-envelope")
      |> put_req_header("x-sentry-auth", auth)
      |> post("/api/1/envelope/", fixture(name))

    %{"id" => event_id} = json_response(response, 200)
    event_id
  end

  defp stored(event_id, project) do
    Alplus.Repo.query!(
      """
      SELECT exception_type, exception_value, frames, causes, environment, level, release,
             user_id, user_email, sdk_name, tags, breadcrumbs, issue_id
      FROM error_events WHERE event_id = $1 AND project_id = $2
      """,
      [event_id, project.id]
    ).rows
  end

  defp issue(issue_id) do
    [row] = Alplus.Repo.query!("SELECT title, culprit FROM issues WHERE id = $1", [issue_id]).rows
    row
  end

  defp post_envelope(conn, secret, body) do
    conn = put_req_header(conn, "content-type", "application/x-sentry-envelope")

    conn =
      if secret do
        put_req_header(
          conn,
          "x-sentry-auth",
          "Sentry sentry_version=7, sentry_client=sentry-ruby/5.26.0, sentry_key=#{secret}"
        )
      else
        conn
      end

    post(conn, "/api/1/envelope/", body)
  end

  # One item carries a `length`; the next ends at its newline. A Sentry SDK may
  # send either form.
  defp envelope(event_id, items) do
    lines =
      items
      |> Enum.with_index()
      |> Enum.map(fn {{type, payload}, index} ->
        encoded = Jason.encode!(payload)

        header =
          if rem(index, 2) == 0,
            do: %{"type" => type, "length" => byte_size(encoded)},
            else: %{"type" => type}

        [Jason.encode!(header), "\n", encoded, "\n"]
      end)

    IO.iodata_to_binary([Jason.encode!(%{"event_id" => event_id}), "\n", lines])
  end

  defp exception_event do
    %{
      "timestamp" => "2026-10-03T10:00:01",
      "platform" => "ruby",
      "level" => "error",
      "release" => "1.4.2",
      "environment" => "staging",
      "sdk" => %{"name" => "sentry.ruby.rails", "version" => "5.26.0"},
      "tags" => %{"team" => "payments"},
      "user" => %{"id" => "user_42", "email" => "person@example.com", "ip_address" => "::1"},
      "breadcrumbs" => %{
        "values" => [
          %{
            "category" => "http",
            "message" => "POST /charge",
            "type" => "http",
            "timestamp" => "2026-10-03T10:00:00Z"
          }
        ]
      },
      "exception" => %{
        "values" => [
          %{"type" => "Timeout::Error", "value" => "execution expired", "module" => "Timeout"},
          %{
            "type" => "RuntimeError",
            "value" => "checkout failed",
            "mechanism" => %{"type" => "rails", "handled" => false},
            "stacktrace" => %{
              "frames" => [
                %{
                  "filename" => "puma/server.rb",
                  "abs_path" => "/gems/puma/server.rb",
                  "function" => "process_client",
                  "lineno" => 10,
                  "in_app" => false
                },
                %{
                  "filename" => "app/services/checkout.rb",
                  "function" => "charge",
                  "lineno" => 42,
                  "in_app" => true,
                  "pre_context" => ["  def charge"],
                  "context_line" => "    raise \"checkout failed\"",
                  "post_context" => ["  end"],
                  "vars" => %{"amount" => 12}
                }
              ]
            }
          }
        ]
      }
    }
  end
end
