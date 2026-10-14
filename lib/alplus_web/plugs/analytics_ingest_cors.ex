defmodule AlplusWeb.Plugs.AnalyticsIngestCors do
  @moduledoc """
  Cross-origin access for `POST /v1/events` and `POST /v1/events/batch`
  (ADR 0007).

  This is the only PostDeploy path that answers a cross-origin request.
  A browser application sends `Authorization` and `Content-Type:
  application/json`, which makes the request preflighted, so without this
  plug every web client would fail before the first event.

  The grant is deliberately narrow:

    * any origin, because an analytics write key is published in the client
      and an origin allow list would protect nothing it does not already
      protect;
    * `Authorization` and `Content-Type` request headers only;
    * no credentials, so a browser never attaches a PostDeploy session
      cookie to an ingest request;
    * no exposed response headers.

  The write key itself is the boundary. It can write events into one
  project and do nothing else (`Alplus.Sources.Source`).
  """

  @behaviour Plug

  import Plug.Conn

  @max_age "86400"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    conn
    |> headers()
    |> put_resp_header("access-control-allow-methods", "POST, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "authorization, content-type")
    |> put_resp_header("access-control-max-age", @max_age)
    |> send_resp(:no_content, "")
    |> halt()
  end

  def call(conn, _opts), do: headers(conn)

  defp headers(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("vary", "origin")
  end
end
