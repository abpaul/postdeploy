defmodule AlplusWeb.McpDiscoveryTest do
  use AlplusWeb.ConnCase, async: true

  test "serves Protected Resource Metadata for the MCP resource" do
    base_url = String.trim_trailing(AlplusWeb.Endpoint.url(), "/")

    for path <- [
          "/.well-known/oauth-protected-resource",
          "/.well-known/oauth-protected-resource/mcp"
        ] do
      conn = get(build_conn(), path)

      assert conn.status == 200
      metadata = json_response(conn, 200)

      assert metadata["resource"] == "#{base_url}/mcp"
      assert metadata["authorization_servers"] == [base_url]
      assert metadata["scopes_supported"] == Alplus.Mcp.Scope.all()
      assert metadata["bearer_methods_supported"] == ["header"]
    end
  end

  test "serves organization-qualified Protected Resource Metadata" do
    org_token = "AbCdEf0123456789"
    path = "/.well-known/oauth-protected-resource/mcp/org/#{org_token}"
    conn = get(build_conn(), path)

    assert conn.status == 200
    assert json_response(conn, 200)["resource"] == Alplus.Mcp.OAuth.resource_uri(org_token)
  end

  test "serves Authorization Server Metadata for MCP clients" do
    conn = get(build_conn(), "/.well-known/oauth-authorization-server")

    assert conn.status == 200
    metadata = json_response(conn, 200)
    base_url = String.trim_trailing(AlplusWeb.Endpoint.url(), "/")

    assert metadata["issuer"] == base_url
    assert metadata["authorization_endpoint"] == "#{base_url}/oauth/authorize"
    assert metadata["token_endpoint"] == "#{base_url}/oauth/token"
    assert metadata["revocation_endpoint"] == "#{base_url}/oauth/revoke"
    assert metadata["registration_endpoint"] == "#{base_url}/oauth/register"
    assert metadata["revocation_endpoint_auth_methods_supported"] == ["none"]
    assert metadata["device_authorization_endpoint"] == "#{base_url}/oauth/device_authorization"

    assert metadata["grant_types_supported"] == [
             "authorization_code",
             "refresh_token",
             "urn:ietf:params:oauth:grant-type:device_code"
           ]

    assert metadata["response_types_supported"] == ["code"]
    assert metadata["code_challenge_methods_supported"] == ["S256"]
    assert metadata["client_id_metadata_document_supported"] == true
    assert metadata["authorization_response_iss_parameter_supported"] == true
    assert metadata["scopes_supported"] == Alplus.Mcp.Scope.all()
  end
end
