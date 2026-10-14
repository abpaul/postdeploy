defmodule AlplusWeb.BodyReader do
  @moduledoc false

  @doc "Caches the parsed request body for routes that must validate wire bytes."
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, Plug.Conn.put_private(conn, :alplus_raw_body, body)}

      {:more, body, conn} ->
        previous = conn.private[:alplus_raw_body] || ""
        {:more, body, Plug.Conn.put_private(conn, :alplus_raw_body, previous <> body)}

      other ->
        other
    end
  end
end
