defmodule AlplusWeb.Plugs.IngestAuth do
  @moduledoc """
  Bearer authentication for the `/e/*` and `/v1/events` ingest pipelines
  (issue #57, ADR 0007).

  One implementation of the ingest preamble's credential step: extract the
  bearer key, authenticate it against an active Source of the pipeline's own
  type, and tarpit invalid keys before any scarce-resource admission or
  database work happens downstream.

  The Source type is the authorization boundary. A pipeline declares the one
  type it accepts (`plug AlplusWeb.Plugs.IngestAuth, :analytics`), and a key
  of any other type fails exactly like an unknown key. A published analytics
  write key therefore reaches no Observe route, and an Observe key writes no
  analytics event.

  On success it assigns:

    * `:source` — the authenticated, active Source
    * `:ingest_environment` — the server-trusted environment taken from the
      Source credential, never from client-supplied payload fields
      (ADR-0001). This assign is the one enforcement point of that rule.

  Halts with `401 invalid_api_key` when the bearer is missing or unknown. Both
  cases use the same 250 ms tarpit floor.

  A pipeline that serves Sentry SDKs declares `{:observe, :sentry}`. The key
  then comes from the `X-Sentry-Auth` header or the `sentry_key` query
  parameter, which is where a Sentry SDK puts the DSN key.
  """

  @behaviour Plug

  import Plug.Conn

  alias Alplus.Observe.Tarpit
  alias Alplus.Sources.Source

  # Fixed, compile-time type wiring. The pipeline names the type; nothing in
  # the request can select a different one.
  @source_types %{observe: :authenticate_observe, analytics: :authenticate_analytics}

  @impl true
  def init({type, scheme}) when is_map_key(@source_types, type) and scheme in [:bearer, :sentry],
    do: {type, scheme}

  def init(type) when is_map_key(@source_types, type), do: {type, :bearer}
  def init(_opts), do: {:observe, :bearer}

  @impl true
  def call(conn, {type, scheme}) do
    authenticate = Map.fetch!(@source_types, type)

    case credential(conn, scheme) do
      {:ok, secret} ->
        case apply(Source, authenticate, [secret]) do
          {:ok, source} ->
            conn
            |> assign(:source, source)
            |> assign(:ingest_bearer, secret)
            |> assign(:ingest_environment, source.environment)

          {:error, :not_found} ->
            # Tarpit before anything else touches the database downstream.
            Tarpit.delay_invalid_key()
            unauthorized(conn)
        end

      :missing_bearer ->
        Tarpit.delay_invalid_key()
        unauthorized(conn)
    end
  end

  defp credential(conn, :bearer) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> secret] when byte_size(secret) > 0 -> {:ok, String.trim(secret)}
      _ -> :missing_bearer
    end
  end

  defp credential(conn, :sentry) do
    header_key =
      conn
      |> get_req_header("x-sentry-auth")
      |> Enum.find_value(fn header ->
        case Regex.run(~r/(?:\A|[\s,])sentry_key=([^,\s]+)/, header) do
          [_, key] -> key
          nil -> nil
        end
      end)

    case header_key || conn.query_params["sentry_key"] do
      key when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
      _ -> :missing_bearer
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      :unauthorized,
      Jason.encode!(%{error: %{type: "invalid_request_error", code: "invalid_api_key"}})
    )
    |> halt()
  end
end
