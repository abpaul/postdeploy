defmodule Alplus.Monitoring.AnonymousProbe do
  @moduledoc """
  One-shot public HTTP probe for the website health check.

  This is not `HttpExecutor`. The anonymous path caps the response body,
  validates TLS with hostname checking, and never forwards visitor headers.
  """

  alias Alplus.Monitoring.AnonymousProbe.Url
  alias Alplus.Monitoring.ExpiryScanner.Native, as: Certificate
  alias Alplus.Monitoring.PublicAddress

  @max_redirects 5
  @connect_timeout_ms 5_000
  @total_budget_ms 10_000
  @max_body_bytes 256 * 1024
  @user_agent "PostDeploy-WebsiteHealthCheck/1"
  @max_header_bytes 200
  # The response headers the health check reports. Everything here describes how
  # the server answered; nothing here carries visitor state or a set-cookie.
  @reported_headers ~w(
    server content-type content-length cache-control
    strict-transport-security content-security-policy
    x-frame-options x-content-type-options referrer-policy
  )

  @type hop :: %{url: String.t(), status: pos_integer() | nil, location: String.t() | nil}

  @type result :: %{
          url: String.t(),
          final_status: pos_integer() | nil,
          elapsed_ms: non_neg_integer(),
          hops: [hop()],
          dns_answers: [%{host: String.t(), addresses: [String.t()]}],
          tls: nil | %{trusted: boolean(), expires_at: DateTime.t() | nil},
          keyword: nil | %{value: String.t(), matched: boolean()},
          headers: %{optional(String.t()) => String.t()},
          body_bytes: non_neg_integer() | nil,
          outcome: :ok | atom()
        }

  @spec run(String.t(), String.t() | nil, keyword()) ::
          {:ok, result()} | {:error, atom()}
  def run(url, keyword \\ nil, opts \\ [])

  def run(url, keyword, opts) when is_list(opts) do
    opts = Keyword.merge(Application.get_env(:alplus, :anonymous_probe_opts, []), opts)
    started = Keyword.get(opts, :started, System.monotonic_time(:millisecond))

    with {:ok, uri} <- Url.parse(url),
         {:ok, keyword} <- Url.keyword(keyword) do
      follow(uri, keyword, started, opts, [], [], 0)
    end
  end

  defp follow(uri, keyword, started, opts, hops, dns_answers, redirects) do
    remaining = remaining_ms(started, opts)

    cond do
      remaining <= 0 ->
        {:ok, bounded(uri, keyword, started, hops, dns_answers, :timeout)}

      redirects > max_redirects(opts) ->
        {:ok, bounded(uri, keyword, started, hops, dns_answers, :too_many_redirects)}

      true ->
        probe_hop(uri, keyword, started, opts, hops, dns_answers, redirects, remaining)
    end
  end

  defp probe_hop(uri, keyword, started, opts, hops, dns_answers, redirects, remaining) do
    resolver = Keyword.get(opts, :resolver)

    case resolve(uri.host, resolver) do
      {:ok, address, answers} ->
        dns_answers = dns_answers ++ [answers]
        connect_hop(uri, address, keyword, started, opts, hops, dns_answers, redirects, remaining)

      {:error, reason} ->
        {:ok, bounded(uri, keyword, started, hops, dns_answers, reason)}
    end
  end

  defp connect_hop(uri, address, keyword, started, opts, hops, dns_answers, redirects, remaining) do
    with {:ok, tls} <- maybe_tls(uri, address, remaining, opts) do
      case request_hop(uri, address, remaining, opts) do
        {:ok, %{status: status, headers: headers, body: body}} ->
          hop = %{url: Url.display(uri), status: status, location: location(headers)}
          hops = hops ++ [hop]

          if redirect?(status) do
            case next_uri(uri, hop.location) do
              {:ok, next} ->
                follow(next, keyword, started, opts, hops, dns_answers, redirects + 1)

              {:error, reason} ->
                {:ok, finish(uri, keyword, started, hops, dns_answers, tls, headers, nil, reason)}
            end
          else
            {:ok, finish(uri, keyword, started, hops, dns_answers, tls, headers, body, :ok)}
          end

        {:error, :response_too_large} ->
          hop = %{url: Url.display(uri), status: nil, location: nil}

          {:ok,
           bounded(uri, keyword, started, hops ++ [hop], dns_answers, :response_too_large, tls)}

        {:error, :timeout} ->
          {:ok, bounded(uri, keyword, started, hops, dns_answers, :timeout, tls)}

        {:error, :tls_untrusted} ->
          {:ok,
           bounded(uri, keyword, started, hops, dns_answers, :tls_untrusted, tls_untrusted())}

        {:error, _reason} ->
          {:ok, bounded(uri, keyword, started, hops, dns_answers, :network_error, tls)}
      end
    else
      {:error, :tls_untrusted} ->
        {:ok, bounded(uri, keyword, started, hops, dns_answers, :tls_untrusted, tls_untrusted())}

      {:error, :timeout} ->
        {:ok, bounded(uri, keyword, started, hops, dns_answers, :timeout)}

      {:error, _reason} ->
        {:ok, bounded(uri, keyword, started, hops, dns_answers, :network_error)}
    end
  end

  defp resolve(host, resolver) do
    case PublicAddress.resolve(host, resolver) do
      {:ok, address} ->
        answers = %{host: host, addresses: [format_address(address)]}
        {:ok, address, answers}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_tls(%URI{scheme: "https"} = uri, address, remaining, opts) do
    timeout = min(connect_timeout_ms(opts), remaining)
    hostname = uri.host
    port = uri.port || 443
    tls = Keyword.get(opts, :tls, &default_tls/4)

    case tls.(hostname, address, port, timeout) do
      {:ok, info} -> {:ok, info}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_tls(_uri, _address, _remaining, _opts), do: {:ok, nil}

  defp default_tls(hostname, address, port, timeout) do
    options = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(hostname),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ],
      active: false
    ]

    case :ssl.connect(address, port, options, timeout) do
      {:ok, socket} ->
        cert = :ssl.peercert(socket)
        _ = :ssl.close(socket)
        {:ok, %{trusted: true, expires_at: expiry(cert)}}

      {:error, {:tls_alert, _alert}} ->
        {:error, :tls_untrusted}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, {:options, {:cacerts, _}}} ->
        {:error, :tls_untrusted}

      {:error, _reason} ->
        {:error, :tls_untrusted}
    end
  end

  defp expiry({:ok, der}) do
    case Certificate.certificate_expiry(der) do
      {:ok, expires_at} -> expires_at
      _ -> nil
    end
  end

  defp expiry(_), do: nil

  defp request_hop(uri, address, remaining, opts) do
    request = Keyword.get(opts, :request, &default_request/1)
    timeout = min(remaining, total_budget_ms(opts))
    connect_timeout = min(connect_timeout_ms(opts), timeout)

    request.(
      method: :get,
      url: connect_url(uri, address),
      headers: request_headers(uri),
      body: nil,
      redirect: false,
      max_redirects: 0,
      retry: false,
      compressed: false,
      receive_timeout: timeout,
      connect_options: connect_options(uri, connect_timeout)
    )
    |> cap_body(opts)
  end

  defp default_request(opts) do
    max_body = max_body_bytes()
    collected = :atomics.new(1, signed: false)

    into = fn
      {:data, chunk}, {req, resp} when is_binary(chunk) ->
        size = :atomics.add_get(collected, 1, byte_size(chunk))

        if size > max_body do
          {:halt, {req, Map.put(resp, :body, :too_large)}}
        else
          body = Map.get(resp, :body) || ""
          {:cont, {req, Map.put(resp, :body, body <> chunk)}}
        end

      other, acc ->
        _ = other
        {:cont, acc}
    end

    case Req.request(Keyword.put(opts, :into, into)) do
      {:ok, %Req.Response{body: :too_large}} ->
        {:error, :response_too_large}

      {:ok, %Req.Response{} = response} ->
        {:ok, %{status: response.status, headers: response.headers, body: response.body || ""}}

      {:error, %Req.TransportError{reason: reason}} when reason in [:timeout, :closed] ->
        {:error, :timeout}

      {:error, %{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _reason} ->
        {:error, :network_error}
    end
  end

  defp cap_body({:ok, %{body: body} = response}, opts) when is_binary(body) do
    if byte_size(body) > max_body_bytes(opts) do
      {:error, :response_too_large}
    else
      {:ok, response}
    end
  end

  defp cap_body({:ok, %{body: :too_large}}, _opts), do: {:error, :response_too_large}
  defp cap_body(other, _opts), do: other

  defp connect_options(%URI{scheme: "https", host: host}, timeout) do
    [
      hostname: host,
      timeout: timeout,
      transport_opts: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(host),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  defp connect_options(%URI{host: host}, timeout), do: [hostname: host, timeout: timeout]

  defp request_headers(uri) do
    [
      {"host", host_header(uri)},
      {"user-agent", @user_agent},
      {"accept", "*/*"},
      {"connection", "close"}
    ]
  end

  defp connect_url(uri, address) do
    uri
    |> Map.put(:host, format_address(address))
    |> URI.to_string()
  end

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host

    default_port? =
      (scheme == "http" and port in [nil, 80]) or (scheme == "https" and port in [nil, 443])

    if default_port?, do: host, else: "#{host}:#{port}"
  end

  defp redirect?(status) when status in [301, 302, 303, 307, 308], do: true
  defp redirect?(_status), do: false

  defp next_uri(_uri, nil), do: {:error, :invalid_url}

  defp next_uri(uri, location) when is_binary(location) do
    next = URI.merge(uri, location)

    case Url.parse(URI.to_string(next)) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp location(headers), do: header(headers, "location")

  defp header(headers, name) when is_map(headers) do
    Enum.find_value(headers, fn
      {key, [value | _]} -> if matches_header?(key, name), do: value
      {key, value} when is_binary(value) -> if matches_header?(key, name), do: value
      _ -> nil
    end)
  end

  defp header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} ->
        if matches_header?(key, name), do: value |> List.wrap() |> List.first()

      _ ->
        nil
    end)
  end

  defp header(_headers, _name), do: nil

  defp matches_header?(key, name), do: String.downcase(to_string(key)) == name

  # Only the allowlist, only single values, and only the first 200 bytes: these
  # strings come from a stranger's server and end up on a public page.
  defp reported_headers(headers) do
    for name <- @reported_headers,
        value = header(headers, name),
        is_binary(value),
        trimmed = String.trim(value),
        trimmed != "",
        into: %{} do
      {name, String.slice(trimmed, 0, @max_header_bytes)}
    end
  end

  defp finish(uri, keyword, started, hops, dns_answers, tls, headers, body, outcome) do
    last = List.last(hops)

    %{
      url: Url.display(uri),
      final_status: last && last.status,
      elapsed_ms: elapsed(started),
      hops: hops,
      dns_answers: dns_answers,
      tls: tls,
      keyword: keyword_result(keyword, body),
      headers: reported_headers(headers),
      body_bytes: if(is_binary(body), do: byte_size(body)),
      outcome: outcome
    }
  end

  defp bounded(uri, keyword, started, hops, dns_answers, outcome, tls \\ nil) do
    %{
      url: Url.display(uri),
      final_status: nil,
      elapsed_ms: elapsed(started),
      hops: hops,
      dns_answers: dns_answers,
      tls: tls,
      keyword: keyword_result(keyword, nil),
      headers: %{},
      body_bytes: nil,
      outcome: outcome
    }
  end

  defp keyword_result(nil, _body), do: nil

  defp keyword_result(keyword, body) when is_binary(body),
    do: %{value: keyword, matched: :binary.match(body, keyword) != :nomatch}

  defp keyword_result(keyword, _body), do: %{value: keyword, matched: false}

  defp tls_untrusted, do: %{trusted: false, expires_at: nil}

  defp elapsed(started), do: max(0, System.monotonic_time(:millisecond) - started)

  defp remaining_ms(started, opts) do
    total_budget_ms(opts) - elapsed(started)
  end

  defp total_budget_ms(opts), do: Keyword.get(opts, :total_budget_ms, @total_budget_ms)
  defp connect_timeout_ms(opts), do: Keyword.get(opts, :connect_timeout_ms, @connect_timeout_ms)
  defp max_redirects(opts), do: Keyword.get(opts, :max_redirects, @max_redirects)
  defp max_body_bytes(opts \\ []), do: Keyword.get(opts, :max_body_bytes, @max_body_bytes)

  defp format_address(address), do: address |> :inet.ntoa() |> to_string()
end
