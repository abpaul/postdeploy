defmodule AlplusWeb.SessionIngestController do
  @moduledoc """
  `POST /e/sessions` (issue #12): a dedicated, ADDITIVE ingest path for
  request-scoped session outcomes -- the `POST /e/errors` envelope and its
  published SDK contract are unchanged (ARCHITECTURE.md §8 decision #5).
  The ingest preamble (bearer auth, tarpit, rate limit, raw-body capture,
  envelope size cap) runs as plugs on the `:session_ingest` pipeline; this
  controller keeps only envelope parsing and writes.
  """

  use AlplusWeb, :controller

  alias Alplus.Observe.SessionEnvelope
  alias Alplus.Security.BearerToken

  def ingest(conn, _params) do
    source = conn.assigns.source

    with {:ok, envelope, dropped} <- parse_envelope(conn.assigns.raw_body),
         :ok <- header_matches?(envelope.header_key, conn.assigns.ingest_bearer) do
      result =
        Alplus.Observe.SessionIngest.write(envelope, %{
          source: source,
          environment: conn.assigns.ingest_environment,
          malformed: dropped
        })

      Alplus.Ingest.OperationalMonitor.outcome(
        :sessions,
        source.id,
        result.accepted,
        result.dropped,
        :accepted
      )

      conn
      |> put_status(:accepted)
      |> json(%{
        accepted: result.accepted,
        dropped: result.dropped,
        dropped_reason: result.dropped_reason
      })
    else
      :malformed -> error(conn, :bad_request, "validation_failed")
      :header_key_mismatch -> error(conn, :bad_request, "parameter_invalid")
    end
  rescue
    DBConnection.ConnectionError ->
      conn
      |> put_resp_header("retry-after", "1")
      |> error(:service_unavailable, "ingest_overloaded")
  end

  defp parse_envelope(raw) do
    case SessionEnvelope.parse(raw) do
      {:ok, envelope, dropped} -> {:ok, envelope, dropped}
      :error -> :malformed
    end
  end

  defp header_matches?(nil, _bearer), do: :ok

  defp header_matches?(header_key, bearer) do
    if BearerToken.matches?(BearerToken.hash(header_key), BearerToken.hash(bearer)),
      do: :ok,
      else: :header_key_mismatch
  end

  defp error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(%{error: %{type: "invalid_request_error", code: code}})
  end
end
