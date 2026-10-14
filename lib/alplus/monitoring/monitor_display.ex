defmodule Alplus.Monitoring.MonitorDisplay do
  @moduledoc """
  Safe display formatting for monitor targets and HTTP headers.

  Monitor configuration is tenant-visible, so values that may carry bearer
  credentials must never be rendered into fleet or detail HTML.
  """

  @sensitive_key ~r/(authorization|auth|cookie|api[-_ ]?key|token|secret|pass(?:word|wd)?|credential)/i

  @spec sanitize_url(term()) :: String.t()
  def sanitize_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        uri
        |> Map.put(:userinfo, nil)
        |> Map.update(:query, nil, &redact_query/1)
        |> URI.to_string()

      _ ->
        redact_raw_url(url)
    end
  rescue
    URI.Error -> redact_raw_url(url)
  end

  def sanitize_url(_url), do: "Target unavailable"

  @spec format_headers(term()) :: String.t()
  def format_headers(nil), do: "-"

  def format_headers(headers) when is_map(headers) do
    headers
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end, :asc)
    |> Enum.map_join(", ", fn {key, value} ->
      value = if sensitive_key?(key), do: "[REDACTED]", else: format_value(value)
      "#{key}: #{value}"
    end)
  end

  def format_headers(value), do: to_string(value)

  defp redact_query(nil), do: nil

  defp redact_query(query) do
    query
    |> String.split("&", trim: true)
    |> Enum.map_join("&", fn pair ->
      {key, _value} = split_query_pair(pair)

      if sensitive_key?(key) do
        "#{key}=[REDACTED]"
      else
        pair
      end
    end)
  end

  defp split_query_pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, value] -> {key, value}
      [key] -> {key, nil}
    end
  end

  defp redact_raw_url(url) do
    [base | query_parts] = String.split(url, "?", parts: 2)
    base = Regex.replace(~r|(//)[^/@]+@|, base, "\\1")

    case query_parts do
      [] -> base
      [query] -> base <> "?" <> redact_query(query)
    end
  end

  defp sensitive_key?(key), do: Regex.match?(@sensitive_key, to_string(key))

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value, printable_limit: :infinity)
end
