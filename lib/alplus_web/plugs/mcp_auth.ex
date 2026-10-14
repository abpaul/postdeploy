defmodule AlplusWeb.Plugs.McpAuth do
  @moduledoc "Authenticates the MCP bearer header before ExMCP reads the body."

  @behaviour Plug

  import Plug.Conn

  alias Alplus.Mcp.Authorization

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Authorization.authenticate(conn) do
      {:ok, principal} -> assign(conn, :mcp_principal, principal)
      {:error, _reason} -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    metadata_uri = protected_resource_metadata_uri(conn.request_path)

    challenge =
      if no_credentials?(conn) do
        "Bearer resource_metadata=\"#{metadata_uri}\""
      else
        "Bearer error=\"invalid_token\", resource_metadata=\"#{metadata_uri}\""
      end

    conn
    |> put_resp_header("www-authenticate", challenge)
    |> put_resp_content_type("application/json")
    |> send_resp(
      401,
      Jason.encode!(%{error: %{code: "unauthenticated", message: "Authentication is required"}})
    )
    |> halt()
  end

  defp protected_resource_metadata_uri(path) when is_binary(path),
    do: path |> String.trim_trailing("/") |> metadata_uri_for_path()

  defp metadata_uri_for_path("/mcp/org/" <> public_token)
       when byte_size(public_token) == 16,
       do: Alplus.Mcp.OAuth.protected_resource_metadata_uri(public_token)

  defp metadata_uri_for_path(_path),
    do: Alplus.Mcp.OAuth.protected_resource_metadata_uri()

  defp no_credentials?(conn) do
    get_req_header(conn, "authorization") == [] and not forbidden_query_token?(conn)
  end

  defp forbidden_query_token?(conn) do
    Enum.any?(String.split(conn.query_string, "&"), fn parameter ->
      parameter in ["token", "access_token", "api_key"] or
        String.starts_with?(parameter, ["token=", "access_token=", "api_key="])
    end)
  end

  @doc false
  def handler_opts(conn, _request), do: [principal: conn.assigns[:mcp_principal]]
end
