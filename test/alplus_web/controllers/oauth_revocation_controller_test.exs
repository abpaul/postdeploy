defmodule AlplusWeb.OAuthRevocationControllerTest.MetadataResolver do
  @address {1, 1, 1, 1}

  def resolve("client.example", _timeout), do: {:ok, [@address]}
  def resolve(_host, _timeout), do: {:error, :nxdomain}
end

defmodule AlplusWeb.OAuthRevocationControllerTest.MetadataHTTPClient do
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

defmodule AlplusWeb.OAuthRevocationControllerTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  @client_id "https://client.example/metadata.json"
  @redirect_uri "https://client.example/oauth/callback"
  @scope "projects:read"
  @state "browser-state"
  @verifier "a-verifier-that-is-long-enough-for-pkce-s256-testing"
  @unrelated_secret "client-metadata-secret-that-must-never-leak"
  @unknown_token "oauth-unknown-token-that-was-never-issued"

  setup do
    previous_fetch_opts = Application.fetch_env(:alplus, :mcp_oauth_metadata_fetch_opts)

    Application.put_env(:alplus, :mcp_oauth_metadata_fetch_opts,
      dns_resolver: AlplusWeb.OAuthRevocationControllerTest.MetadataResolver,
      http_client: AlplusWeb.OAuthRevocationControllerTest.MetadataHTTPClient
    )

    on_exit(fn -> restore_fetch_opts(previous_fetch_opts) end)

    user = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(user.id))
    project = project_fixture(scope, org)
    resource = Alplus.Mcp.OAuth.resource_uri()

    %{
      user: user,
      org: org,
      project: project,
      resource: resource,
      verifier: @verifier,
      challenge: code_challenge(@verifier)
    }
  end

  test "revokes an access token and immediately rejects it at MCP", context do
    tokens = issue_access_token(context.conn, context)
    assert_mcp_authorized(tokens.access_token)

    response = revoke(tokens.access_token, "access_token")

    assert_revocation_response(response, revocation_secrets(tokens, context))
    assert_mcp_unauthorized(tokens.access_token)
  end

  test "revokes a refresh token and immediately rejects the sibling access token at MCP",
       context do
    tokens = issue_tokens(context.conn, context)
    assert is_binary(tokens.access_token)
    assert_mcp_authorized(tokens.access_token)

    response = revoke(tokens.refresh_token, "refresh_token")

    assert_revocation_response(response, revocation_secrets(tokens, context))
    assert_token_error(refresh_grant(tokens.refresh_token, context), "invalid_grant")
    assert_mcp_unauthorized(tokens.access_token)
  end

  test "returns 200 for an unknown token without disclosing whether it existed", context do
    response = revoke(@unknown_token, "access_token")

    assert_revocation_response(
      response,
      [
        @unknown_token,
        context.verifier,
        context.org.id,
        context.project.id,
        @unrelated_secret
      ]
    )
  end

  test "still revokes an access token when token_type_hint names a refresh token", context do
    tokens = issue_access_token(context.conn, context)
    assert_mcp_authorized(tokens.access_token)

    response = revoke(tokens.access_token, "refresh_token")

    assert_revocation_response(response, revocation_secrets(tokens, context))
    assert_mcp_unauthorized(tokens.access_token)
  end

  test "still revokes a refresh token when token_type_hint names an access token", context do
    tokens = issue_tokens(context.conn, context)

    response = revoke(tokens.refresh_token, "access_token")

    assert_revocation_response(response, revocation_secrets(tokens, context))
    assert_token_error(refresh_grant(tokens.refresh_token, context), "invalid_grant")
  end

  test "revokes an access token when token_type_hint is omitted", context do
    tokens = issue_access_token(context.conn, context)
    assert_mcp_authorized(tokens.access_token)

    response = revoke(tokens.access_token)

    assert_revocation_response(response, revocation_secrets(tokens, context))
    assert_mcp_unauthorized(tokens.access_token)
  end

  defp issue_access_token(conn, context) do
    %{code: code} = authorize_code(conn, context)
    response = exchange_code(build_conn(), code, context)

    assert %{"access_token" => access_token} = json_response(response, 200)
    assert is_binary(access_token) and byte_size(access_token) > 0

    %{access_token: access_token, refresh_token: nil, code: code}
  end

  defp issue_tokens(conn, context) do
    %{code: code} = authorize_code(conn, context)
    response = exchange_code(build_conn(), code, context)

    assert %{
             "access_token" => access_token,
             "refresh_token" => refresh_token,
             "token_type" => "Bearer",
             "expires_in" => expires_in,
             "scope" => @scope
           } = json_response(response, 200)

    assert is_binary(access_token) and byte_size(access_token) > 0
    assert is_binary(refresh_token) and byte_size(refresh_token) > 0
    assert access_token != refresh_token
    assert expires_in in 3590..3600

    %{access_token: access_token, refresh_token: refresh_token, code: code}
  end

  defp authorize_code(conn, context) do
    consent =
      conn
      |> log_in(context.user)
      |> get(authorize_path(authorization_params(context)))

    assert consent.status == 200

    csrf = Plug.CSRFProtection.get_csrf_token()

    response =
      consent
      |> recycle()
      |> post("/oauth/authorize", %{
        "_csrf_token" => csrf,
        "decision" => "allow",
        "org_id" => context.org.id,
        "project_id" => context.project.id,
        "scope_indices" => ["0"]
      })

    uri = URI.parse(redirected_to(response))

    assert URI.to_string(%{uri | query: nil, fragment: nil}) == @redirect_uri

    query = uri |> Map.fetch!(:query) |> URI.decode_query()
    assert %{"code" => code, "iss" => issuer, "state" => @state} = query
    assert Map.keys(query) |> MapSet.new() == MapSet.new(~w(code iss state))

    %{code: code, issuer: issuer}
  end

  defp exchange_code(conn, code, context) do
    post(conn, "/oauth/token", token_params(context, code))
  end

  defp refresh_grant(refresh_token, context) do
    post(build_conn(), "/oauth/token", %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => @client_id,
      "resource" => context.resource
    })
  end

  defp revoke(token, hint \\ nil) do
    params = %{"token" => token, "client_id" => @client_id}
    params = if is_binary(hint), do: Map.put(params, "token_type_hint", hint), else: params
    post(build_conn(), "/oauth/revoke", params)
  end

  defp authorization_params(context) do
    %{
      "response_type" => "code",
      "client_id" => @client_id,
      "redirect_uri" => @redirect_uri,
      "scope" => @scope,
      "state" => @state,
      "resource" => context.resource,
      "code_challenge" => context.challenge,
      "code_challenge_method" => "S256"
    }
  end

  defp authorize_path(parameters), do: "/oauth/authorize?" <> URI.encode_query(parameters)

  defp token_params(context, code) do
    %{
      "grant_type" => "authorization_code",
      "code" => code,
      "code_verifier" => context.verifier,
      "redirect_uri" => @redirect_uri,
      "client_id" => @client_id,
      "resource" => context.resource
    }
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp code_challenge(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end

  defp assert_mcp_authorized(access_token) do
    response = mcp_tools_list(access_token)
    assert response.status == 200
  end

  defp assert_mcp_unauthorized(access_token) do
    response = mcp_tools_list(access_token)
    resource_metadata = Alplus.Mcp.OAuth.protected_resource_metadata_uri()

    assert response.status == 401

    assert get_resp_header(response, "www-authenticate") == [
             "Bearer error=\"invalid_token\", resource_metadata=\"#{resource_metadata}\""
           ]
  end

  defp mcp_tools_list(access_token) do
    initialized =
      post_mcp(
        build_conn(),
        "Bearer #{access_token}",
        mcp_request("initialize", %{
          "clientInfo" => %{"name" => "revocation-test", "version" => "1.0.0"},
          "capabilities" => %{}
        }),
        "2025-11-25"
      )

    if initialized.status == 200 do
      [session_id] = get_resp_header(initialized, "mcp-session-id")

      build_conn()
      |> put_req_header("mcp-session-id", session_id)
      |> post_mcp(
        "Bearer #{access_token}",
        mcp_request("tools/list"),
        "2025-11-25"
      )
    else
      initialized
    end
  end

  defp mcp_request(method, params \\ %{}) do
    %{
      "id" => "revocation-#{method}",
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => Map.put(params, "protocolVersion", "2025-11-25")
    }
  end

  defp post_mcp(conn, authorization, body, revision) do
    conn
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-protocol-version", revision)
    |> put_req_header("authorization", authorization)
    |> post("/mcp", Jason.encode!(body))
  end

  defp assert_revocation_response(response, secrets) do
    assert response.status == 200
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get_resp_header(response, "pragma") == ["no-cache"]

    Enum.each(secrets, fn secret ->
      refute response.resp_body =~ to_string(secret)
    end)

    refute response.resp_body =~ "access_token"
    refute response.resp_body =~ "refresh_token"
    refute response.resp_body =~ "token_hash"
    refute response.resp_body =~ "access_token_hash"
    refute response.resp_body =~ "refresh_token_hash"
    refute response.resp_body =~ "client_secret"
    refute response.resp_body =~ "unrelated_secret"
  end

  defp revocation_secrets(tokens, context) do
    [
      tokens.access_token,
      tokens.refresh_token,
      tokens.code,
      context.verifier,
      context.org.id,
      context.project.id,
      @unrelated_secret
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp assert_token_error(response, error) do
    assert response.status == 400
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get_resp_header(response, "pragma") == ["no-cache"]
    assert json_response(response, 400) == %{"error" => error}
    refute response.resp_body =~ "access_token"
    refute response.resp_body =~ "refresh_token"
  end

  defp restore_fetch_opts(:error),
    do: Application.delete_env(:alplus, :mcp_oauth_metadata_fetch_opts)

  defp restore_fetch_opts({:ok, previous}),
    do: Application.put_env(:alplus, :mcp_oauth_metadata_fetch_opts, previous)
end
