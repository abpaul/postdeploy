defmodule AlplusWeb.Plugs.IngestRawBody do
  @moduledoc """
  Raw-body capture and the envelope size cap for the ingest pipelines
  (issue #57).

  Reads the exact wire bytes once — reusing the endpoint body reader's
  cache when a parser already consumed the body, otherwise reading it here
  — and halts with `413 body_too_large` when they exceed `:max_bytes`. On
  success it assigns `:raw_body` so controllers parse the envelope from
  the same bytes the cap was checked against. A read that fails halts with
  `400 parameter_invalid`.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: Keyword.fetch!(opts, :max_bytes)

  @impl true
  def call(conn, max_bytes) do
    case fetch_raw(conn, max_bytes) do
      {:ok, raw, conn} ->
        assign(conn, :raw_body, raw)

      {:too_large, conn} ->
        error(conn, 413, "body_too_large")

      {:read_failed, conn} ->
        error(conn, 400, "parameter_invalid")
    end
  end

  defp fetch_raw(%{private: %{alplus_raw_body: raw}} = conn, max_bytes),
    do: check_size(raw, conn, max_bytes)

  # Warning: keep the conn `read_body/2` returns. It carries the adapter
  # state that records the body as consumed. Discarding it left the adapter
  # claiming the body was unread, so Bandit tried to drain it again after the
  # response and either swallowed the next keep-alive request or stalled the
  # connection for its 15-second read timeout.
  defp fetch_raw(conn, max_bytes) do
    case Plug.Conn.read_body(conn, length: max_bytes + 1, read_timeout: 5_000) do
      {:ok, raw, conn} -> check_size(raw, conn, max_bytes)
      {:more, _partial, conn} -> {:too_large, conn}
      {:error, _reason} -> {:read_failed, conn}
    end
  end

  # Warning: never synthesize an empty body from a failed read. `/m` would
  # then authenticate and write the query parameters of a request whose body
  # never arrived, and the `/e/*` paths would report a validation failure for
  # bytes nobody ever saw. Say the read failed and stop.
  defp error(conn, status, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{type: "invalid_request_error", code: code}}))
    |> halt()
  end

  defp check_size(raw, conn, max_bytes) when byte_size(raw) <= max_bytes, do: {:ok, raw, conn}
  defp check_size(_raw, conn, _max_bytes), do: {:too_large, conn}
end
