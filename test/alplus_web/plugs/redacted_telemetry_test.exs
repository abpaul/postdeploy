defmodule AlplusWeb.Plugs.RedactedTelemetryTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias AlplusWeb.Plugs.RedactedTelemetry

  test "redacts every bearer path on a telemetry copy and preserves the request path" do
    for {path, expected_path} <- [
          {"/share/share_private_bearer", "/share/[FILTERED]"},
          {"/h/heartbeat_private_bearer/1", "/h/[FILTERED]/1"},
          {"/invitations/invitation_private_bearer", "/invitations/[FILTERED]"},
          {"/password-reset/reset_private_bearer", "/password-reset/[FILTERED]"},
          {"/confirm_new_user/confirm_private_bearer", "/confirm_new_user/[FILTERED]"},
          {"/confirm_email_change/change_private_bearer", "/confirm_email_change/[FILTERED]"}
        ] do
      conn = conn(:get, path)
      redacted = RedactedTelemetry.redact(conn)

      assert redacted.request_path == expected_path
      assert conn.request_path == path
      assert redacted.path_info == conn.path_info
    end
  end

  test "leaves an unrelated path unchanged" do
    conn = conn(:get, "/pricing/private-value")

    assert RedactedTelemetry.redact(conn).request_path == "/pricing/private-value"
  end

  test "keeps a file upload in the params and still redacts beside it" do
    upload = %Plug.Upload{path: "/tmp/upload", filename: "shell.php", content_type: "text/plain"}

    redacted =
      conn(:post, "/wp-admin/admin-ajax.php", %{"file" => upload, "token" => "secret"})
      |> RedactedTelemetry.redact()

    assert redacted.params == %{"file" => upload, "token" => "[FILTERED]"}
  end

  test "redacts OAuth secrets from params, query strings, and Authorization headers" do
    conn =
      conn(:post, "/oauth/token?access_token=mcoat_query&code=mcoac_query", %{
        "grant_type" => "authorization_code",
        "code" => "mcoac_secret",
        "code_verifier" => "pkce-verifier-secret",
        "code_challenge" => "pkce-challenge-secret",
        "refresh_token" => "mcort_secret",
        "access_token" => "mcoat_secret",
        "client_id" => "https://client.example/metadata.json"
      })
      |> Plug.Conn.put_req_header("authorization", "Bearer mcoat_header")
      |> Plug.Conn.put_private(
        :alplus_raw_body,
        "code=mcoac_raw&refresh_token=mcort_raw&code_verifier=pkce-raw"
      )

    redacted = RedactedTelemetry.redact(conn)

    assert redacted.params["code"] == "[FILTERED]"
    assert redacted.params["code_verifier"] == "[FILTERED]"
    assert redacted.params["code_challenge"] == "[FILTERED]"
    assert redacted.params["refresh_token"] == "[FILTERED]"
    assert redacted.params["access_token"] == "[FILTERED]"
    assert redacted.params["grant_type"] == "authorization_code"
    assert redacted.params["client_id"] == "https://client.example/metadata.json"
    query = URI.decode_query(redacted.query_string)
    assert query["access_token"] == "[FILTERED]"
    assert query["code"] == "[FILTERED]"
    refute redacted.query_string =~ "mcoac_query"
    refute redacted.query_string =~ "mcoat_query"
    assert Plug.Conn.get_req_header(redacted, "authorization") == ["Bearer [FILTERED]"]
    assert conn.params["code"] == "mcoac_secret"
    assert conn.params["refresh_token"] == "mcort_secret"
    refute Map.has_key?(redacted.private, :alplus_raw_body)
    assert conn.private[:alplus_raw_body] =~ "mcort_raw"
    assert conn.query_string =~ "mcoat_query"
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer mcoat_header"]
  end

  test "emits sanitized start and stop telemetry while preserving the live connection" do
    event_prefix = [:redacted_telemetry_test, :endpoint]
    start_event = event_prefix ++ [:start]
    stop_event = event_prefix ++ [:stop]
    event_id = {__MODULE__, make_ref()}
    test_pid = self()

    :telemetry.attach_many(
      event_id,
      [start_event, stop_event],
      fn event, _measurements, %{conn: conn}, _config ->
        send(test_pid, {event, conn.request_path})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(event_id) end)

    conn =
      conn(:get, "/password-reset/reset_private_bearer")
      |> RedactedTelemetry.call(RedactedTelemetry.init(event_prefix: event_prefix))

    assert conn.request_path == "/password-reset/reset_private_bearer"
    conn = Plug.Conn.send_resp(conn, 200, "ok")
    assert conn.request_path == "/password-reset/reset_private_bearer"

    assert_receive {^start_event, "/password-reset/[FILTERED]"}
    assert_receive {^stop_event, "/password-reset/[FILTERED]"}
  end
end
