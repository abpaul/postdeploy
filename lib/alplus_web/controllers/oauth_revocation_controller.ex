defmodule AlplusWeb.OAuthRevocationController do
  use AlplusWeb, :controller

  alias Alplus.Mcp.OAuth

  def create(conn, params) when is_map(params) do
    _ = OAuth.revoke_token(Map.get(params, "token"), Map.get(params, "token_type_hint"))

    conn
    |> no_cache()
    |> send_resp(200, "")
  end

  def create(conn, _params) do
    conn
    |> no_cache()
    |> send_resp(200, "")
  end

  defp no_cache(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end
end
