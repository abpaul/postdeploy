defmodule AlplusWeb.OAuthDeviceController do
  @moduledoc """
  RFC 8628 device authorization endpoint. A client that cannot open a browser
  on its own host starts here, shows the user code, and then polls the token
  endpoint.
  """

  use AlplusWeb, :controller

  alias Alplus.Mcp.OAuth
  alias Alplus.Mcp.OAuth.DeviceRateLimiter

  def create(conn, params) do
    case DeviceRateLimiter.check_authorization(conn.remote_ip) do
      :ok -> start(conn, params)
      {:error, retry_after} -> too_many_requests(conn, retry_after)
    end
  end

  defp start(conn, params) do
    case OAuth.start_device_authorization(params) do
      {:ok, response} ->
        conn
        |> no_cache()
        |> json(response)

      {:error, reason} ->
        error(conn, reason)
    end
  end

  defp too_many_requests(conn, retry_after) do
    conn
    |> no_cache()
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_status(:too_many_requests)
    |> json(%{"error" => "slow_down"})
  end

  defp error(conn, :invalid_scope), do: device_error(conn, "invalid_scope")
  defp error(conn, :invalid_client), do: device_error(conn, "invalid_client")
  defp error(conn, _reason), do: device_error(conn, "invalid_request")

  defp no_cache(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end

  defp device_error(conn, error) do
    conn
    |> no_cache()
    |> put_status(:bad_request)
    |> json(%{"error" => error})
  end
end
