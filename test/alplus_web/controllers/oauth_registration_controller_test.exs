defmodule AlplusWeb.OAuthRegistrationControllerTest do
  use AlplusWeb.ConnCase, async: true

  alias Alplus.Mcp.OAuth

  test "registers a public native client and authorizes it" do
    redirect_uri = "http://127.0.0.1:6274/oauth/callback"

    response =
      post(build_conn(), "/oauth/register", %{
        "client_name" => "MCP Inspector",
        "application_type" => "native",
        "redirect_uris" => [redirect_uri],
        "token_endpoint_auth_method" => "none",
        "grant_types" => ["authorization_code"],
        "response_types" => ["code"]
      })

    body = json_response(response, 201)
    client_id = body["client_id"]

    assert String.starts_with?(client_id, "mcocl_")
    refute Map.has_key?(body, "client_secret")
    assert body["redirect_uris"] == [redirect_uri]
    assert body["token_endpoint_auth_method"] == "none"
    assert {:ok, _client} = Alplus.Mcp.OAuth.ClientMetadata.fetch(client_id)
  end

  test "rejects a non-loopback HTTP redirect URI" do
    response =
      post(build_conn(), "/oauth/register", %{
        "client_name" => "Bad client",
        "redirect_uris" => ["http://example.com/callback"]
      })

    assert json_response(response, 400)["error"] == "invalid_redirect_uri"
  end

  test "rejects a CSP wildcard HTTPS redirect host" do
    response =
      post(build_conn(), "/oauth/register", %{
        "client_name" => "Wildcard client",
        "redirect_uris" => ["https://*/callback"]
      })

    assert json_response(response, 400)["error"] == "invalid_redirect_uri"
  end

  test "authorization metadata advertises the registration endpoint" do
    assert OAuth.registration_endpoint() ==
             String.trim_trailing(AlplusWeb.Endpoint.url(), "/") <> "/oauth/register"
  end
end
