defmodule AlplusWeb.McpEndpointTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Mcp
  alias Alplus.Mcp.{OAuth, Scope}

  defmodule OAuthMetadataDNSResolver do
    def resolve("client.example", _timeout_ms), do: {:ok, [{93, 184, 216, 34}]}
    def resolve(_host, _timeout_ms), do: {:error, :nxdomain}
  end

  defmodule OAuthMetadataHTTPClient do
    def get(_uri, _address, _opts) do
      {:ok,
       %{
         status: 200,
         headers: [],
         body:
           Jason.encode!(%{
             "client_id" => "https://client.example/metadata.json",
             "client_name" => "MCP endpoint test client",
             "redirect_uris" => ["https://client.example/oauth/callback"]
           })
       }}
    end
  end

  setup do
    user = user_fixture()
    {org, scope} = org_fixture(scope_fixture(%{user: user}))
    project = project_fixture(scope, org, %{name: "MCP Project"})
    actor = Alplus.Scope.put_project(scope, project.id)
    {grant, token} = issue_access_token(actor, read_scopes())

    %{
      conn: build_conn(),
      org: org,
      scope: scope,
      actor: actor,
      user: user,
      project: project,
      grant: grant,
      token: token
    }
  end

  test "challenges a request with no Authorization without an OAuth error", %{conn: conn} do
    response = post_mcp(conn, nil, request("tools/list"), "2025-11-25")
    resource_metadata = "#{AlplusWeb.Endpoint.url()}/.well-known/oauth-protected-resource/mcp"

    assert response.status == 401

    assert get_resp_header(response, "www-authenticate") == [
             "Bearer resource_metadata=\"#{resource_metadata}\""
           ]
  end

  test "challenges malformed, unknown, revoked, and expired Bearer credentials as invalid tokens",
       %{
         grant: grant,
         actor: actor,
         token: token,
         user: user,
         org: org,
         project: project
       } do
    resource_metadata = "#{AlplusWeb.Endpoint.url()}/.well-known/oauth-protected-resource/mcp"

    invalid_token_challenge =
      "Bearer error=\"invalid_token\", resource_metadata=\"#{resource_metadata}\""

    malformed = post_mcp(build_conn(), "Bearer", request("tools/list"), "2025-11-25")

    assert malformed.status == 401
    assert get_resp_header(malformed, "www-authenticate") == [invalid_token_challenge]

    for legacy <- [
          "mcred_unknown",
          "mcred_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        ] do
      unknown =
        post_mcp(build_conn(), "Bearer #{legacy}", request("tools/list"), "2025-11-25")

      assert unknown.status == 401
      assert get_resp_header(unknown, "www-authenticate") == [invalid_token_challenge]
    end

    assert {:ok, _} = Mcp.revoke_oauth_grant(grant, actor: actor)

    revoked =
      post_mcp(build_conn(), "Bearer #{token}", request("tools/list"), "2025-11-25")

    assert revoked.status == 401
    assert get_resp_header(revoked, "www-authenticate") == [invalid_token_challenge]

    configure_oauth_metadata_fetch!()
    code_grant = issue_oauth_code(user, org, project)
    token_response = exchange_oauth_code(code_grant)
    access_token = Jason.decode!(token_response.resp_body)["access_token"]

    assert token_response.status == 200
    assert is_binary(access_token) and access_token != ""
    refute String.starts_with?(access_token, "mcred_")

    assert %{num_rows: 1} =
             Alplus.Repo.query!(
               "UPDATE mcp_oauth_access_tokens SET expires_at = $1 WHERE token_hash = $2",
               [
                 DateTime.add(DateTime.utc_now(), -1, :second),
                 Alplus.Security.BearerToken.hash(access_token)
               ]
             )

    expired =
      post_mcp(build_conn(), "Bearer #{access_token}", request("tools/list"), "2025-11-25")

    assert expired.status == 401
    assert get_resp_header(expired, "www-authenticate") == [invalid_token_challenge]
  end

  test "legacy mcred tokens never authenticate through the mounted route" do
    resource_metadata = "#{AlplusWeb.Endpoint.url()}/.well-known/oauth-protected-resource/mcp"

    invalid_token_challenge =
      "Bearer error=\"invalid_token\", resource_metadata=\"#{resource_metadata}\""

    for token <- [
          "mcred_unknown",
          "mcred_" <> String.duplicate("a", 32)
        ] do
      response = post_mcp(build_conn(), "Bearer #{token}", request("tools/list"), "2025-11-25")

      assert response.status == 401
      assert get_resp_header(response, "www-authenticate") == [invalid_token_challenge]
    end
  end

  test "rejects a token after the grant issuer is mutated", %{
    conn: conn,
    token: token,
    grant: grant
  } do
    resource_metadata = "#{AlplusWeb.Endpoint.url()}/.well-known/oauth-protected-resource/mcp"

    assert %{num_rows: 1} =
             Alplus.Repo.query!(
               "UPDATE mcp_oauth_grants SET issuer = $1 WHERE id = $2",
               ["https://attacker.example", grant.id]
             )

    response = post_mcp(conn, "Bearer #{token}", request("tools/list"), "2025-11-25")

    assert response.status == 401

    assert get_resp_header(response, "www-authenticate") == [
             "Bearer error=\"invalid_token\", resource_metadata=\"#{resource_metadata}\""
           ]
  end

  test "rejects a query token with an invalid-token challenge", %{conn: conn, token: token} do
    response =
      post_mcp(
        conn,
        "Bearer #{token}",
        request("tools/list"),
        "2025-11-25",
        "/mcp?access_token=#{URI.encode_www_form(token)}"
      )

    resource_metadata = "#{AlplusWeb.Endpoint.url()}/.well-known/oauth-protected-resource/mcp"

    assert response.status == 401

    assert get_resp_header(response, "www-authenticate") == [
             "Bearer error=\"invalid_token\", resource_metadata=\"#{resource_metadata}\""
           ]
  end

  test "uses the configured origin allowlist", %{token: token} do
    previous = Application.get_env(:alplus, :mcp_allowed_origins)
    Application.put_env(:alplus, :mcp_allowed_origins, ["http://localhost"])
    on_exit(fn -> Application.put_env(:alplus, :mcp_allowed_origins, previous) end)

    allowed =
      build_conn()
      |> put_req_header("origin", "http://localhost")
      |> post_mcp(
        "Bearer #{token}",
        request("initialize", "2025-11-25", %{
          "clientInfo" => %{"name" => "origin-test", "version" => "1.0.0"},
          "capabilities" => %{}
        }),
        "2025-11-25"
      )

    assert allowed.status == 200

    refused =
      build_conn()
      |> put_req_header("origin", "https://untrusted.example")
      |> post_mcp("Bearer #{token}", request("tools/list"), "2025-11-25")

    assert refused.status == 403
  end

  test "applies the production origin matrix", %{token: token} do
    previous = Application.get_env(:alplus, :mcp_allowed_origins)
    Application.put_env(:alplus, :mcp_allowed_origins, ["https://postdeploy.dev"])
    on_exit(fn -> Application.put_env(:alplus, :mcp_allowed_origins, previous) end)

    for {origin, expected_status} <- [
          {"https://postdeploy.dev", 200},
          {"http://localhost", 403},
          {"https://malicious.example", 403},
          {nil, 200}
        ] do
      conn = build_conn()
      conn = if origin, do: put_req_header(conn, "origin", origin), else: conn

      response =
        post_mcp(
          conn,
          "Bearer #{token}",
          request("initialize", "2025-11-25", %{
            "clientInfo" => %{"name" => "origin-matrix", "version" => "1.0.0"},
            "capabilities" => %{}
          }),
          "2025-11-25"
        )

      assert response.status == expected_status
    end
  end

  test "reads origin allowlist changes at request time", %{token: token} do
    previous = Application.get_env(:alplus, :mcp_allowed_origins)
    Application.put_env(:alplus, :mcp_allowed_origins, ["https://runtime.example"])

    on_exit(fn ->
      Application.put_env(:alplus, :mcp_allowed_origins, previous)
    end)

    allowed =
      build_conn()
      |> put_req_header("origin", "https://runtime.example")
      |> post_mcp(
        "Bearer #{token}",
        request("initialize", "2025-11-25", %{
          "clientInfo" => %{"name" => "runtime-origin-test", "version" => "1.0.0"},
          "capabilities" => %{}
        }),
        "2025-11-25"
      )

    assert allowed.status == 200

    refused =
      build_conn()
      |> put_req_header("origin", "http://localhost")
      |> post_mcp("Bearer #{token}", request("tools/list"), "2025-11-25")

    assert refused.status == 403
  end

  test "negotiates legacy initialize and modern discovery", %{token: token} do
    legacy =
      post_mcp(
        build_conn(),
        "Bearer #{token}",
        request("initialize", "2025-11-25", %{
          "clientInfo" => %{"name" => "boundary-test", "version" => "1.0.0"},
          "capabilities" => %{}
        }),
        "2025-11-25"
      )

    assert legacy.status == 200
    assert legacy.resp_body =~ "2025-11-25"

    discovery =
      post_mcp(
        build_conn(),
        "Bearer #{token}",
        request("server/discover", "2026-07-28"),
        "2026-07-28"
      )

    assert discovery.status == 200

    # Decode rather than match a substring. A 2026-07-28 client learns the
    # capability set from discovery, not from initialize, so an empty
    # capabilities object makes every tool invisible to it while tools/list
    # still answers correctly. A substring check passed straight through that.
    result = Jason.decode!(discovery.resp_body)["result"]

    assert "2026-07-28" in result["supportedVersions"]
    assert result["capabilities"]["tools"] == %{}

    modern_initialize =
      post_mcp(build_conn(), "Bearer #{token}", request("initialize", "2026-07-28"), "2026-07-28")

    assert modern_initialize.status == 404
    assert modern_initialize.resp_body =~ "-32601"
  end

  test "advertises and serves every gateway tool through the mounted route", %{token: token} do
    initialized =
      post_mcp(
        build_conn(),
        "Bearer #{token}",
        request("initialize", "2025-11-25", %{
          "clientInfo" => %{"name" => "tools-test", "version" => "1.0.0"},
          "capabilities" => %{}
        }),
        "2025-11-25"
      )

    body = Jason.decode!(initialized.resp_body)
    assert get_in(body, ["result", "capabilities", "tools"]) == %{}
    [session_id] = get_resp_header(initialized, "mcp-session-id")

    listed =
      build_conn()
      |> put_req_header("mcp-session-id", session_id)
      |> post_mcp("Bearer #{token}", request("tools/list"), "2025-11-25")

    listed_body = Jason.decode!(listed.resp_body)
    tools = get_in(listed_body, ["result", "tools"])

    assert Enum.map(tools, & &1["name"]) == gateway_tool_names()
    refute Enum.any?(tools, &String.contains?(&1["name"], ".list"))

    # A successful tool result is an envelope, not the domain map. `content`
    # must be an array or a spec-conformant client rejects the call outright.
    # Returning the domain fields directly made the official TypeScript client
    # fail every successful call with "expected array path content received
    # undefined", and no test caught it.
    called =
      build_conn()
      |> put_req_header("mcp-session-id", session_id)
      |> post_mcp(
        "Bearer #{token}",
        request("tools/call", "2025-11-25", %{
          "name" => "actions.read",
          "arguments" => %{"action" => "projects.list", "arguments" => %{}}
        }),
        "2025-11-25"
      )

    result = Jason.decode!(called.resp_body)["result"]

    assert called.status == 200
    assert is_list(result["content"])
    assert [%{"type" => "text"} | _] = result["content"]
    assert result["isError"] == false
    assert is_map(result["structuredContent"])
    assert get_in(result, ["structuredContent", "result", "projects"]) != nil
  end

  test "encodes gateway errors in the legacy content text", %{token: token} do
    initialized =
      post_mcp(
        build_conn(),
        "Bearer #{token}",
        request("initialize", "2025-11-25", %{
          "clientInfo" => %{"name" => "legacy-error-test", "version" => "1.0.0"},
          "capabilities" => %{}
        }),
        "2025-11-25"
      )

    [session_id] = get_resp_header(initialized, "mcp-session-id")

    called =
      build_conn()
      |> put_req_header("mcp-session-id", session_id)
      |> post_mcp(
        "Bearer #{token}",
        request("tools/call", "2025-11-25", %{
          "name" => "actions.read",
          "arguments" => %{"action" => "missing.action", "arguments" => %{}}
        }),
        "2025-11-25"
      )

    result = Jason.decode!(called.resp_body)["result"]
    [text_content] = result["content"]
    content_error = Jason.decode!(text_content["text"])

    assert called.status == 200
    assert result["isError"] == true
    assert content_error["error"]["code"] == "not_found"
    assert result["structuredContent"]["error"]["code"] == "not_found"
  end

  test "returns method not found for an unknown mounted method", %{token: token} do
    initialized =
      post_mcp(
        build_conn(),
        "Bearer #{token}",
        request("initialize", "2025-11-25", %{
          "clientInfo" => %{"name" => "unknown-test", "version" => "1.0.0"},
          "capabilities" => %{}
        }),
        "2025-11-25"
      )

    [session_id] = get_resp_header(initialized, "mcp-session-id")

    response =
      build_conn()
      |> put_req_header("mcp-session-id", session_id)
      |> post_mcp(
        "Bearer #{token}",
        request("method/that/does/not/exist"),
        "2025-11-25"
      )

    assert response.status == 200
    assert Jason.decode!(response.resp_body)["error"]["code"] == -32_601
  end

  test "an OAuth authorization-code bearer reads only its granted project and resource", %{
    user: user,
    org: org,
    scope: scope,
    project: project
  } do
    configure_oauth_metadata_fetch!()
    resource = oauth_resource()

    grant = issue_oauth_code(user, org, project)
    token_response = exchange_oauth_code(grant)
    token_body = Jason.decode!(token_response.resp_body)
    access_token = token_body["access_token"]

    assert token_response.status == 200
    assert is_binary(access_token) and access_token != ""
    refute String.starts_with?(access_token, "mcred_")
    assert token_body["token_type"] == "Bearer"
    assert is_integer(token_body["expires_in"]) and token_body["expires_in"] > 0
    assert token_body["scope"] == "projects:read"
    refute Map.has_key?(token_body, "code")
    refute Map.has_key?(token_body, "code_verifier")
    refute Map.has_key?(token_body, "code_challenge")

    initialized = initialize(build_conn(), access_token)
    assert initialized.status == 200
    [session_id] = get_resp_header(initialized, "mcp-session-id")

    sibling = project_fixture(scope, org, %{name: "OAuth sibling"})

    granted_read =
      call_tool(build_conn(), access_token, session_id, "actions.read", %{
        "action" => "projects.list",
        "arguments" => %{}
      })

    assert granted_read.status == 200
    assert get_in(Jason.decode!(granted_read.resp_body), ["result", "isError"]) == false

    handles =
      granted_read.resp_body
      |> Jason.decode!()
      |> get_in(["result", "structuredContent", "result", "projects"])
      |> Enum.map(& &1["handle"])

    assert handles == [project.id]
    refute sibling.id in handles

    assert_oauth_activity_touched!(access_token)

    wrong_resource =
      issue_oauth_code(user, org, project)
      |> exchange_oauth_code(resource <> "/other")

    wrong_resource_body = Jason.decode!(wrong_resource.resp_body)
    assert wrong_resource.status == 400
    assert wrong_resource_body["error"] == "invalid_grant"
    refute Map.has_key?(wrong_resource_body, "access_token")
  end

  test "OAuth consent refuses foreign organization and project selections", %{
    user: user,
    org: org
  } do
    configure_oauth_metadata_fetch!()

    {foreign_org, foreign_scope} = org_fixture(scope_fixture())
    foreign_project = project_fixture(foreign_scope, foreign_org)

    for {org_id, project_id} <- [
          {foreign_org.id, foreign_project.id},
          {org.id, foreign_project.id}
        ] do
      verifier = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)

      authorization =
        build_conn()
        |> log_in(user)
        |> get(
          "/oauth/authorize?" <>
            URI.encode_query(%{
              "response_type" => "code",
              "client_id" => "https://client.example/metadata.json",
              "redirect_uri" => "https://client.example/oauth/callback",
              "scope" => "projects:read",
              "state" => "mcp-endpoint-state",
              "resource" => oauth_resource(),
              "code_challenge" => pkce_challenge(verifier),
              "code_challenge_method" => "S256"
            })
        )

      assert authorization.status == 200
      csrf = Plug.CSRFProtection.get_csrf_token()

      denied =
        authorization
        |> recycle()
        |> put_req_header("x-csrf-token", csrf)
        |> post("/oauth/authorize", %{
          "decision" => "allow",
          "org_id" => org_id,
          "project_id" => project_id,
          "scope_indices" => ["0"]
        })

      assert denied.status == 200

      assert html_response(denied, 200) =~
               "Choose a project that belongs to the selected organization."

      assert get_resp_header(denied, "location") == []
      refute denied.resp_body =~ "code="
    end
  end

  test "modern discovery and tools/list expose only gateway names", %{token: token} do
    discovery =
      post_mcp(
        build_conn(),
        "Bearer #{token}",
        request("server/discover", "2026-07-28"),
        "2026-07-28"
      )

    assert discovery.status == 200
    result = Jason.decode!(discovery.resp_body)["result"]
    assert "2026-07-28" in result["supportedVersions"]
    assert result["capabilities"]["tools"] == %{}

    listed =
      post_mcp(
        build_conn(),
        "Bearer #{token}",
        request("tools/list", "2026-07-28"),
        "2026-07-28"
      )

    assert listed.status == 200

    assert get_in(Jason.decode!(listed.resp_body), ["result", "tools"])
           |> Enum.map(& &1["name"]) == Enum.sort(gateway_tool_names())

    refute secret_present?(listed.resp_body, token)
  end

  test "resource discovery returns empty lists", %{token: token} do
    initialized = initialize(build_conn(), token)
    assert initialized.status == 200
    [session_id] = get_resp_header(initialized, "mcp-session-id")

    for {method, result_key} <- [
          {"resources/list", "resources"},
          {"resources/templates/list", "resourceTemplates"}
        ] do
      response =
        build_conn()
        |> put_req_header("mcp-session-id", session_id)
        |> post_mcp("Bearer #{token}", request(method), "2025-11-25")

      assert response.status == 200, response.resp_body
      assert get_in(Jason.decode!(response.resp_body), ["result", result_key]) == []
    end
  end

  defp gateway_tool_names do
    ~w(context.get actions.search actions.get actions.read actions.write actions.publish actions.destroy confirmations.get)
  end

  defp read_scopes do
    Enum.filter(Scope.all(), &String.ends_with?(&1, ":read"))
  end

  defp issue_access_token(actor, scopes) do
    {:ok, client} = cache_client!()

    {:ok, grant} =
      Mcp.authorize_oauth_grant(
        %{
          org_id: actor.org_id,
          project_id: actor.project_id,
          user_id: actor.user_id,
          oauth_client_id: client.id,
          issuer: OAuth.issuer(),
          resource: OAuth.resource_uri(),
          scopes: scopes
        },
        actor: actor
      )

    {:ok, access_token} =
      Mcp.issue_oauth_access_token(
        %{
          grant_id: grant.id,
          resource: OAuth.resource_uri(),
          scopes: scopes
        },
        authorize?: false
      )

    token = Ash.Resource.get_metadata(access_token, :token)
    assert is_binary(token) and token != ""
    refute String.starts_with?(token, "mcred_")
    {grant, token}
  end

  defp cache_client! do
    now = DateTime.utc_now()

    Mcp.cache_oauth_client(
      %{
        issuer: OAuth.issuer(),
        client_id:
          "https://client.example/mcp-endpoint-#{System.unique_integer([:positive])}.json",
        client_name: "MCP endpoint test client",
        redirect_uris: ["https://client.example/oauth/callback"],
        fetched_at: now,
        expires_at: DateTime.add(now, 3600, :second)
      },
      authorize?: false
    )
  end

  defp configure_oauth_metadata_fetch! do
    previous = Application.get_env(:alplus, :mcp_oauth_metadata_fetch_opts)

    Application.put_env(:alplus, :mcp_oauth_metadata_fetch_opts,
      dns_resolver: OAuthMetadataDNSResolver,
      http_client: OAuthMetadataHTTPClient
    )

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:alplus, :mcp_oauth_metadata_fetch_opts)
      else
        Application.put_env(:alplus, :mcp_oauth_metadata_fetch_opts, previous)
      end
    end)
  end

  defp issue_oauth_code(user, org, project, scope \\ "projects:read") do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)

    authorization =
      build_conn()
      |> log_in(user)
      |> get(
        "/oauth/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => "https://client.example/metadata.json",
            "redirect_uri" => "https://client.example/oauth/callback",
            "scope" => scope,
            "state" => "mcp-endpoint-state",
            "resource" => oauth_resource(),
            "code_challenge" => pkce_challenge(verifier),
            "code_challenge_method" => "S256"
          })
      )

    assert authorization.status == 200
    csrf = Plug.CSRFProtection.get_csrf_token()

    approved =
      authorization
      |> recycle()
      |> put_req_header("x-csrf-token", csrf)
      |> post("/oauth/authorize", %{
        "decision" => "allow",
        "org_id" => org.id,
        "project_id" => project.id,
        "scope_indices" =>
          scope
          |> String.split(" ", trim: true)
          |> Enum.uniq()
          |> Enum.with_index()
          |> Enum.map(fn {_scope, index} -> Integer.to_string(index) end)
      })

    assert approved.status == 302

    query = oauth_callback_query(approved)

    assert query["iss"] == Alplus.Mcp.OAuth.issuer()
    assert query["state"] == "mcp-endpoint-state"
    assert is_binary(query["code"]) and query["code"] != ""

    %{code: query["code"], verifier: verifier}
  end

  defp oauth_callback_query(response) do
    uri = response |> redirected_to() |> URI.parse()

    assert URI.to_string(%{uri | query: nil, fragment: nil}) ==
             "https://client.example/oauth/callback"

    assert is_binary(uri.query)
    URI.decode_query(uri.query)
  end

  defp exchange_oauth_code(%{code: code, verifier: verifier}, resource \\ oauth_resource()) do
    post(build_conn(), "/oauth/token", %{
      "grant_type" => "authorization_code",
      "code" => code,
      "code_verifier" => verifier,
      "redirect_uri" => "https://client.example/oauth/callback",
      "client_id" => "https://client.example/metadata.json",
      "resource" => resource
    })
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp pkce_challenge(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end

  defp oauth_resource, do: Alplus.Mcp.OAuth.resource_uri()

  defp assert_oauth_activity_touched!(access_token) do
    %{rows: [[token_last_used, grant_last_used]]} =
      Alplus.Repo.query!(
        """
        SELECT tokens.last_used_at, grants.last_used_at
        FROM mcp_oauth_access_tokens AS tokens
        INNER JOIN mcp_oauth_grants AS grants ON grants.id = tokens.grant_id
        WHERE tokens.token_hash = $1
        """,
        [Alplus.Security.BearerToken.hash(access_token)]
      )

    assert token_last_used
    assert grant_last_used
  end

  defp initialize(conn, token) do
    post_mcp(
      conn,
      "Bearer #{token}",
      request("initialize", "2025-11-25", %{
        "clientInfo" => %{"name" => "rate-test", "version" => "1.0.0"},
        "capabilities" => %{}
      }),
      "2025-11-25"
    )
  end

  defp call_tool(conn, token, session_id, name, arguments) do
    body =
      request("tools/call", "2025-11-25", %{"name" => name, "arguments" => arguments})
      |> Map.put("id", "call-#{System.unique_integer([:positive])}")

    conn
    |> put_req_header("mcp-session-id", session_id)
    |> post_mcp("Bearer #{token}", body, "2025-11-25")
  end

  defp secret_present?(body, secret), do: String.contains?(body, secret)

  defp request(method, revision \\ "2025-11-25", params \\ %{}) do
    params =
      params
      |> Map.put("protocolVersion", revision)
      |> modern_metadata(revision)

    %{
      "id" => "endpoint-#{method}",
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params
    }
  end

  defp modern_metadata(params, "2026-07-28") do
    Map.put(params, "_meta", %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{},
      "io.modelcontextprotocol/clientInfo" => %{"name" => "boundary-test", "version" => "1.0.0"}
    })
  end

  defp modern_metadata(params, _revision), do: params

  defp post_mcp(conn, authorization, body, revision, path \\ "/mcp") do
    conn =
      conn
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", revision)

    conn =
      if revision == "2026-07-28",
        do: put_req_header(conn, "mcp-method", body["method"]),
        else: conn

    conn = if authorization, do: put_req_header(conn, "authorization", authorization), else: conn
    post(conn, path, Jason.encode!(body))
  end
end
