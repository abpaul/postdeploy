defmodule AlplusWeb.Plugs.IngestMeasureSource do
  @moduledoc """
  Token authentication for the Measure ingest pipeline (issue #57).

  Measure beacons carry their site token in the payload (`site`), not an
  Authorization header, so this plug resolves the token against an active
  `:measure` Source. An unknown or revoked token tarpits — before any
  database work downstream — and answers `204` with an empty body, wire-
  identical to a known-but-rejected beacon: this request has no
  organization, so it cannot consume the organization's budget.

  On success it assigns `:source`. Measure's write path takes the
  server-trusted environment from that Source credential itself (ADR-0001),
  never from a client-supplied value. A payload without a usable `site`
  value passes through untouched so the controller's envelope validation
  answers 400.

  This plug also selects the ONE payload the request is judged and written
  from, before it authenticates anything. Browser beacons post with
  `Content-Type: text/plain` (`sendBeacon` and no-cors `fetch` force it), so
  the payload is the raw body captured by `IngestRawBody` (which runs first
  on this pipeline), decoded once and assigned as `:ingest_payload`. A
  request with no body at all is judged from its query parameters instead.

  Warning: a non-empty body that is not a JSON object is rejected outright.
  It never falls back to the query string. Authenticating from one payload
  and writing another let a malformed body pass its own validation and store
  whatever the query string said.
  """

  @behaviour Plug

  import Plug.Conn

  alias Alplus.Observe.Tarpit
  alias Alplus.Sources.Source

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case payload(conn) do
      {:ok, payload} ->
        resolve(assign(conn, :ingest_payload, payload), payload)

      :malformed ->
        # No `:source`, no `:ingest_payload`: the controller answers 400.
        conn
    end
  end

  defp resolve(conn, payload) do
    case site_token(payload) do
      {:ok, site} ->
        case Source.resolve_measure(site) do
          {:ok, source} ->
            assign(conn, :source, source)

          {:error, :not_found} ->
            # Tarpit before anything else touches the database downstream.
            Tarpit.delay_invalid_key()
            silently_accept(conn)
        end

      :no_token ->
        conn
    end
  end

  # An empty body is a query-parameter beacon. Any other body wins outright.
  defp payload(%{assigns: %{raw_body: ""}, params: params}), do: {:ok, params}

  defp payload(%{assigns: %{raw_body: raw}}) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, body} when is_map(body) -> {:ok, body}
      _ -> :malformed
    end
  end

  defp site_token(%{"site" => site}) when is_binary(site) and byte_size(site) > 0,
    do: {:ok, site}

  defp site_token(_payload), do: :no_token

  defp silently_accept(conn) do
    conn
    |> send_resp(:no_content, "")
    |> halt()
  end
end
