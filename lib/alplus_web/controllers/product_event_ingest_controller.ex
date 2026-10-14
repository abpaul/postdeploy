defmodule AlplusWeb.ProductEventIngestController do
  use AlplusWeb, :controller

  @moduledoc """
  `POST /v1/events` and `POST /v1/events/batch` (ADR 0007).

  The ingest preamble (CORS, bearer auth, tarpit, admission, rate limit,
  raw-body capture, request size cap) runs as plugs on the
  `:product_event_ingest` pipeline. This controller parses, validates,
  meters, writes, and answers.

  It computes no funnel, no retention, and no property aggregate. Every
  analytics question is answered at read time, so a slow query can never
  slow a customer's application down.
  """

  alias Alplus.Analytics.Ingest

  def create(conn, _params), do: ingest(conn, :single)

  def batch(conn, _params), do: ingest(conn, :batch)

  defp ingest(conn, shape) do
    source = conn.assigns.source
    now = DateTime.utc_now()

    with {:ok, raw_events} <- Ingest.parse(conn.assigns.raw_body, shape),
         {:ok, events} <- Ingest.normalize(raw_events, now),
         {:ok, result} <- Ingest.write(source, events, now) do
      Alplus.Ingest.OperationalMonitor.outcome(
        :product_events,
        source.id,
        result.accepted,
        result.dropped,
        :accepted
      )

      conn
      |> put_status(:accepted)
      |> json(response(result))
    else
      {:error, code, message} ->
        Alplus.Ingest.OperationalMonitor.outcome(:product_events, source.id, 0, 1, :rejected)
        error(conn, :bad_request, code, message)

      {:error, :write_failed} ->
        unavailable(conn)
    end
  rescue
    DBConnection.ConnectionError -> unavailable(conn)
  end

  # Small on purpose. A client that batches has to know how many events the
  # server took, so `accepted` is always present; `dropped` and
  # `dropped_reason` appear only when something was dropped, so the common
  # response stays two fields.
  defp response(%{dropped: 0} = result), do: %{success: true, accepted: result.accepted}

  defp response(result) do
    %{
      success: true,
      accepted: result.accepted,
      dropped: result.dropped,
      dropped_reason: result.dropped_reason
    }
  end

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{type: "invalid_request_error", code: code, message: message}})
  end

  defp unavailable(conn) do
    Alplus.Ingest.OperationalMonitor.outcome(:product_events, source_id(conn), 0, 1, :unavailable)

    conn
    |> put_resp_header("retry-after", "1")
    |> error(
      :service_unavailable,
      "ingest_overloaded",
      "PostDeploy could not store these events. Retry with backoff."
    )
  end

  defp source_id(%{assigns: %{source: source}}), do: source.id
  defp source_id(_conn), do: nil
end
