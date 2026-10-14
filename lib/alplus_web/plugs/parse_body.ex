defmodule AlplusWeb.Plugs.ParseBody do
  @moduledoc """
  Runs `Plug.Parsers` for every request except public ingest routes.

  Warning: `Plug.Parsers` at the endpoint runs before any router pipeline.
  On an ingest path that read and decoded the request body before the
  bearer check and before the rate limiter, so a malformed
  `application/json` body raised `Plug.Parsers.ParseError` instead of the
  published `401 invalid_api_key`, and a rate-limited client still uploaded
  its whole payload before the `429`.

  The `/e/*`, `/v1/events`, and `/api/:project_id/envelope` ingest paths
  therefore skip parsing here.
  Their pipelines
  authenticate, tarpit, rate limit, and only then read the capped body with
  `AlplusWeb.Plugs.IngestRawBody`. `/m` skips parsing too, but its order
  differs: the site token travels in the payload, so `/m` reads its capped
  1 MiB body first, then resolves the token and rate limits. Every other
  route keeps the stock behaviour.
  """

  @behaviour Plug

  # Fixed, compile-time list of `conn.path_info` values, never request data.
  @ingest_paths [
    ["e", "errors"],
    ["e", "sessions"],
    ["e", "artifacts"],
    ["m"],
    ["mcp"],
    ["v1", "events"],
    ["v1", "events", "batch"]
  ]

  @impl true
  def init(opts), do: Plug.Parsers.init(opts)

  @impl true
  def call(%Plug.Conn{path_info: path_info} = conn, opts) do
    if ingest_path?(path_info), do: conn, else: Plug.Parsers.call(conn, opts)
  end

  # Warning: `conn.path_info` keeps the raw request-target segments.
  # `Phoenix.Router` matches routes against a percent-decoded COPY, so
  # `POST /e/error%73` reaches `ErrorIngestController` while the raw segments
  # read `["e", "error%73"]`. Comparing the raw form let an attacker opt the
  # whole skip out with one escape and get the parser back before the bearer
  # check. Compare what the router compares.
  defp ingest_path?(path_info) when path_info in @ingest_paths, do: true
  defp ingest_path?(["mcp" | _]), do: true

  defp ingest_path?(path_info) when length(path_info) in 1..4 do
    decoded = Enum.map(path_info, &URI.decode/1)
    decoded in @ingest_paths or match?(["api", _project, "envelope"], decoded)
  end

  defp ingest_path?(_path_info), do: false
end
