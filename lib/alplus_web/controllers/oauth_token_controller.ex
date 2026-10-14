defmodule AlplusWeb.OAuthTokenController do
  use AlplusWeb, :controller

  alias Alplus.Mcp.OAuth

  def create(
        conn,
        %{
          "grant_type" => "authorization_code",
          "code" => code,
          "code_verifier" => code_verifier,
          "redirect_uri" => redirect_uri,
          "client_id" => client_id,
          "resource" => resource
        }
      )
      when is_binary(code) and byte_size(code) > 0 and is_binary(code_verifier) and
             byte_size(code_verifier) > 0 and is_binary(redirect_uri) and
             byte_size(redirect_uri) > 0 and is_binary(client_id) and byte_size(client_id) > 0 and
             is_binary(resource) and byte_size(resource) > 0 do
    case OAuth.exchange_code(%{
           "grant_type" => "authorization_code",
           "code" => code,
           "code_verifier" => code_verifier,
           "redirect_uri" => redirect_uri,
           "client_id" => client_id,
           "resource" => resource
         }) do
      {:ok, token_response} ->
        conn
        |> no_cache()
        |> json(token_response)

      {:error, _reason} ->
        token_error(conn, "invalid_grant")
    end
  end

  def create(
        conn,
        %{
          "grant_type" => "refresh_token",
          "refresh_token" => refresh_token,
          "client_id" => client_id,
          "resource" => resource
        } = params
      )
      when is_binary(refresh_token) and byte_size(refresh_token) > 0 and
             is_binary(client_id) and byte_size(client_id) > 0 and is_binary(resource) and
             byte_size(resource) > 0 do
    refresh_params = %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => client_id,
      "resource" => resource
    }

    refresh_params =
      if Map.has_key?(params, "scope") do
        Map.put(refresh_params, "scope", params["scope"])
      else
        refresh_params
      end

    case OAuth.refresh_token(refresh_params) do
      {:ok, token_response} ->
        conn
        |> no_cache()
        |> json(token_response)

      {:error, _reason} ->
        token_error(conn, "invalid_grant")
    end
  end

  def create(
        conn,
        %{
          "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
          "device_code" => device_code,
          "client_id" => client_id,
          "resource" => resource
        }
      )
      when is_binary(device_code) and byte_size(device_code) > 0 and
             is_binary(client_id) and byte_size(client_id) > 0 and is_binary(resource) and
             byte_size(resource) > 0 do
    case OAuth.redeem_device_code(%{
           "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
           "device_code" => device_code,
           "client_id" => client_id,
           "resource" => resource
         }) do
      {:ok, token_response} ->
        conn
        |> no_cache()
        |> json(token_response)

      # RFC 8628 section 3.5. `authorization_pending` and `slow_down` tell a
      # polling client to keep waiting, so they must stay distinguishable.
      {:error, reason} ->
        token_error(conn, Atom.to_string(reason))
    end
  end

  def create(conn, _params), do: token_error(conn, "invalid_request")

  defp no_cache(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end

  defp token_error(conn, error) do
    conn
    |> no_cache()
    |> put_status(:bad_request)
    |> json(%{"error" => error})
  end
end
