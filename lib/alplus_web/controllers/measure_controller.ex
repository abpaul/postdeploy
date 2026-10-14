defmodule AlplusWeb.MeasureController do
  use AlplusWeb, :controller

  @moduledoc """
  `POST /m`. The ingest preamble's token step (site-token authentication,
  tarpit on unknown tokens) runs as plugs on the `:measure_ingest`
  pipeline; this controller keeps only envelope parsing, rate limiting,
  and the write.
  """

  @allowed_keys ~w(site url referrer type name props device)

  def ingest(conn, _params) do
    # `IngestMeasureSource` selected the one payload and authenticated from
    # it. It leaves both unassigned when the body is malformed or carries no
    # usable site token; those answer 400 here.
    with source when not is_nil(source) <- conn.assigns[:source],
         body when is_map(body) <- conn.assigns[:ingest_payload],
         true <- valid_body?(body) do
      result =
        Alplus.Measure.Ingest.record(
          source,
          get_req_header(conn, "origin") |> List.first(),
          body,
          conn.remote_ip,
          get_req_header(conn, "user-agent") |> List.first(),
          get_req_header(conn, "cf-ipcountry") |> List.first()
        )

      Alplus.Ingest.OperationalMonitor.outcome(
        :measure,
        source.id,
        if(result == :accepted, do: 1, else: 0),
        if(result == :accepted, do: 0, else: 1),
        result
      )

      case result do
        :invalid_event -> invalid_request(conn)
        _accepted_or_rejected -> send_resp(conn, 204, "")
      end
    else
      _ -> invalid_request(conn)
    end
  rescue
    DBConnection.ConnectionError ->
      conn
      |> put_resp_header("retry-after", "1")
      |> send_resp(503, "")
  end

  defp valid_body?(body) do
    Map.keys(body) -- @allowed_keys == [] and is_binary(body["site"]) and is_binary(body["url"]) and
      byte_size(body["site"]) in 1..64 and byte_size(body["url"]) in 1..2048 and valid_type?(body)
  end

  defp valid_type?(body) do
    case Map.get(body, "type", "pageview") do
      "pageview" -> true
      type when type in ["custom_event", "event"] -> valid_event_name?(body["name"])
      _other -> false
    end
  end

  defp valid_event_name?(name) when is_binary(name) and byte_size(name) in 1..64,
    do: Regex.match?(~r/^[a-z0-9_-]+$/, name)

  defp valid_event_name?(_name), do: false

  defp invalid_request(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{type: "invalid_request_error", code: "parameter_invalid"}})
  end
end
