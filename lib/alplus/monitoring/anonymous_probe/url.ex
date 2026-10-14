defmodule Alplus.Monitoring.AnonymousProbe.Url do
  @moduledoc false

  @max_url_bytes 2_048
  @max_keyword_bytes 900
  @host_pattern ~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\z/
  # People type "example.com", not "https://example.com". A value that already
  # carries a scheme keeps it, so a rejected scheme still reports itself, and a
  # leading "example.com:8443" reads as a port rather than as a scheme.
  @scheme_prefix ~r{\A[a-zA-Z][a-zA-Z0-9+.\-]*:(?!\d)}

  @spec parse(term()) :: {:ok, URI.t()} | {:error, atom()}
  def parse(url) when is_binary(url) do
    url = String.trim(url)

    cond do
      url == "" ->
        {:error, :invalid_url}

      byte_size(url) > @max_url_bytes ->
        {:error, :url_too_long}

      true ->
        url |> with_scheme() |> parse_uri()
    end
  end

  def parse(_url), do: {:error, :invalid_url}

  @spec keyword(term()) :: {:ok, String.t() | nil} | {:error, atom()}
  def keyword(nil), do: {:ok, nil}
  def keyword(""), do: {:ok, nil}

  def keyword(value) when is_binary(value) do
    if byte_size(value) > @max_keyword_bytes,
      do: {:error, :keyword_too_long},
      else: {:ok, value}
  end

  def keyword(_value), do: {:error, :invalid_keyword}

  @spec display(URI.t()) :: String.t()
  def display(%URI{} = uri), do: URI.to_string(%{uri | fragment: nil})

  defp with_scheme(url) do
    if Regex.match?(@scheme_prefix, url) do
      url
    else
      "https://" <> String.trim_leading(url, "/")
    end
  end

  defp parse_uri(url) do
    uri = URI.parse(url)

    with :ok <- scheme(uri),
         :ok <- userinfo(uri),
         :ok <- fragment(uri),
         :ok <- host(uri),
         :ok <- port(uri) do
      {:ok, normalize(uri)}
    end
  rescue
    URI.Error -> {:error, :invalid_url}
  end

  defp scheme(%URI{scheme: scheme}) when scheme in ["http", "https"], do: :ok
  defp scheme(%URI{scheme: scheme}) when is_binary(scheme), do: {:error, :forbidden_scheme}
  defp scheme(_uri), do: {:error, :invalid_url}

  defp userinfo(%URI{userinfo: nil}), do: :ok
  defp userinfo(_uri), do: {:error, :userinfo}

  defp fragment(%URI{fragment: nil}), do: :ok
  defp fragment(_uri), do: {:error, :fragment}

  defp host(%URI{host: host}) when is_binary(host) and host != "" do
    cond do
      ip_literal?(host) ->
        :ok

      Regex.match?(@host_pattern, host) ->
        :ok

      true ->
        {:error, :malformed_host}
    end
  end

  defp host(_uri), do: {:error, :malformed_host}

  defp port(%URI{scheme: "http", port: port}) when port in [nil, 80], do: :ok
  defp port(%URI{scheme: "https", port: port}) when port in [nil, 443], do: :ok
  defp port(_uri), do: {:error, :forbidden_port}

  defp normalize(%URI{path: path} = uri) do
    %{uri | path: normalize_path(path), fragment: nil}
  end

  defp normalize_path(nil), do: "/"
  defp normalize_path(""), do: "/"
  defp normalize_path(path), do: path

  defp ip_literal?(host) do
    host = unwrap_ipv6(host)

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _address} -> true
      _ -> false
    end
  end

  defp unwrap_ipv6("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [host, ""] -> host
      _ -> rest
    end
  end

  defp unwrap_ipv6(host), do: host
end
