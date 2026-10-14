defmodule AlplusWeb.McpDiscoveryController do
  @moduledoc "Serves OAuth discovery metadata for the MCP resource."

  use AlplusWeb, :controller

  alias Alplus.Mcp.OAuth
  alias ExMCP.Plugs.ProtectedResourceMetadata

  @doc "Serves Protected Resource Metadata for an MCP resource."
  def protected_resource(conn, %{"org_token" => org_token}) do
    serve_protected_resource(conn, OAuth.resource_uri(org_token))
  end

  def protected_resource(conn, _params) do
    serve_protected_resource(conn, OAuth.resource_uri())
  end

  defp serve_protected_resource(conn, resource) do
    opts =
      ProtectedResourceMetadata.init(
        resource: resource,
        authorization_servers: [OAuth.issuer()],
        scopes_supported: OAuth.supported_scopes(),
        bearer_methods_supported: ["header"]
      )

    ProtectedResourceMetadata.call(conn, opts)
  end

  @doc "Serves Authorization Server Metadata for MCP clients."
  def authorization_server(conn, _params) do
    json(conn, %{
      "issuer" => OAuth.issuer(),
      "authorization_endpoint" => OAuth.authorization_endpoint(),
      "token_endpoint" => OAuth.token_endpoint(),
      "revocation_endpoint" => OAuth.revocation_endpoint(),
      "registration_endpoint" => OAuth.registration_endpoint(),
      "device_authorization_endpoint" => OAuth.device_authorization_endpoint(),
      "response_types_supported" => ["code"],
      "grant_types_supported" => [
        "authorization_code",
        "refresh_token",
        OAuth.device_grant_type()
      ],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["none"],
      "revocation_endpoint_auth_methods_supported" => ["none"],
      "scopes_supported" => OAuth.supported_scopes(),
      "client_id_metadata_document_supported" => true,
      "authorization_response_iss_parameter_supported" => true
    })
  end
end
