defmodule AlplusWeb.OAuthTokenControllerTest.MetadataResolver do
  @address {1, 1, 1, 1}

  def resolve("client.example", _timeout), do: {:ok, [@address]}
  def resolve(_host, _timeout), do: {:error, :nxdomain}
end

defmodule AlplusWeb.OAuthTokenControllerTest.MetadataHTTPClient do
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

defmodule AlplusWeb.OAuthTokenControllerTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  @client_id "https://client.example/metadata.json"
  @other_client_id "https://another-client.example/metadata.json"
  @redirect_uri "https://client.example/oauth/callback"
  @scope "projects:read"
  @widened_scope "projects:read monitor:read"
  @replacement_requested_scope "monitor:write analytics:read monitor:read analytics:read"
  @state "browser-state"
  @verifier "a-verifier-that-is-long-enough-for-pkce-s256-testing"
  @unrelated_secret "client-metadata-secret-that-must-never-leak"
  @unknown_refresh_token "mcorf_unknown-refresh-token-that-was-never-issued"

  setup do
    previous_fetch_opts = Application.fetch_env(:alplus, :mcp_oauth_metadata_fetch_opts)

    Application.put_env(:alplus, :mcp_oauth_metadata_fetch_opts,
      dns_resolver: AlplusWeb.OAuthTokenControllerTest.MetadataResolver,
      http_client: AlplusWeb.OAuthTokenControllerTest.MetadataHTTPClient
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

  test "exchanges an issuer-bound authorization code without disclosing grant or client secrets",
       context do
    %{code: code, issuer: issuer} = authorize_code(context.conn, context)

    response = exchange_code(build_conn(), code, context)

    assert response.status == 200
    assert_token_cache_headers(response)

    assert %{
             "access_token" => access_token,
             "refresh_token" => refresh_token,
             "token_type" => "Bearer",
             "expires_in" => expires_in,
             "scope" => @scope
           } = body = json_response(response, 200)

    assert is_binary(access_token) and byte_size(access_token) > 0
    assert is_binary(refresh_token) and byte_size(refresh_token) > 0
    assert access_token != refresh_token
    assert expires_in in 3590..3600

    assert Map.keys(body) |> MapSet.new() ==
             MapSet.new(~w(access_token refresh_token token_type expires_in scope))

    assert issuer == Alplus.Mcp.OAuth.issuer()

    refute_disclosed(response.resp_body, [
      code,
      context.verifier,
      context.org.id,
      context.project.id,
      @unrelated_secret
    ])

    refute Map.has_key?(body, "code")
    refute Map.has_key?(body, "authorization_code")
    refute Map.has_key?(body, "code_verifier")
    refute Map.has_key?(body, "code_challenge")
    refute Map.has_key?(body, "token_hash")
    refute Map.has_key?(body, "access_token_hash")
    refute Map.has_key?(body, "refresh_token_hash")
    refute Map.has_key?(body, "org_id")
    refute Map.has_key?(body, "project_id")
    refute Map.has_key?(body, "client_secret")
    refute Map.has_key?(body, "unrelated_secret")
  end

  test "authorization-code exchange and refresh preserve the requested canonical scope set",
       context do
    # Unsorted duplicate subset of Scope.all/0. Omits projects:read so a
    # hardcoded initial-scope binding cannot satisfy the token response.
    requested_scope = "monitor:write analytics:read monitor:read analytics:read"
    requested = String.split(requested_scope, " ", trim: true)
    supported = MapSet.new(Alplus.Mcp.Scope.all())

    assert requested != []
    assert Enum.all?(requested, &MapSet.member?(supported, &1))

    canonical_scopes = Enum.filter(Alplus.Mcp.Scope.all(), &(&1 in requested))
    canonical_scope = Enum.join(canonical_scopes, " ")

    refute canonical_scope == @scope
    refute @scope in canonical_scopes
    assert length(canonical_scopes) > 1

    context = Map.put(context, :requested_scope, requested_scope)
    %{code: code} = authorize_code(context.conn, context)

    issued = exchange_code(build_conn(), code, context)

    {issued_body, _access_token, refresh_token} =
      assert_successful_token_response(issued, canonical_scope)

    assert_exact_scope_set(issued_body["scope"], canonical_scopes)

    successor = refresh_tokens(build_conn(), refresh_token, context)

    {successor_body, _successor_access, _successor_refresh} =
      assert_successful_token_response(successor, canonical_scope)

    assert_exact_scope_set(successor_body["scope"], canonical_scopes)
    assert successor_body["scope"] == issued_body["scope"]
  end

  test "authorization-code exchange persists only the permissions selected at consent", context do
    context =
      context
      |> Map.put(:requested_scope, @replacement_requested_scope)
      |> Map.put(:selected_scope_indices, ["0", "2"])

    %{code: code} = authorize_code(context.conn, context)
    response = exchange_code(build_conn(), code, context)
    expected_scopes = ["analytics:read", "monitor:write"]

    {body, access_token, _refresh_token} =
      assert_successful_token_response(response, Enum.join(expected_scopes, " "))

    assert_exact_scope_set(body["scope"], expected_scopes)

    assert {:ok, %{scopes: ^expected_scopes}} =
             Alplus.Mcp.OAuth.authenticate_access_token(access_token)
  end

  test "re-consent replaces the grant scope snapshot and supersedes the prior family", context do
    first_scopes = canonical_scopes(@scope)
    replacement_scopes = canonical_scopes(@replacement_requested_scope)
    replacement_scope = Enum.join(replacement_scopes, " ")

    refute replacement_scope == @scope
    refute @scope in replacement_scopes
    assert first_scopes -- replacement_scopes != []
    assert replacement_scopes -- first_scopes != []

    first = issue_tokens(context.conn, context)
    assert_usable_access_token(first.access_token)
    assert_active_grant_scopes(first_scopes)

    reconsent = Map.put(context, :requested_scope, @replacement_requested_scope)
    replacement = issue_tokens(context.conn, reconsent)

    assert replacement.access_token != first.access_token
    assert replacement.refresh_token != first.refresh_token
    assert_active_grant_scopes(replacement_scopes)

    successor = refresh_tokens(build_conn(), replacement.refresh_token, reconsent)

    {successor_body, successor_access, successor_refresh} =
      assert_successful_token_response(successor, replacement_scope)

    assert_exact_scope_set(successor_body["scope"], replacement_scopes)
    assert_usable_access_token(successor_access)

    assert_invalid_access_token(first.access_token)

    replay = refresh_tokens(build_conn(), first.refresh_token, context)

    assert_token_error(replay, "invalid_grant", [
      first.refresh_token,
      replacement.refresh_token,
      successor_refresh,
      first.access_token,
      replacement.access_token,
      context.org.id,
      context.project.id,
      @unrelated_secret
    ])

    still_live = refresh_tokens(build_conn(), successor_refresh, reconsent)
    assert_successful_token_response(still_live, replacement_scope)
  end

  test "same-scope reauthorization supersedes the prior token family", context do
    first = issue_tokens(context.conn, context)
    assert_usable_access_token(first.access_token)
    assert_active_grant_scopes(canonical_scopes(@scope))

    replacement = issue_tokens(context.conn, context)

    assert replacement.access_token != first.access_token
    assert replacement.refresh_token != first.refresh_token
    assert_usable_access_token(replacement.access_token)
    assert_active_grant_scopes(canonical_scopes(@scope))

    successor = refresh_tokens(build_conn(), replacement.refresh_token, context)

    {_successor_body, successor_access, successor_refresh} =
      assert_successful_token_response(successor)

    assert_usable_access_token(successor_access)

    assert_invalid_access_token(first.access_token)

    replay = refresh_tokens(build_conn(), first.refresh_token, context)

    assert_token_error(replay, "invalid_grant", [
      first.refresh_token,
      replacement.refresh_token,
      successor_refresh,
      first.access_token,
      replacement.access_token,
      context.org.id,
      context.project.id,
      @unrelated_secret
    ])

    still_live = refresh_tokens(build_conn(), successor_refresh, context)
    assert_successful_token_response(still_live)
  end

  test "rejects an authorization-code exchange without a PKCE verifier", context do
    %{code: code} = authorize_code(context.conn, context)

    response =
      exchange_code(build_conn(), code, context, fn params ->
        Map.delete(params, "code_verifier")
      end)

    assert_token_error(response, "invalid_request")
  end

  test "rejects an authorization-code exchange with an invalid PKCE verifier", context do
    %{code: code} = authorize_code(context.conn, context)

    response =
      exchange_code(build_conn(), code, context, fn params ->
        Map.put(params, "code_verifier", "another-verifier-that-is-long-enough-to-be-valid-pkce")
      end)

    assert_token_error(response, "invalid_grant")
  end

  test "rejects an authorization-code exchange with a different redirect URI", context do
    %{code: code} = authorize_code(context.conn, context)

    response =
      exchange_code(build_conn(), code, context, fn params ->
        Map.put(params, "redirect_uri", "https://client.example/another-callback")
      end)

    assert_token_error(response, "invalid_grant")
  end

  test "rejects an authorization-code exchange from a different client", context do
    %{code: code} = authorize_code(context.conn, context)

    response =
      exchange_code(build_conn(), code, context, fn params ->
        Map.put(params, "client_id", @other_client_id)
      end)

    assert_token_error(response, "invalid_grant")
  end

  test "rejects an authorization-code exchange for a different resource", context do
    %{code: code} = authorize_code(context.conn, context)

    response =
      exchange_code(build_conn(), code, context, fn params ->
        Map.put(params, "resource", context.resource <> "/other")
      end)

    assert_token_error(response, "invalid_grant")
  end

  test "rejects an authorization-code exchange without a resource", context do
    %{code: code} = authorize_code(context.conn, context)

    response =
      exchange_code(build_conn(), code, context, fn params ->
        Map.delete(params, "resource")
      end)

    assert_token_error(response, "invalid_request")
  end

  test "rejects an expired authorization code", context do
    %{code: code} = authorize_code(context.conn, context)

    Alplus.Repo.query!("UPDATE mcp_oauth_authorization_codes SET expires_at = $1", [
      DateTime.add(DateTime.utc_now(), -1, :second)
    ])

    assert_token_error(exchange_code(build_conn(), code, context), "invalid_grant")
  end

  test "rejects a previously exchanged authorization code", context do
    %{code: code} = authorize_code(context.conn, context)

    response = exchange_code(build_conn(), code, context)
    assert %{"access_token" => access_token} = json_response(response, 200)
    assert is_binary(access_token) and byte_size(access_token) > 0

    assert_token_error(exchange_code(build_conn(), code, context), "invalid_grant")
  end

  test "rejects an authorization-code exchange when the grant issuer does not match", context do
    %{code: code} = authorize_code(context.conn, context)

    Alplus.Repo.query!("UPDATE mcp_oauth_grants SET issuer = $1", [
      "https://attacker.example"
    ])

    assert_token_error(exchange_code(build_conn(), code, context), "invalid_grant")
  end

  test "refreshes an authorization-code grant without widening or disclosing secrets", context do
    issued = issue_tokens(context.conn, context)

    response = refresh_tokens(build_conn(), issued.refresh_token, context)

    {body, access_token, refresh_token} = assert_successful_token_response(response)

    assert access_token != issued.access_token
    assert refresh_token != issued.refresh_token
    assert body["scope"] == @scope
    assert_usable_access_token(access_token)

    refute_disclosed(response.resp_body, [
      issued.code,
      issued.refresh_token,
      context.verifier,
      context.org.id,
      context.project.id,
      @unrelated_secret
    ])

    refute Map.has_key?(body, "code")
    refute Map.has_key?(body, "authorization_code")
    refute Map.has_key?(body, "code_verifier")
    refute Map.has_key?(body, "token_hash")
    refute Map.has_key?(body, "access_token_hash")
    refute Map.has_key?(body, "refresh_token_hash")
    refute Map.has_key?(body, "org_id")
    refute Map.has_key?(body, "project_id")
    refute Map.has_key?(body, "client_secret")
    refute Map.has_key?(body, "unrelated_secret")
  end

  test "a lost token response recovers inside the reuse grace window", context do
    issued = issue_tokens(context.conn, context)

    lost = refresh_tokens(build_conn(), issued.refresh_token, context)
    {_body, _lost_access_token, lost_refresh_token} = assert_successful_token_response(lost)

    # The client never received the response above. It retries with the only
    # refresh token it still holds.
    retry = refresh_tokens(build_conn(), issued.refresh_token, context)
    {_body, retry_access_token, retry_refresh_token} = assert_successful_token_response(retry)

    assert retry_refresh_token != lost_refresh_token
    assert retry_refresh_token != issued.refresh_token
    assert_usable_access_token(retry_access_token)

    # The recovered pair keeps working, so the connection survives.
    followup = refresh_tokens(build_conn(), retry_refresh_token, context)
    assert_successful_token_response(followup)
  end

  test "replay after the reuse grace window revokes the grant token family", context do
    issued = issue_tokens(context.conn, context)

    rotated = refresh_tokens(build_conn(), issued.refresh_token, context)

    {_body, rotated_access_token, rotated_refresh_token} =
      assert_successful_token_response(rotated)

    assert_usable_access_token(rotated_access_token)
    age_refresh_rotation!(issued.refresh_token, 120)

    replay = refresh_tokens(build_conn(), issued.refresh_token, context)

    assert_token_error(replay, "invalid_grant", [
      issued.refresh_token,
      rotated_refresh_token,
      issued.access_token,
      rotated_access_token,
      context.org.id,
      context.project.id,
      @unrelated_secret
    ])

    successor = refresh_tokens(build_conn(), rotated_refresh_token, context)

    assert_token_error(successor, "invalid_grant", [
      issued.refresh_token,
      rotated_refresh_token,
      @unrelated_secret
    ])

    assert_invalid_access_token(issued.access_token)
    assert_invalid_access_token(rotated_access_token)
  end

  test "replay revokes the family once the client has rotated past the successor", context do
    issued = issue_tokens(context.conn, context)

    first = refresh_tokens(build_conn(), issued.refresh_token, context)
    {_body, _first_access_token, first_refresh_token} = assert_successful_token_response(first)

    second = refresh_tokens(build_conn(), first_refresh_token, context)
    {_body, second_access_token, second_refresh_token} = assert_successful_token_response(second)

    # The successor is spent, so this replay is a fork rather than a retry,
    # even though it arrives inside the grace window.
    replay = refresh_tokens(build_conn(), issued.refresh_token, context)

    assert_token_error(replay, "invalid_grant", [
      issued.refresh_token,
      first_refresh_token,
      second_refresh_token,
      @unrelated_secret
    ])

    assert_invalid_access_token(second_access_token)
  end

  test "rejects a refresh request without a refresh token", context do
    issued = issue_tokens(context.conn, context)

    response =
      refresh_tokens(build_conn(), issued.refresh_token, context, fn params ->
        Map.delete(params, "refresh_token")
      end)

    assert_token_error(response, "invalid_request", [issued.refresh_token, @unrelated_secret])
  end

  test "rejects an expired refresh token without distinguishing the failure", context do
    issued = issue_tokens(context.conn, context)
    expire_refresh_token!(issued.refresh_token)

    response = refresh_tokens(build_conn(), issued.refresh_token, context)

    assert_token_error(response, "invalid_grant", [
      issued.refresh_token,
      issued.access_token,
      context.org.id,
      context.project.id,
      @unrelated_secret
    ])
  end

  test "rejects a revoked refresh token without distinguishing the failure", context do
    issued = issue_tokens(context.conn, context)
    revoke_refresh_token!(issued.refresh_token)

    response = refresh_tokens(build_conn(), issued.refresh_token, context)

    assert_token_error(response, "invalid_grant", [
      issued.refresh_token,
      issued.access_token,
      context.org.id,
      context.project.id,
      @unrelated_secret
    ])
  end

  test "rejects a refresh that widens the resource", context do
    issued = issue_tokens(context.conn, context)

    response =
      refresh_tokens(build_conn(), issued.refresh_token, context, fn params ->
        Map.put(params, "resource", context.resource <> "/other")
      end)

    assert_token_error(response, "invalid_grant", [
      issued.refresh_token,
      context.resource <> "/other",
      @unrelated_secret
    ])
  end

  test "rejects a refresh without a resource", context do
    issued = issue_tokens(context.conn, context)

    response =
      refresh_tokens(build_conn(), issued.refresh_token, context, fn params ->
        Map.delete(params, "resource")
      end)

    assert_token_error(response, "invalid_request", [
      issued.refresh_token,
      @unrelated_secret
    ])
  end

  test "rejects a refresh from a different client", context do
    issued = issue_tokens(context.conn, context)

    response =
      refresh_tokens(build_conn(), issued.refresh_token, context, fn params ->
        Map.put(params, "client_id", @other_client_id)
      end)

    assert_token_error(response, "invalid_grant", [
      issued.refresh_token,
      @other_client_id,
      @unrelated_secret
    ])
  end

  test "rejects a refresh that widens the granted scope", context do
    issued = issue_tokens(context.conn, context)

    response =
      refresh_tokens(build_conn(), issued.refresh_token, context, fn params ->
        Map.put(params, "scope", @widened_scope)
      end)

    assert_token_error(response, "invalid_grant", [
      issued.refresh_token,
      @widened_scope,
      @unrelated_secret
    ])
  end

  test "rejects an unknown refresh token with a minimized no-store error", context do
    response = refresh_tokens(build_conn(), @unknown_refresh_token, context)

    assert_token_error(response, "invalid_grant", [
      @unknown_refresh_token,
      context.org.id,
      context.project.id,
      @unrelated_secret
    ])
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
        "scope_indices" => selected_scope_indices(context)
      })

    uri = URI.parse(redirected_to(response))

    assert URI.to_string(%{uri | query: nil, fragment: nil}) == @redirect_uri

    query = uri |> Map.fetch!(:query) |> URI.decode_query()
    assert %{"code" => code, "iss" => issuer, "state" => @state} = query
    assert Map.keys(query) |> MapSet.new() == MapSet.new(~w(code iss state))

    %{code: code, issuer: issuer}
  end

  defp issue_tokens(conn, context) do
    %{code: code} = authorize_code(conn, context)
    response = exchange_code(build_conn(), code, context)

    expected_scope =
      context
      |> Map.get(:requested_scope, @scope)
      |> canonical_scope_string()

    {_body, access_token, refresh_token} =
      assert_successful_token_response(response, expected_scope)

    %{
      code: code,
      access_token: access_token,
      refresh_token: refresh_token
    }
  end

  defp exchange_code(conn, code, context, transform \\ &Function.identity/1) do
    params =
      context
      |> token_params(code)
      |> transform.()

    post(conn, "/oauth/token", params)
  end

  defp refresh_tokens(conn, refresh_token, context, transform \\ &Function.identity/1) do
    params =
      %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => @client_id,
        "resource" => context.resource
      }
      |> transform.()

    post(conn, "/oauth/token", params)
  end

  defp selected_scope_indices(context) do
    case Map.fetch(context, :selected_scope_indices) do
      {:ok, indices} ->
        indices

      :error ->
        requested =
          context
          |> Map.get(:requested_scope, @scope)
          |> String.split(" ", trim: true)
          |> MapSet.new()

        Alplus.Mcp.Scope.all()
        |> Enum.filter(&MapSet.member?(requested, &1))
        |> Enum.with_index()
        |> Enum.map(fn {_scope, index} -> Integer.to_string(index) end)
    end
  end

  defp authorization_params(context) do
    %{
      "response_type" => "code",
      "client_id" => @client_id,
      "redirect_uri" => @redirect_uri,
      "scope" => Map.get(context, :requested_scope, @scope),
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

  defp expire_refresh_token!(refresh_token) do
    assert %{num_rows: 1} =
             Alplus.Repo.query!(
               "UPDATE mcp_oauth_refresh_tokens SET expires_at = $1 WHERE token_hash = $2",
               [
                 DateTime.add(DateTime.utc_now(), -1, :second),
                 Alplus.Security.BearerToken.hash(refresh_token)
               ]
             )
  end

  defp revoke_refresh_token!(refresh_token) do
    assert %{num_rows: 1} =
             Alplus.Repo.query!(
               "UPDATE mcp_oauth_refresh_tokens SET revoked_at = $1 WHERE token_hash = $2",
               [DateTime.utc_now(), Alplus.Security.BearerToken.hash(refresh_token)]
             )
  end

  defp age_refresh_rotation!(refresh_token, seconds) do
    assert %{num_rows: 1} =
             Alplus.Repo.query!(
               "UPDATE mcp_oauth_refresh_tokens SET rotated_at = $1 WHERE token_hash = $2",
               [
                 DateTime.add(DateTime.utc_now(), -seconds, :second),
                 Alplus.Security.BearerToken.hash(refresh_token)
               ]
             )
  end

  defp mcp_initialize(access_token) do
    build_conn()
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-protocol-version", "2025-11-25")
    |> put_req_header("authorization", "Bearer #{access_token}")
    |> post(
      "/mcp",
      Jason.encode!(%{
        "id" => "refresh-lifecycle",
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "clientInfo" => %{"name" => "refresh-lifecycle", "version" => "1.0.0"},
          "capabilities" => %{}
        }
      })
    )
  end

  defp assert_usable_access_token(access_token) do
    response = mcp_initialize(access_token)
    assert response.status == 200
  end

  defp assert_invalid_access_token(access_token) do
    response = mcp_initialize(access_token)
    resource_metadata = Alplus.Mcp.OAuth.protected_resource_metadata_uri()

    assert response.status == 401

    assert get_resp_header(response, "www-authenticate") == [
             "Bearer error=\"invalid_token\", resource_metadata=\"#{resource_metadata}\""
           ]
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

  defp assert_successful_token_response(response, expected_scope \\ @scope) do
    assert response.status == 200
    assert_token_cache_headers(response)

    assert %{
             "access_token" => access_token,
             "refresh_token" => refresh_token,
             "token_type" => "Bearer",
             "expires_in" => expires_in,
             "scope" => ^expected_scope
           } = body = json_response(response, 200)

    assert is_binary(access_token) and byte_size(access_token) > 0
    assert is_binary(refresh_token) and byte_size(refresh_token) > 0
    assert access_token != refresh_token
    assert expires_in in 3590..3600

    assert Map.keys(body) |> MapSet.new() ==
             MapSet.new(~w(access_token refresh_token token_type expires_in scope))

    {body, access_token, refresh_token}
  end

  defp assert_exact_scope_set(scope, canonical_scopes) when is_binary(scope) do
    granted = String.split(scope, " ", trim: true)

    assert granted == canonical_scopes
    assert MapSet.new(granted) == MapSet.new(canonical_scopes)

    extras =
      MapSet.difference(MapSet.new(Alplus.Mcp.Scope.all()), MapSet.new(canonical_scopes))

    Enum.each(extras, fn extra ->
      refute extra in granted
    end)
  end

  defp canonical_scopes(requested_scope) when is_binary(requested_scope) do
    requested = String.split(requested_scope, " ", trim: true)
    supported = MapSet.new(Alplus.Mcp.Scope.all())

    assert requested != []
    assert Enum.all?(requested, &MapSet.member?(supported, &1))

    Enum.filter(Alplus.Mcp.Scope.all(), &(&1 in requested))
  end

  defp canonical_scope_string(requested_scope) do
    requested_scope |> canonical_scopes() |> Enum.join(" ")
  end

  defp assert_active_grant_scopes(canonical_scopes) do
    assert %{rows: [[scopes]], num_rows: 1} =
             Alplus.Repo.query!("SELECT scopes FROM mcp_oauth_grants WHERE revoked_at IS NULL")

    assert scopes == canonical_scopes
  end

  defp assert_token_error(response, error, extras \\ []) do
    assert response.status == 400
    assert_token_cache_headers(response)
    assert json_response(response, 400) == %{"error" => error}
    refute response.resp_body =~ "access_token"
    refute response.resp_body =~ "refresh_token"
    refute_disclosed(response.resp_body, extras)
  end

  defp assert_token_cache_headers(response) do
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get_resp_header(response, "pragma") == ["no-cache"]
  end

  defp refute_disclosed(body, values) do
    Enum.each(values, fn value ->
      refute body =~ value
    end)
  end

  defp restore_fetch_opts(:error),
    do: Application.delete_env(:alplus, :mcp_oauth_metadata_fetch_opts)

  defp restore_fetch_opts({:ok, previous}),
    do: Application.put_env(:alplus, :mcp_oauth_metadata_fetch_opts, previous)
end
