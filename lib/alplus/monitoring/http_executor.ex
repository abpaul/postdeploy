defmodule Alplus.Monitoring.HttpExecutor do
  @moduledoc false

  def run(config, opts \\ []) do
    started = System.monotonic_time(:millisecond)
    method = %{"GET" => :get, "HEAD" => :head, "POST" => :post}[config.method]
    resolver = Keyword.get(opts, :resolver)
    request = Keyword.get(opts, :request, &Req.request/1)
    headers = Enum.map(config.headers || %{}, fn {key, value} -> {key, value} end)
    timeout = config.timeout_seconds * 1_000

    result =
      request_target(
        config,
        method,
        config.body,
        headers,
        URI.parse(config.url),
        resolver,
        request,
        timeout
      )

    latency = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, %{status: status, body: body}} ->
        evaluate(config, status, body, latency)

      {:error, _reason} ->
        %{status: "down", status_code: nil, latency_ms: latency, error_class: "network_error"}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp request_target(
         config,
         method,
         body,
         headers,
         uri,
         resolver,
         request,
         timeout,
         redirects \\ 0
       ) do
    with {:ok, %{uri: uri, address: address, hostname: hostname}} <-
           resolve_target(uri, resolver),
         {:ok, response} <-
           request.(
             method: method,
             url: connect_url(uri, address),
             headers: put_host_header(headers, uri),
             body: body,
             redirect: false,
             max_redirects: 0,
             retry: false,
             receive_timeout: timeout,
             connect_options: [hostname: hostname, timeout: timeout]
           ) do
      if redirect?(config, response) do
        if redirects < config.max_redirects do
          case redirect_uri(uri, response) do
            {:ok, next_uri} ->
              {next_method, next_body} = redirect_method_and_body(method, body, response.status)

              request_target(
                config,
                next_method,
                next_body,
                redirect_headers(headers, uri, next_uri, response.status, method),
                next_uri,
                resolver,
                request,
                timeout,
                redirects + 1
              )

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:error, :too_many_redirects}
        end
      else
        {:ok, response}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp redirect_method_and_body(:post, _body, status) when status in [301, 302, 303],
    do: {:get, nil}

  defp redirect_method_and_body(method, body, _status), do: {method, body}

  defp resolve_target(%URI{scheme: scheme, host: host, userinfo: userinfo} = uri, resolver)
       when scheme in ["http", "https"] and is_binary(host) and host != "" and is_nil(userinfo) do
    with {:ok, address} <- Alplus.Monitoring.PublicAddress.resolve(host, resolver) do
      {:ok, %{uri: uri, address: address, hostname: host}}
    end
  end

  defp resolve_target(_uri, _resolver), do: {:error, :invalid_url}

  defp connect_url(uri, address) do
    uri
    |> Map.put(:host, address |> :inet.ntoa() |> to_string())
    |> URI.to_string()
  end

  defp put_host_header(headers, uri) do
    headers = Enum.reject(headers, fn {name, _value} -> String.downcase(name) == "host" end)
    [{"host", host_header(uri)} | headers]
  end

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host

    default_port? =
      (scheme == "http" and port in [nil, 80]) or (scheme == "https" and port in [nil, 443])

    if default_port?, do: host, else: "#{host}:#{port}"
  end

  defp redirect?(config, %{status: status}) do
    config.follow_redirects == true and status in [301, 302, 303, 307, 308]
  end

  defp redirect?(_config, _response), do: false

  defp redirect_uri(uri, response) do
    case response_location(response) do
      location when is_binary(location) ->
        next_uri = URI.merge(uri, location)
        if next_uri.host, do: {:ok, next_uri}, else: {:error, :invalid_url}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp response_location(%Req.Response{} = response),
    do: response |> Req.Response.get_header("location") |> List.first()

  defp response_location(%{headers: headers}) when is_map(headers),
    do: headers |> Map.get("location", []) |> List.first()

  defp response_location(%{headers: headers}) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {name, value} when is_binary(name) ->
        if String.downcase(name) == "location", do: value

      _ ->
        nil
    end)
  end

  defp response_location(_response), do: nil

  defp redirect_headers(headers, from_uri, to_uri, status, method) do
    same_authority? =
      {from_uri.scheme, from_uri.host, from_uri.port} ==
        {to_uri.scheme, to_uri.host, to_uri.port}

    Enum.reject(headers, fn {name, _value} ->
      name = String.downcase(name)

      (not same_authority? and name == "authorization") or
        (method == :post and status in [301, 302, 303] and
           name in ["content-type", "content-length"])
    end)
  end

  defp expected?(%{"kind" => "list", "values" => values}, status), do: status in values

  defp expected?(%{"kind" => "range", "min" => min, "max" => max}, status),
    do: status >= min and status <= max

  defp expected?(_, status), do: status >= 200 and status <= 399

  @doc false
  @spec evaluate(map(), non_neg_integer(), binary() | term(), non_neg_integer()) :: map()
  def evaluate(config, status_code, body, latency_ms) do
    cond do
      not expected?(config.expected_status, status_code) ->
        %{
          status: "down",
          status_code: status_code,
          latency_ms: latency_ms,
          error_class: "unexpected_status"
        }

      not keyword_matches?(config.keyword_match, body) ->
        %{
          status: "down",
          status_code: status_code,
          latency_ms: latency_ms,
          error_class: "keyword_not_matched"
        }

      slow?(config.response_time_threshold_ms, latency_ms) ->
        %{
          status: "degraded",
          status_code: status_code,
          latency_ms: latency_ms,
          error_class: "response_time_threshold"
        }

      true ->
        %{status: "up", status_code: status_code, latency_ms: latency_ms, error_class: nil}
    end
  end

  defp keyword_matches?(nil, _body), do: true

  defp keyword_matches?(%{"mode" => mode, "value" => value} = keyword_match, body)
       when mode in ["contains", "not_contains"] and is_binary(value) and byte_size(value) > 0 do
    scan_bytes =
      Map.get(keyword_match, "scanBytes", Map.get(keyword_match, "scan_bytes", 262_144))

    scan_bytes =
      if is_integer(scan_bytes), do: min(max(scan_bytes, 1_024), 1_048_576), else: 262_144

    body =
      if is_binary(body), do: binary_part(body, 0, min(byte_size(body), scan_bytes)), else: ""

    found? = :binary.match(body, value) != :nomatch
    if mode == "contains", do: found?, else: not found?
  end

  defp keyword_matches?(_keyword_match, _body), do: false

  defp slow?(nil, _latency_ms), do: false
  defp slow?(threshold, latency_ms) when is_integer(threshold), do: latency_ms > threshold
  defp slow?(_threshold, _latency_ms), do: false
end
