defmodule AlplusWeb.Plugs.RedactedTelemetry do
  @moduledoc "Emits Phoenix endpoint telemetry with bearer paths and OAuth secrets redacted."

  @bearer_paths [
    "share",
    "h",
    "invitations",
    "password-reset",
    "confirm_new_user",
    "confirm_email_change"
  ]

  # `sentry_key` is the Observe key a Sentry SDK may send in the query string.
  @oauth_param_keys ~w(
    code
    code_verifier
    code_challenge
    refresh_token
    access_token
    token
    sentry_key
  )

  @behaviour Plug

  @impl Plug
  def init(opts) do
    Plug.Telemetry.init(opts)
  end

  @impl Plug
  def call(conn, {start_event, stop_event, opts}) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      start_event,
      %{system_time: System.system_time()},
      %{conn: redact(conn), options: opts}
    )

    Plug.Conn.register_before_send(conn, fn conn ->
      :telemetry.execute(
        stop_event,
        %{duration: System.monotonic_time() - start_time},
        %{conn: redact(conn), options: opts}
      )

      conn
    end)
  end

  @doc false
  def redact(conn) do
    conn
    |> redact_bearer_path()
    |> redact_oauth_params()
    |> redact_authorization_header()
    |> redact_raw_body()
  end

  defp redact_bearer_path(%{path_info: [path, token | _rest]} = conn)
       when path in @bearer_paths and is_binary(token) do
    %{conn | request_path: String.replace(conn.request_path, token, "[FILTERED]")}
  end

  defp redact_bearer_path(conn), do: conn

  defp redact_oauth_params(conn) do
    %{
      conn
      | params: filter_params(conn.params),
        body_params: filter_params(conn.body_params),
        query_params: filter_params(conn.query_params),
        query_string: filter_query_string(conn.query_string)
    }
  end

  defp redact_authorization_header(conn) do
    headers =
      Enum.map(conn.req_headers, fn
        {key, "Bearer " <> _token} -> {key, "Bearer [FILTERED]"}
        {"x-sentry-auth", _value} -> {"x-sentry-auth", "[FILTERED]"}
        other -> other
      end)

    %{conn | req_headers: headers}
  end

  defp redact_raw_body(conn) do
    update_in(conn.private, &Map.delete(&1, :alplus_raw_body))
  end

  # A multipart request puts a `Plug.Upload` struct in the params. A struct
  # is a map but is not enumerable.
  defp filter_params(%_{} = value), do: value

  defp filter_params(params) when is_map(params) do
    Map.new(params, fn {key, value} ->
      if oauth_param_key?(key) do
        {key, "[FILTERED]"}
      else
        {key, filter_params(value)}
      end
    end)
  end

  defp filter_params(value), do: value

  defp filter_query_string(query_string) when is_binary(query_string) and query_string != "" do
    query_string
    |> URI.decode_query()
    |> filter_params()
    |> URI.encode_query()
  end

  defp filter_query_string(query_string), do: query_string

  defp oauth_param_key?(key) when is_atom(key), do: Atom.to_string(key) in @oauth_param_keys
  defp oauth_param_key?(key) when is_binary(key), do: key in @oauth_param_keys
  defp oauth_param_key?(_key), do: false
end
