defmodule AlplusWeb.OAuthRegistrationController do
  @moduledoc "RFC 7591 Dynamic Client Registration fallback for MCP clients."

  use AlplusWeb, :controller

  alias Alplus.Mcp.OAuth

  def create(conn, params) do
    case OAuth.register_client(params) do
      {:ok, body} ->
        conn
        |> put_status(:created)
        |> json(body)

      {:error, :invalid_redirect_uri} ->
        registration_error(conn, :bad_request, "invalid_redirect_uri")

      {:error, _reason} ->
        registration_error(conn, :bad_request, "invalid_client_metadata")
    end
  end

  defp registration_error(conn, status, error) do
    conn
    |> put_status(status)
    |> json(%{"error" => error})
  end
end
