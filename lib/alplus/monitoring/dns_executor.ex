defmodule Alplus.Monitoring.DnsExecutor do
  @moduledoc false

  @timeout_seconds 10
  @type_numbers %{"A" => 1, "NS" => 2, "CNAME" => 5, "MX" => 15, "TXT" => 16, "AAAA" => 28}

  def run(config, request \\ &Req.request/1) do
    started = System.monotonic_time(:millisecond)

    result = doh_request(config.hostname, config.record_type, request)

    latency = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        assess(decode_body(body), config, latency)

      {:ok, %{status: status}} ->
        %{status: "down", status_code: status, latency_ms: latency, error_class: "doh_error"}

      {:error, :timeout} ->
        %{status: "down", status_code: nil, latency_ms: latency, error_class: "timeout"}

      {:error, _reason} ->
        %{status: "down", status_code: nil, latency_ms: latency, error_class: "network_error"}
    end
  end

  defp doh_request(hostname, record_type, request) do
    timeout = @timeout_seconds * 1_000

    request.(
      method: :get,
      url:
        "https://cloudflare-dns.com/dns-query?name=#{URI.encode(hostname)}&type=#{record_type}",
      headers: [{"accept", "application/dns-json"}],
      retry: false,
      receive_timeout: timeout,
      connect_options: [timeout: timeout]
    )
  end

  defp extract_values(answers, record_type) do
    answers
    |> Enum.filter(&(Map.get(&1, "type") == @type_numbers[record_type]))
    |> Enum.map(&Map.get(&1, "data"))
    |> Enum.filter(&is_binary/1)
  end

  defp assess(%{"Status" => 0, "Answer" => answers}, config, latency) when is_list(answers) do
    values = extract_values(answers, config.record_type)
    expected_values = Map.get(config, :expected_values, [])
    match_mode = Map.get(config, :match_mode, :all)

    match(values, expected_values, match_mode, latency)
  end

  defp assess(%{"Status" => 3}, _config, latency),
    do: %{status: "down", status_code: nil, latency_ms: latency, error_class: "dns_nxdomain"}

  defp assess(_body, _config, latency),
    do: %{status: "down", status_code: nil, latency_ms: latency, error_class: "dns_error"}

  # Resolvability: no expected values configured, so any answer means up.
  defp match(values, [], _match_mode, latency) do
    if values == [] do
      %{status: "down", status_code: nil, latency_ms: latency, error_class: "no_records"}
    else
      %{status: "up", status_code: nil, latency_ms: latency, error_class: nil}
    end
  end

  defp match(values, expected_values, :all, latency) do
    if values != [] and Enum.all?(expected_values, &(&1 in values)) do
      %{status: "up", status_code: nil, latency_ms: latency, error_class: nil}
    else
      down_for_values(values, latency)
    end
  end

  defp match(values, expected_values, :any, latency) do
    if values != [] and Enum.any?(expected_values, &(&1 in values)) do
      %{status: "up", status_code: nil, latency_ms: latency, error_class: nil}
    else
      down_for_values(values, latency)
    end
  end

  defp down_for_values([], latency),
    do: %{status: "down", status_code: nil, latency_ms: latency, error_class: "no_records"}

  defp down_for_values(_values, latency),
    do: %{status: "down", status_code: nil, latency_ms: latency, error_class: "record_mismatch"}

  # Cloudflare DoH replies with content-type "application/dns-json", which Req
  # does not auto-decode (it only decodes "application/json"), so the body
  # arrives as a raw JSON string. Decode it before assessing.
  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp decode_body(body), do: body
end
