defmodule AlplusWeb.OAuthAuthorizationControllerTest.MetadataResolver do
  @address {1, 1, 1, 1}

  def resolve("client.example", _timeout), do: {:ok, [@address]}
  def resolve("private.example", _timeout), do: {:ok, [{127, 0, 0, 1}]}

  def resolve(_host, _timeout), do: {:error, :nxdomain}
end

defmodule AlplusWeb.OAuthAuthorizationControllerTest.MetadataHTTPClient do
  @client_id "https://client.example/metadata.json"
  @redirect_uri "https://client.example/oauth/callback"
  @unrelated_secret "client-metadata-secret-that-must-never-leak"
  @loopback_client_id "https://client.example/loopback-metadata.json"
  @loopback_redirect_uri "http://localhost:49875/oauth/callback"
  @non_loopback_client_id "https://client.example/non-loopback-metadata.json"
  @non_loopback_redirect_uri "http://client.example/oauth/callback"
  @loopback_v4_client_id "https://client.example/loopback-v4-metadata.json"
  @loopback_v4_redirect_uri "http://127.0.0.1/oauth/callback"
  @loopback_v6_client_id "https://client.example/loopback-v6-metadata.json"
  @loopback_v6_redirect_uri "http://[::1]:49875/oauth/callback"
  @userinfo_client_id "https://client.example/userinfo-metadata.json"
  @userinfo_redirect_uri "https://user@client.example/oauth/callback"
  @fragment_client_id "https://client.example/fragment-metadata.json"
  @fragment_redirect_uri "https://client.example/oauth/callback#frag"

  def get(
        %URI{scheme: "https", host: "client.example", path: "/impersonation-metadata.json"},
        {1, 1, 1, 1},
        _opts
      ) do
    body =
      Jason.encode!(%{
        "client_id" => "https://attacker.example/metadata.json",
        "client_name" => "Impersonating MCP client",
        "redirect_uris" => ["https://attacker.example/oauth/callback"]
      })

    {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: body}}
  end

  def get(
        %URI{scheme: "https", host: "client.example", path: "/loopback-v4-metadata.json"},
        {1, 1, 1, 1},
        _opts
      ) do
    body =
      Jason.encode!(%{
        "client_id" => @loopback_v4_client_id,
        "client_name" => "PostDeploy MCP IPv4 loopback client",
        "redirect_uris" => [@loopback_v4_redirect_uri]
      })

    {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: body}}
  end

  def get(
        %URI{scheme: "https", host: "client.example", path: "/loopback-v6-metadata.json"},
        {1, 1, 1, 1},
        _opts
      ) do
    body =
      Jason.encode!(%{
        "client_id" => @loopback_v6_client_id,
        "client_name" => "PostDeploy MCP IPv6 loopback client",
        "redirect_uris" => [@loopback_v6_redirect_uri]
      })

    {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: body}}
  end

  def get(
        %URI{scheme: "https", host: "client.example", path: "/userinfo-metadata.json"},
        {1, 1, 1, 1},
        _opts
      ) do
    body =
      Jason.encode!(%{
        "client_id" => @userinfo_client_id,
        "client_name" => "PostDeploy MCP userinfo client",
        "redirect_uris" => [@userinfo_redirect_uri]
      })

    {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: body}}
  end

  def get(
        %URI{scheme: "https", host: "client.example", path: "/fragment-metadata.json"},
        {1, 1, 1, 1},
        _opts
      ) do
    body =
      Jason.encode!(%{
        "client_id" => @fragment_client_id,
        "client_name" => "PostDeploy MCP fragment client",
        "redirect_uris" => [@fragment_redirect_uri]
      })

    {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: body}}
  end

  def get(%URI{host: "private.example"}, _address, _opts) do
    {:error, :ssrf}
  end

  def get(
        %URI{scheme: "https", host: "client.example", path: "/loopback-metadata.json"},
        {1, 1, 1, 1},
        _opts
      ) do
    body =
      Jason.encode!(%{
        "client_id" => @loopback_client_id,
        "client_name" => "PostDeploy MCP loopback test client",
        "redirect_uris" => [@loopback_redirect_uri]
      })

    {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: body}}
  end

  def get(
        %URI{scheme: "https", host: "client.example", path: "/non-loopback-metadata.json"},
        {1, 1, 1, 1},
        _opts
      ) do
    body =
      Jason.encode!(%{
        "client_id" => @non_loopback_client_id,
        "client_name" => "PostDeploy MCP non-loopback test client",
        "redirect_uris" => [@non_loopback_redirect_uri]
      })

    {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: body}}
  end

  def get(
        %URI{scheme: "https", host: "client.example", path: "/metadata.json"},
        {1, 1, 1, 1},
        _opts
      ) do
    body =
      Jason.encode!(%{
        "client_id" => @client_id,
        "client_name" => "PostDeploy MCP test client",
        "redirect_uris" => [@redirect_uri],
        "unrelated_secret" => @unrelated_secret
      })

    {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: body}}
  end

  def get(_uri, _address, _opts), do: {:error, :unexpected_request}
end

defmodule AlplusWeb.OAuthAuthorizationControllerTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.OrgsFixtures

  @client_id "https://client.example/metadata.json"
  @redirect_uri "https://client.example/oauth/callback"
  @code_challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  @unrelated_secret "client-metadata-secret-that-must-never-leak"
  @loopback_client_id "https://client.example/loopback-metadata.json"
  @loopback_redirect_uri "http://localhost:49875/oauth/callback"
  @non_loopback_client_id "https://client.example/non-loopback-metadata.json"
  @non_loopback_redirect_uri "http://client.example/oauth/callback"
  @impersonation_client_id "https://client.example/impersonation-metadata.json"
  @private_client_id "https://private.example/metadata.json"
  @loopback_v4_client_id "https://client.example/loopback-v4-metadata.json"
  @loopback_v4_redirect_uri "http://127.0.0.1:49875/oauth/callback"
  @loopback_v6_client_id "https://client.example/loopback-v6-metadata.json"
  @loopback_v6_redirect_uri "http://[::1]:49875/oauth/callback"
  @userinfo_client_id "https://client.example/userinfo-metadata.json"
  @userinfo_redirect_uri "https://user@client.example/oauth/callback"
  @fragment_client_id "https://client.example/fragment-metadata.json"
  @fragment_redirect_uri "https://client.example/oauth/callback#frag"

  @supported_multi_scope "monitor:read monitor:write analytics:read"

  @state "browser-authorization-state"

  setup do
    previous_fetch_opts = Application.fetch_env(:alplus, :mcp_oauth_metadata_fetch_opts)

    Application.put_env(:alplus, :mcp_oauth_metadata_fetch_opts,
      dns_resolver: AlplusWeb.OAuthAuthorizationControllerTest.MetadataResolver,
      http_client: AlplusWeb.OAuthAuthorizationControllerTest.MetadataHTTPClient
    )

    on_exit(fn -> restore_fetch_opts(previous_fetch_opts) end)

    user = user_fixture()

    {org, scope} =
      org_fixture(Alplus.Scope.for_user(user.id), %{name: "Browser OAuth organization"})

    project = project_fixture(scope, org, %{name: "Browser OAuth project"})

    %{user: user, org: org, project: project, scope: scope}
  end

  test "a signed-out authorization request returns through sign-in with its complete path", %{
    conn: conn
  } do
    path = authorize_path(authorization_params())

    response =
      conn
      |> Plug.Test.init_test_session(%{})
      |> get(path)

    assert redirected_to(response) == "/sign-in"
    assert Plug.Conn.get_session(response, :return_to) == path
  end

  test "a signed-out authorization request does not fetch client metadata", %{conn: conn} do
    path =
      authorize_path(authorization_params(%{"client_id" => @private_client_id}))

    response =
      conn
      |> Plug.Test.init_test_session(%{})
      |> get(path)

    assert redirected_to(response) == "/sign-in"
    assert Plug.Conn.get_session(response, :return_to) == path
  end

  test "a signed-in user sees the client, account, permitted organization and project, and consent choices",
       %{conn: conn, user: user, org: org, project: project} do
    response =
      conn
      |> log_in(user)
      |> get(authorize_path(authorization_params()))

    html = html_response(response, 200)

    assert html =~ "PostDeploy MCP test client"
    assert html =~ "client.example"
    assert html =~ "After approval, you will return to client.example."
    assert html =~ to_string(user.email)
    assert html =~ org.name
    assert html =~ project.name
    assert html =~ "Projects read"
    assert html =~ "Allow"
    assert html =~ "Cancel"
    [csp] = get_resp_header(response, "content-security-policy")
    [_, nonce] = Regex.run(~r/script-src[^;]*'nonce-([^']+)'/, csp)
    assert html =~ ~s(nonce="#{nonce}")
    assert html =~ ~s(data-org-id="#{org.id}")

    refute html =~ @client_id
    refute html =~ @redirect_uri
    refute html =~ @state
    refute html =~ @code_challenge
    refute html =~ @unrelated_secret
    refute html =~ resource_uri()
  end

  test "organization consent binds all projects and one access choice", %{
    conn: conn,
    user: user,
    org: org,
    scope: scope
  } do
    resource = Alplus.Mcp.OAuth.resource_uri(org.public_token)

    consent =
      conn
      |> log_in(user)
      |> get(
        authorize_path(
          authorization_params(%{
            "resource" => resource,
            "scope" => @supported_multi_scope
          })
        )
      )

    html = html_response(consent, 200)
    assert html =~ org.name
    assert html =~ "All current and future projects."
    assert html =~ "Access level"
    assert html =~ "Read only"
    assert html =~ "Destructive actions always need your approval in PostDeploy."
    assert html =~ ~s(name="access")
    assert html =~ ~s(value="read")
    assert html =~ ~s(value="read_write")
    refute html =~ ~s(name="project_id")

    response =
      consent
      |> recycle()
      |> post("/oauth/authorize", %{
        "_csrf_token" => Plug.CSRFProtection.get_csrf_token(),
        "decision" => "allow",
        "access" => "read_write"
      })

    assert response.status in [302, 303]
    assert {:ok, [grant]} = Alplus.Mcp.list_oauth_grants(actor: scope)
    assert grant.scope_mode == "organization"
    assert is_nil(grant.project_id)
    assert grant.resource == resource
    assert grant.scopes == ["analytics:read", "monitor:read", "monitor:write"]

    code = callback_parameters(response)["code"]

    token_response =
      post(build_conn(), "/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "code_verifier" => "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
        "redirect_uri" => @redirect_uri,
        "client_id" => @client_id,
        "resource" => resource
      })

    assert token_response.status == 200
    access_token = json_response(token_response, 200)["access_token"]

    assert {:ok, %{scope_mode: :organization, org_id: org_id, project_id: nil}} =
             Alplus.Mcp.OAuth.authenticate_access_token(access_token, resource)

    assert org_id == org.id
  end

  test "a plain member cannot authorize an organization connection", %{
    conn: conn,
    org: org,
    scope: owner_scope
  } do
    member = user_fixture()
    member_fixture(owner_scope, org, member, "member")

    assert_authorization_error_redirect(
      conn,
      member,
      authorization_params(%{
        "resource" => Alplus.Mcp.OAuth.resource_uri(org.public_token),
        "scope" => @supported_multi_scope
      }),
      error: "access_denied"
    )
  end

  test "the consent form lets the user narrow requested permissions", %{conn: conn, user: user} do
    html =
      conn
      |> log_in(user)
      |> get(authorize_path(authorization_params(%{"scope" => @supported_multi_scope})))
      |> html_response(200)

    assert html =~ "Permissions"
    assert html =~ "Choose the permissions this client can use. Select at least one."
    assert html =~ ">Capability</th>"
    assert html =~ ">Read</th>"
    assert html =~ ">Write</th>"
    assert length(Regex.scan(~r/<th scope="row"/, html)) == 2
    assert html =~ ~s(name="scope_indices[]")
    assert html =~ ~s(id="oauth-scope-0")
    assert html =~ ~s(id="oauth-scope-1")
    assert html =~ ~s(id="oauth-scope-2")
    assert html =~ ~s(checked)
  end

  test "allow requires at least one selected permission and keeps the selection empty", %{
    conn: conn,
    user: user,
    org: org,
    project: project
  } do
    consent =
      conn
      |> log_in(user)
      |> get(authorize_path(authorization_params(%{"scope" => @supported_multi_scope})))

    csrf = Plug.CSRFProtection.get_csrf_token()

    response =
      consent
      |> recycle()
      |> post("/oauth/authorize", %{
        "_csrf_token" => csrf,
        "decision" => "allow",
        "org_id" => org.id,
        "project_id" => project.id
      })

    html = html_response(response, 200)
    assert html =~ "Choose at least one of the requested permissions."

    scope_inputs =
      Regex.scan(~r/<input[^>]+name="scope_indices\[\]"[^>]*>/, html) |> List.flatten()

    assert scope_inputs != []
    refute Enum.any?(scope_inputs, &Regex.match?(~r/\schecked(?:\s|\/?>)/, &1))
    assert get_resp_header(response, "location") == []
  end

  test "allow rejects a forged permission selection", %{
    conn: conn,
    user: user,
    org: org,
    project: project
  } do
    consent =
      conn
      |> log_in(user)
      |> get(authorize_path(authorization_params()))

    csrf = Plug.CSRFProtection.get_csrf_token()

    response =
      consent
      |> recycle()
      |> post("/oauth/authorize", %{
        "_csrf_token" => csrf,
        "decision" => "allow",
        "org_id" => org.id,
        "project_id" => project.id,
        "scope_indices" => ["999"]
      })

    assert html_response(response, 200) =~ "Choose at least one of the requested permissions."
    assert get_resp_header(response, "location") == []
  end

  test "a signed-in user sees capability labels for a supported multi-scope request", %{
    conn: conn,
    user: user,
    org: org,
    project: project
  } do
    response =
      conn
      |> log_in(user)
      |> get(authorize_path(authorization_params(%{"scope" => @supported_multi_scope})))

    html = html_response(response, 200)

    assert html =~ "PostDeploy MCP test client"
    assert html =~ to_string(user.email)
    assert html =~ org.name
    assert html =~ project.name
    assert html =~ "Monitor read"
    assert html =~ "Monitor write"
    assert html =~ "Analytics read"
    assert html =~ "Allow"
    assert html =~ "Cancel"
    refute html =~ "Projects read"
    refute html =~ "Changelog write"
    refute html =~ "monitor:read"
    refute html =~ "monitor:write"
    refute html =~ "analytics:read"
    refute html =~ "projects:read"
    refute html =~ "tools/list"
    refute html =~ "tools/call"
    refute html =~ @client_id
    refute html =~ @redirect_uri
    refute html =~ @state
    refute html =~ @code_challenge
    refute html =~ @unrelated_secret
    refute html =~ resource_uri()
  end

  test "rejects a response type other than code", %{conn: conn, user: user} do
    assert_authorization_error_redirect(
      conn,
      user,
      authorization_params(%{"response_type" => "token"})
    )
  end

  test "rejects a non-HTTPS client identifier", %{conn: conn, user: user} do
    assert_invalid_authorization(
      conn,
      user,
      authorization_params(%{"client_id" => "http://client.example/metadata.json"})
    )
  end

  test "rejects a redirect URI that is not exactly registered", %{conn: conn, user: user} do
    assert_invalid_authorization(
      conn,
      user,
      authorization_params(%{"redirect_uri" => @redirect_uri <> "/unexpected"})
    )
  end

  test "rejects an unregistered HTTP loopback redirect URI", %{conn: conn, user: user} do
    assert_invalid_authorization(
      conn,
      user,
      authorization_params(%{
        "client_id" => @loopback_client_id,
        "redirect_uri" => @loopback_redirect_uri <> "/unexpected"
      })
    )
  end

  test "rejects an exactly registered non-loopback HTTP redirect URI", %{conn: conn, user: user} do
    assert_invalid_authorization(
      conn,
      user,
      authorization_params(%{
        "client_id" => @non_loopback_client_id,
        "redirect_uri" => @non_loopback_redirect_uri
      })
    )
  end

  test "returns invalid_scope for an unsupported account scope", %{conn: conn, user: user} do
    assert_authorization_error_redirect(
      conn,
      user,
      authorization_params(%{"scope" => "projects:read account:read"}),
      error: "invalid_scope"
    )
  end

  test "returns invalid_scope for an unknown scope", %{conn: conn, user: user} do
    assert_authorization_error_redirect(
      conn,
      user,
      authorization_params(%{"scope" => "projects:read unknown:scope"}),
      error: "invalid_scope"
    )
  end

  test "rejects an empty state", %{conn: conn, user: user} do
    assert_authorization_error_redirect(
      conn,
      user,
      authorization_params(%{"state" => ""}),
      include_state?: false
    )
  end

  test "rejects a noncanonical MCP resource", %{conn: conn, user: user} do
    assert_authorization_error_redirect(
      conn,
      user,
      authorization_params(%{"resource" => resource_uri() <> "/"})
    )
  end

  test "rejects a request without a PKCE code challenge", %{conn: conn, user: user} do
    assert_authorization_error_redirect(
      conn,
      user,
      Map.delete(authorization_params(), "code_challenge")
    )
  end

  test "a valid redirect with a malformed PKCE method returns invalid_request to the client", %{
    conn: conn,
    user: user
  } do
    assert_authorization_error_redirect(
      conn,
      user,
      authorization_params(%{"code_challenge_method" => "plain"})
    )
  end

  test "rejects a PKCE method other than S256", %{conn: conn, user: user} do
    assert_authorization_error_redirect(
      conn,
      user,
      authorization_params(%{"code_challenge_method" => "plain"})
    )
  end

  test "rejects a request without a PKCE method", %{conn: conn, user: user} do
    assert_authorization_error_redirect(
      conn,
      user,
      Map.delete(authorization_params(), "code_challenge_method")
    )
  end

  test "rejects a request without a state", %{conn: conn, user: user} do
    assert_authorization_error_redirect(
      conn,
      user,
      Map.delete(authorization_params(), "state"),
      include_state?: false
    )
  end

  test "rejects a state longer than 512 bytes", %{conn: conn, user: user} do
    assert_authorization_error_redirect(
      conn,
      user,
      authorization_params(%{"state" => String.duplicate("a", 513)}),
      include_state?: false
    )
  end

  test "rejects a request without a resource", %{conn: conn, user: user} do
    assert_authorization_error_redirect(
      conn,
      user,
      Map.delete(authorization_params(), "resource")
    )
  end

  test "rejects a client metadata document whose client_id does not match the URL", %{
    conn: conn,
    user: user
  } do
    assert_invalid_authorization(
      conn,
      user,
      authorization_params(%{"client_id" => @impersonation_client_id})
    )
  end

  test "rejects a client identifier that resolves to a loopback address", %{
    conn: conn,
    user: user
  } do
    assert_invalid_authorization(
      conn,
      user,
      authorization_params(%{"client_id" => @private_client_id})
    )
  end

  test "rejects a redirect URI with userinfo even when listed in metadata", %{
    conn: conn,
    user: user
  } do
    assert_invalid_authorization(
      conn,
      user,
      authorization_params(%{
        "client_id" => @userinfo_client_id,
        "redirect_uri" => @userinfo_redirect_uri
      })
    )
  end

  test "rejects a redirect URI with a fragment even when listed in metadata", %{
    conn: conn,
    user: user
  } do
    assert_invalid_authorization(
      conn,
      user,
      authorization_params(%{
        "client_id" => @fragment_client_id,
        "redirect_uri" => @fragment_redirect_uri
      })
    )
  end

  test "allow redirects exactly to the registered URI with code, state, and issuer", %{
    conn: conn,
    user: user,
    org: org,
    project: project
  } do
    consent =
      conn
      |> log_in(user)
      |> get(authorize_path(authorization_params()))

    response = post_consent(consent, "allow", org.id, project.id)
    parameters = callback_parameters(response)

    assert Map.keys(parameters) |> MapSet.new() == MapSet.new(~w(code state iss))
    assert parameters["code"] != ""
    assert parameters["state"] == @state
    assert parameters["iss"] == issuer()
  end

  test "allow redirects for a supported multi-scope request with code, state, and issuer", %{
    conn: conn,
    user: user,
    org: org,
    project: project
  } do
    consent =
      conn
      |> log_in(user)
      |> get(authorize_path(authorization_params(%{"scope" => @supported_multi_scope})))

    response = post_consent(consent, "allow", org.id, project.id)
    parameters = callback_parameters(response)

    assert Map.keys(parameters) |> MapSet.new() == MapSet.new(~w(code state iss))
    assert parameters["code"] != ""
    assert parameters["state"] == @state
    assert parameters["iss"] == issuer()
  end

  test "allow redirects to an exactly registered HTTP loopback URI with code, state, and issuer",
       %{
         conn: conn,
         user: user,
         org: org,
         project: project
       } do
    consent =
      conn
      |> log_in(user)
      |> get(
        authorize_path(
          authorization_params(%{
            "client_id" => @loopback_client_id,
            "redirect_uri" => @loopback_redirect_uri
          })
        )
      )

    response = post_consent(consent, "allow", org.id, project.id)
    parameters = callback_parameters(response, @loopback_redirect_uri)

    assert Map.keys(parameters) |> MapSet.new() == MapSet.new(~w(code state iss))
    assert parameters["code"] != ""
    assert parameters["state"] == @state
    assert parameters["iss"] == issuer()
  end

  test "allow redirects for a dynamically registered native client", %{
    conn: conn,
    user: user,
    org: org,
    project: project
  } do
    redirect_uri = "http://127.0.0.1:6274/oauth/callback"

    registration =
      post(build_conn(), "/oauth/register", %{
        "client_name" => "Inspector",
        "redirect_uris" => [redirect_uri]
      })

    client_id = json_response(registration, 201)["client_id"]

    consent =
      conn
      |> log_in(user)
      |> get(
        authorize_path(
          authorization_params(%{
            "client_id" => client_id,
            "redirect_uri" => redirect_uri
          })
        )
      )

    html = html_response(consent, 200)
    assert html =~ "Inspector"
    assert html =~ "Registered application"
    assert html =~ "After approval, you will return to 127.0.0.1."
    [csp] = get_resp_header(consent, "content-security-policy")
    assert csp =~ "form-action 'self' http://127.0.0.1:6274"
    refute csp =~ redirect_uri

    response = post_consent(consent, "allow", org.id, project.id)
    parameters = callback_parameters(response, redirect_uri)

    assert parameters["code"] != ""
    assert parameters["state"] == @state
    assert parameters["iss"] == issuer()
  end

  test "allow redirects to a registered HTTP 127.0.0.1 loopback URI on an ephemeral port", %{
    conn: conn,
    user: user,
    org: org,
    project: project
  } do
    consent =
      conn
      |> log_in(user)
      |> get(
        authorize_path(
          authorization_params(%{
            "client_id" => @loopback_v4_client_id,
            "redirect_uri" => @loopback_v4_redirect_uri
          })
        )
      )

    response = post_consent(consent, "allow", org.id, project.id)
    parameters = callback_parameters(response, @loopback_v4_redirect_uri)

    assert Map.keys(parameters) |> MapSet.new() == MapSet.new(~w(code state iss))
    assert parameters["code"] != ""
    assert parameters["state"] == @state
    assert parameters["iss"] == issuer()
  end

  test "allow redirects to an exactly registered HTTP IPv6 loopback URI", %{
    conn: conn,
    user: user,
    org: org,
    project: project
  } do
    consent =
      conn
      |> log_in(user)
      |> get(
        authorize_path(
          authorization_params(%{
            "client_id" => @loopback_v6_client_id,
            "redirect_uri" => @loopback_v6_redirect_uri
          })
        )
      )

    response = post_consent(consent, "allow", org.id, project.id)
    parameters = callback_parameters(response, @loopback_v6_redirect_uri)

    assert Map.keys(parameters) |> MapSet.new() == MapSet.new(~w(code state iss))
    assert parameters["code"] != ""
    assert parameters["state"] == @state
    assert parameters["iss"] == issuer()
  end

  test "cancel redirects exactly to the registered URI with access_denied, state, and issuer", %{
    conn: conn,
    user: user,
    org: org,
    project: project
  } do
    consent =
      conn
      |> log_in(user)
      |> get(authorize_path(authorization_params()))

    response = post_consent(consent, "deny", org.id, project.id)
    parameters = callback_parameters(response)

    assert Map.keys(parameters) |> MapSet.new() == MapSet.new(~w(error state iss))
    assert parameters["error"] == "access_denied"
    assert parameters["state"] == @state
    assert parameters["iss"] == issuer()
    refute Map.has_key?(parameters, "code")
  end

  test "ordinary members receive no consent choice and cannot authorize a project", %{
    conn: conn,
    user: user,
    org: org,
    project: project,
    scope: scope
  } do
    member = user_fixture()
    member_fixture(scope, org, member)

    rejected_consent =
      conn
      |> log_in(member)
      |> get(authorize_path(authorization_params()))

    parameters = callback_parameters(rejected_consent)
    assert parameters["error"] == "access_denied"
    refute Map.has_key?(parameters, "code")
    refute rejected_consent.resp_body =~ to_string(member.email)

    owner_consent =
      conn
      |> log_in(user)
      |> get(authorize_path(authorization_params()))

    member_consent =
      conn
      |> log_in(member)
      |> put_session(
        :oauth_authorization_request,
        get_session(owner_consent, :oauth_authorization_request)
      )

    member_consent
    |> post_consent("allow", org.id, project.id)
    |> assert_rejected_without_callback_code()
  end

  test "a mismatched organization and project keeps consent open", %{
    conn: conn,
    user: user,
    org: org,
    project: project
  } do
    foreign_user = user_fixture()
    foreign_scope = scope_fixture(%{user: foreign_user})
    {foreign_org, foreign_owner_scope} = org_fixture(foreign_scope)
    foreign_project = project_fixture(foreign_owner_scope, foreign_org)

    consent =
      conn
      |> log_in(user)
      |> get(authorize_path(authorization_params()))

    mismatch = post_consent(consent, "allow", foreign_org.id, foreign_project.id)
    html = html_response(mismatch, 200)

    assert html =~ "Choose a project that belongs to the selected organization."
    assert html =~ "Allow"
    refute html =~ "code="

    response = post_consent(mismatch, "allow", org.id, project.id)
    parameters = callback_parameters(response)

    assert parameters["code"] != ""
    assert parameters["state"] == @state
  end

  test "allow cannot reuse a consumed authorization request", %{
    conn: conn,
    user: user,
    org: org,
    project: project
  } do
    consent =
      conn
      |> log_in(user)
      |> get(authorize_path(authorization_params()))

    first_response = post_consent(consent, "allow", org.id, project.id)
    assert callback_parameters(first_response)["code"] != ""

    first_response
    |> post_consent("allow", org.id, project.id)
    |> assert_rejected_without_callback_code()
  end

  test "consent without a CSRF token does not issue a code", %{
    conn: conn,
    user: user,
    org: org,
    project: project
  } do
    consent =
      conn
      |> log_in(user)
      |> get(authorize_path(authorization_params()))

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      consent
      |> recycle()
      |> Map.update!(:private, &Map.delete(&1, :plug_skip_csrf_protection))
      |> post("/oauth/authorize", %{
        "decision" => "allow",
        "org_id" => org.id,
        "project_id" => project.id
      })
    end
  end

  test "consent with a forged CSRF token does not issue a code", %{
    conn: conn,
    user: user,
    org: org,
    project: project
  } do
    consent =
      conn
      |> log_in(user)
      |> get(authorize_path(authorization_params()))

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      consent
      |> recycle()
      |> Map.update!(:private, &Map.delete(&1, :plug_skip_csrf_protection))
      |> post("/oauth/authorize", %{
        "_csrf_token" => "forged-csrf-token",
        "decision" => "allow",
        "org_id" => org.id,
        "project_id" => project.id
      })
    end
  end

  defp authorization_params(overrides \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => @client_id,
        "redirect_uri" => @redirect_uri,
        "scope" => "projects:read",
        "state" => @state,
        "resource" => resource_uri(),
        "code_challenge" => @code_challenge,
        "code_challenge_method" => "S256"
      },
      overrides
    )
  end

  defp authorize_path(parameters), do: "/oauth/authorize?" <> URI.encode_query(parameters)

  defp assert_invalid_authorization(conn, user, parameters) do
    response = conn |> log_in(user) |> get(authorize_path(parameters))

    assert response.status == 400
  end

  defp assert_authorization_error_redirect(conn, user, parameters, opts \\ []) do
    include_state? = Keyword.get(opts, :include_state?, true)
    expected_error = Keyword.get(opts, :error, "invalid_request")
    response = conn |> log_in(user) |> get(authorize_path(parameters))
    params = callback_parameters(response)

    assert params["error"] == expected_error
    assert params["iss"] == issuer()
    refute Map.has_key?(params, "code")

    if include_state? do
      assert params["state"] == parameters["state"]
    else
      refute Map.has_key?(params, "state")
    end
  end

  defp post_consent(conn, decision, org_id, project_id) do
    csrf = Plug.CSRFProtection.get_csrf_token()

    conn
    |> recycle()
    |> post("/oauth/authorize", %{
      "_csrf_token" => csrf,
      "decision" => decision,
      "org_id" => org_id,
      "project_id" => project_id,
      "scope_indices" => "0"
    })
  end

  defp assert_rejected_without_callback_code(response) do
    assert response.status == 400
    assert get_resp_header(response, "location") == []
  end

  defp callback_parameters(response, redirect_uri \\ @redirect_uri) do
    location = redirected_to(response)
    uri = URI.parse(location)

    assert URI.to_string(%{uri | query: nil, fragment: nil}) == redirect_uri
    URI.decode_query(uri.query)
  end

  defp issuer do
    AlplusWeb.Endpoint.url()
    |> String.trim_trailing("/")
  end

  defp resource_uri, do: issuer() <> "/mcp"

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp restore_fetch_opts(:error),
    do: Application.delete_env(:alplus, :mcp_oauth_metadata_fetch_opts)

  defp restore_fetch_opts({:ok, previous}),
    do: Application.put_env(:alplus, :mcp_oauth_metadata_fetch_opts, previous)
end
