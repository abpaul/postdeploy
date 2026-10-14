defmodule AlplusWeb.ErrorIngestController do
  use AlplusWeb, :controller

  @moduledoc """
  `POST /e/errors`. The ingest preamble (bearer auth, tarpit, rate limit,
  raw-body capture, envelope size cap) runs as plugs on the `:error_ingest`
  pipeline. The shared Observe ingest module owns parsing and writes.
  """

  alias Alplus.Observe.Ingest

  def ingest(conn, _params) do
    source = conn.assigns.source

    with {:ok, envelope, dropped} <- Ingest.parse(conn.assigns.raw_body),
         :ok <- Ingest.header_matches?(envelope.header_key, conn.assigns.ingest_bearer),
         {:ok, result} <- Ingest.write_items(envelope, source, dropped) do
      Alplus.Ingest.OperationalMonitor.outcome(
        :errors,
        source.id,
        length(result.event_ids),
        result.dropped,
        :accepted
      )

      conn
      |> put_status(:accepted)
      |> json(%{
        accepted: length(result.event_ids),
        dropped: result.dropped,
        event_ids: result.event_ids,
        dropped_reason: result.dropped_reason
      })
    else
      :malformed -> error(conn, :bad_request, "validation_failed")
      :header_key_mismatch -> error(conn, :bad_request, "parameter_invalid")
      {:write_failed, _reason} -> unavailable(conn)
    end
  rescue
    DBConnection.ConnectionError -> unavailable(conn)
  end

  defp error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(%{error: %{type: "invalid_request_error", code: code}})
  end

  defp unavailable(conn) do
    Alplus.Ingest.OperationalMonitor.outcome(:errors, source_id(conn), 0, 1, :unavailable)

    conn
    |> put_resp_header("retry-after", "1")
    |> error(:service_unavailable, "ingest_overloaded")
  end

  defp source_id(%{assigns: %{source: source}}), do: source.id
  defp source_id(_conn), do: nil
end
