defmodule AlplusWeb.SentryIngestController do
  use AlplusWeb, :controller

  @moduledoc """
  `POST /api/:project_id/envelope`, the endpoint a Sentry SDK derives from its
  DSN. The `:sentry_ingest` pipeline runs the same preamble as `/e/errors`.
  The key in the DSN selects the Source, so the project segment is not read.
  """

  alias Alplus.Observe.{Ingest, SentryEnvelope}

  def ingest(conn, _params) do
    source = conn.assigns.source
    encoding = conn |> get_req_header("content-encoding") |> List.first()

    with {:ok, raw} <- SentryEnvelope.inflate(conn.assigns.raw_body, encoding),
         {:ok, envelope} <- SentryEnvelope.parse(raw),
         {:ok, accepted, dropped} <- write(envelope.items, source, envelope.dropped) do
      Alplus.Ingest.OperationalMonitor.outcome(:errors, source.id, accepted, dropped, :accepted)

      json(
        conn,
        if(envelope.event_id, do: %{id: envelope.event_id}, else: %{})
      )
    else
      :error ->
        error(conn, :bad_request, "validation_failed")

      :unsupported_encoding ->
        error(conn, :unsupported_media_type, "content_encoding_unsupported")

      :too_large ->
        error(conn, :request_entity_too_large, "body_too_large")

      {:write_failed, _reason} ->
        unavailable(conn)
    end
  rescue
    DBConnection.ConnectionError -> unavailable(conn)
  end

  defp write(items, source, dropped) do
    Enum.reduce_while(items, {:ok, 0, dropped}, fn item, {:ok, accepted, dropped} ->
      case Ingest.write_item(source, item) do
        {:ok, result} ->
          {:cont, {:ok, accepted + length(result.event_ids), dropped + result.dropped}}

        :malformed ->
          {:cont, {:ok, accepted, dropped + 1}}

        {:write_failed, _reason} = failed ->
          {:halt, failed}
      end
    end)
  end

  defp error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(%{error: %{type: "invalid_request_error", code: code}})
  end

  defp unavailable(conn) do
    Alplus.Ingest.OperationalMonitor.outcome(:errors, conn.assigns.source.id, 0, 1, :unavailable)

    conn
    |> put_resp_header("retry-after", "1")
    |> error(:service_unavailable, "ingest_overloaded")
  end
end
