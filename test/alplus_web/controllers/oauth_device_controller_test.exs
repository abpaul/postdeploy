defmodule AlplusWeb.OAuthDeviceControllerTest.MetadataResolver do
  @address {1, 1, 1, 1}

  def resolve("client.example", _timeout), do: {:ok, [@address]}
  def resolve(_host, _timeout), do: {:error, :nxdomain}
end

defmodule AlplusWeb.OAuthDeviceControllerTest.MetadataHTTPClient do
  @client_id "https://client.example/metadata.json"
  @redirect_uri "https://client.example/oauth/callback"
  @unrelated_secret "client-metadata-secret-that-must-never-leak"

  def get(
        %URI{scheme: "https", host: "client.example", path: "/metadata.json"},
        {1, 1, 1, 1},
        _opts
      ) do
    body =
      Jason.encode!(%{
        "client_id" => @client_id,
        "client_name" => "Test MCP Client",
        "redirect_uris" => [@redirect_uri],
        "unrelated_secret" => @unrelated_secret
      })

    {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: body}}
  end

  def get(_uri, _address, _opts), do: {:error, :unexpected_request}
end

defmodule AlplusWeb.OAuthDeviceControllerTest do
  @moduledoc """
  The device grant exists so an agent with no browser on its own host can
  still connect. These tests drive the whole loop a real client runs: start,
  poll, approve in a browser, poll again.
  """

  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Mcp.OAuth

  @client_id "https://client.example/metadata.json"
  @scope "projects:read monitor:read"
  @device_grant_type "urn:ietf:params:oauth:grant-type:device_code"
  @unrelated_secret "client-metadata-secret-that-must-never-leak"

  setup do
    previous_fetch_opts = Application.fetch_env(:alplus, :mcp_oauth_metadata_fetch_opts)

    Application.put_env(:alplus, :mcp_oauth_metadata_fetch_opts,
      dns_resolver: AlplusWeb.OAuthDeviceControllerTest.MetadataResolver,
      http_client: AlplusWeb.OAuthDeviceControllerTest.MetadataHTTPClient
    )

    on_exit(fn -> restore_fetch_opts(previous_fetch_opts) end)

    user = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(user.id))
    project = project_fixture(scope, org)

    %{user: user, org: org, project: project, resource: OAuth.resource_uri()}
  end

  test "a client with no browser connects by polling while a person approves", context do
    start = start_device_authorization(context)

    assert %{
             "device_code" => device_code,
             "user_code" => user_code,
             "verification_uri" => verification_uri,
             "verification_uri_complete" => verification_uri_complete,
             "expires_in" => expires_in,
             "interval" => interval
           } = json_response(start, 200)

    assert verification_uri == OAuth.verification_uri()
    assert verification_uri_complete =~ URI.encode_www_form(user_code)
    assert expires_in > 0
    assert interval > 0
    assert Regex.match?(~r/\A[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}\z/, user_code)
    refute device_code == user_code

    # Nobody has approved yet, so the client must keep waiting.
    assert %{"error" => "authorization_pending"} =
             context |> poll_token(device_code) |> json_response(400)

    approve_in_browser(context, user_code)

    body = context |> poll_token(device_code) |> json_response(200)

    assert %{
             "access_token" => access_token,
             "refresh_token" => refresh_token,
             "token_type" => "Bearer",
             "scope" => "monitor:read projects:read"
           } = body

    assert MapSet.new(Map.keys(body)) ==
             MapSet.new(~w(access_token refresh_token token_type expires_in scope))

    assert usable_access_token?(access_token)
    refute body |> Jason.encode!() |> String.contains?(@unrelated_secret)

    # The device code is single-use.
    assert %{"error" => "invalid_grant"} =
             context |> poll_token(device_code) |> json_response(400)

    assert is_binary(refresh_token)
  end

  test "grants only the permissions the person selected", context do
    start = start_device_authorization(context)
    %{"device_code" => device_code, "user_code" => user_code} = json_response(start, 200)

    # The request asked for two permissions. Keep the second one only.
    approve_in_browser(context, user_code, ["1"])

    assert %{"scope" => "projects:read"} =
             context |> poll_token(device_code) |> json_response(200)
  end

  test "polling faster than the advertised interval is told to slow down", context do
    start = start_device_authorization(context)
    %{"device_code" => device_code} = json_response(start, 200)

    assert %{"error" => "authorization_pending"} =
             context |> poll_token(device_code) |> json_response(400)

    assert %{"error" => "slow_down"} =
             context |> poll_token(device_code) |> json_response(400)
  end

  test "a refused request reports access_denied", context do
    start = start_device_authorization(context)
    %{"device_code" => device_code, "user_code" => user_code} = json_response(start, 200)

    deny_in_browser(context, user_code)

    assert %{"error" => "access_denied"} =
             context |> poll_token(device_code) |> json_response(400)
  end

  test "an expired request reports expired_token", context do
    start = start_device_authorization(context)
    %{"device_code" => device_code} = json_response(start, 200)

    expire_device_codes!()

    assert %{"error" => "expired_token"} =
             context |> poll_token(device_code) |> json_response(400)
  end

  test "rejects an unknown device code without disclosing anything", context do
    response = poll_token(context, "mcodc_a-device-code-that-was-never-issued")

    assert %{"error" => "invalid_grant"} = json_response(response, 400)
    refute response.resp_body =~ context.org.id
    refute response.resp_body =~ context.project.id
  end

  test "rejects a device code presented for a different resource", context do
    start = start_device_authorization(context)
    %{"device_code" => device_code, "user_code" => user_code} = json_response(start, 200)

    approve_in_browser(context, user_code)

    response =
      post(build_conn(), "/oauth/token", %{
        "grant_type" => @device_grant_type,
        "device_code" => device_code,
        "client_id" => @client_id,
        "resource" => OAuth.resource_uri("AAAAAAAAAAAAAAAA")
      })

    assert %{"error" => "invalid_grant"} = json_response(response, 400)
  end

  test "a member who is not an owner or admin cannot approve a device code", context do
    start = start_device_authorization(context)
    %{"device_code" => device_code, "user_code" => user_code} = json_response(start, 200)

    member = user_fixture()
    _member_scope = member_fixture(Alplus.Scope.for_user(context.user.id), context.org, member)

    response =
      build_conn()
      |> log_in(member)
      |> post("/activate", %{
        "_csrf_token" => Plug.CSRFProtection.get_csrf_token(),
        "user_code" => user_code
      })

    # The member has no organization they may grant, so consent never renders.
    refute html_response(response, 200) =~ ~s(id="oauth-consent-heading")

    assert %{"error" => "authorization_pending"} =
             context |> poll_token(device_code) |> json_response(400)
  end

  test "a user cannot approve a device code onto another organization's project", context do
    start = start_device_authorization(context)
    %{"device_code" => device_code, "user_code" => user_code} = json_response(start, 200)

    outsider = user_fixture()
    {other_org, outsider_scope} = org_fixture(Alplus.Scope.for_user(outsider.id))
    _outsider_project = project_fixture(outsider_scope, other_org)

    consent =
      build_conn()
      |> log_in(outsider)
      |> post("/activate", %{
        "_csrf_token" => Plug.CSRFProtection.get_csrf_token(),
        "user_code" => user_code
      })

    assert html_response(consent, 200) =~ ~s(id="oauth-consent-heading")

    # The outsider names the victim's organization and project explicitly.
    response =
      consent
      |> recycle()
      |> post("/activate", %{
        "_csrf_token" => Plug.CSRFProtection.get_csrf_token(),
        "decision" => "allow",
        "org_id" => context.org.id,
        "project_id" => context.project.id,
        "scope_indices" => ["0", "1"]
      })

    refute html_response(response, 200) =~ ~s(id="device-activation-result-heading")

    assert %{"error" => "authorization_pending"} =
             context |> poll_token(device_code) |> json_response(400)
  end

  test "another client cannot redeem a device code it did not start", context do
    start = start_device_authorization(context)
    %{"device_code" => device_code, "user_code" => user_code} = json_response(start, 200)

    approve_in_browser(context, user_code)

    # A second client registers itself and presents the leaked device code.
    %{"client_id" => other_client_id} =
      build_conn()
      |> post("/oauth/register", %{
        "client_name" => "Impostor",
        "redirect_uris" => ["https://impostor.example/callback"]
      })
      |> json_response(201)

    response =
      post(build_conn(), "/oauth/token", %{
        "grant_type" => @device_grant_type,
        "device_code" => device_code,
        "client_id" => other_client_id,
        "resource" => context.resource
      })

    assert %{"error" => "invalid_grant"} = json_response(response, 400)

    # The theft must not burn the code either: the real client still works.
    assert %{"access_token" => _} = context |> poll_token(device_code) |> json_response(200)
  end

  test "a later wider consent does not widen a device code already approved", context do
    first = start_device_authorization(context)
    %{"device_code" => device_code, "user_code" => user_code} = json_response(first, 200)

    # Approve this machine with the first permission only.
    approve_in_browser(context, user_code, ["0"])

    # The same person then approves the same client, on another machine, with
    # both permissions. That rewrites the shared grant.
    second = start_device_authorization(context)
    %{"user_code" => wide_user_code} = json_response(second, 200)
    approve_in_browser(context, wide_user_code, ["0", "1"])

    assert %{"scope" => "monitor:read"} =
             context |> poll_token(device_code) |> json_response(200)
  end

  test "rejects a device authorization request for an unsupported scope", context do
    response =
      post(build_conn(), "/oauth/device_authorization", %{
        "client_id" => @client_id,
        "resource" => context.resource,
        "scope" => "not-a-real-scope"
      })

    assert %{"error" => "invalid_scope"} = json_response(response, 400)
  end

  test "advertises the device grant so clients can discover it", %{conn: conn} do
    metadata = conn |> get("/.well-known/oauth-authorization-server") |> json_response(200)

    assert metadata["device_authorization_endpoint"] == OAuth.device_authorization_endpoint()
    assert @device_grant_type in metadata["grant_types_supported"]
  end

  defp start_device_authorization(context) do
    post(build_conn(), "/oauth/device_authorization", %{
      "client_id" => @client_id,
      "resource" => context.resource,
      "scope" => @scope
    })
  end

  defp poll_token(context, device_code) do
    post(build_conn(), "/oauth/token", %{
      "grant_type" => @device_grant_type,
      "device_code" => device_code,
      "client_id" => @client_id,
      "resource" => context.resource
    })
  end

  defp approve_in_browser(context, user_code, scope_indices \\ ["0", "1"]) do
    consent = submit_user_code(context, user_code)

    response =
      consent
      |> recycle()
      |> post("/activate", %{
        "_csrf_token" => Plug.CSRFProtection.get_csrf_token(),
        "decision" => "allow",
        "org_id" => context.org.id,
        "project_id" => context.project.id,
        "scope_indices" => scope_indices
      })

    assert html_response(response, 200) =~ ~s(id="device-activation-result-heading")
    assert response.resp_body =~ "Your agent is connected"
    response
  end

  defp deny_in_browser(context, user_code) do
    consent = submit_user_code(context, user_code)

    response =
      consent
      |> recycle()
      |> post("/activate", %{
        "_csrf_token" => Plug.CSRFProtection.get_csrf_token(),
        "decision" => "deny"
      })

    assert html_response(response, 200) =~ ~s(id="device-activation-result-heading")
    assert response.resp_body =~ "Request cancelled"
    response
  end

  defp submit_user_code(context, user_code) do
    response =
      build_conn()
      |> log_in(context.user)
      |> post("/activate", %{
        "_csrf_token" => Plug.CSRFProtection.get_csrf_token(),
        "user_code" => user_code
      })

    assert html_response(response, 200) =~ ~s(id="oauth-consent-heading")
    response
  end

  defp expire_device_codes! do
    Alplus.Repo.query!("UPDATE mcp_oauth_device_codes SET expires_at = $1", [
      DateTime.add(DateTime.utc_now(), -1, :second)
    ])
  end

  defp usable_access_token?(access_token) do
    response =
      build_conn()
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", "2025-11-25")
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> post(
        "/mcp",
        Jason.encode!(%{
          "id" => "device-flow",
          "jsonrpc" => "2.0",
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-11-25",
            "clientInfo" => %{"name" => "device-flow", "version" => "1.0.0"},
            "capabilities" => %{}
          }
        })
      )

    response.status == 200
  end

  defp restore_fetch_opts({:ok, opts}),
    do: Application.put_env(:alplus, :mcp_oauth_metadata_fetch_opts, opts)

  defp restore_fetch_opts(:error),
    do: Application.delete_env(:alplus, :mcp_oauth_metadata_fetch_opts)

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
