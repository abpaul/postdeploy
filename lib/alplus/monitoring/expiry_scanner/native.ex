defmodule Alplus.Monitoring.ExpiryScanner.Native do
  @moduledoc false

  @behaviour Alplus.Monitoring.ExpiryScanner

  @default_timeout 5_000

  @impl true
  def scan(url, opts) when is_binary(url) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, uri} <- parse_https_url(url),
         {:ok, ssl_expires_at} <- ssl_expiry(uri.host, uri.port || 443, timeout, opts) do
      {:ok,
       %{
         ssl_expires_at: ssl_expires_at,
         domain_expires_at: domain_expiry(uri.host, timeout)
       }}
    end
  end

  defp parse_https_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} = uri when is_binary(host) and host != "" -> {:ok, uri}
      _ -> {:error, :https_required}
    end
  end

  defp ssl_expiry(host, port, timeout, opts) do
    options = [
      verify: :verify_none,
      server_name_indication: String.to_charlist(host),
      active: false
    ]

    resolver = Keyword.get(opts, :resolver)
    connector = Keyword.get(opts, :ssl_connector, &:ssl.connect/4)

    with {:ok, address} <- Alplus.Monitoring.PublicAddress.resolve(host, resolver),
         {:ok, socket} <- connector.(:inet.ntoa(address), port, options, timeout),
         {:ok, certificate} <- :ssl.peercert(socket) do
      :ssl.close(socket)
      certificate_expiry(certificate)
    end
  end

  # OTP's public-key records are tuples at runtime. Match only the stable
  # certificate/validity positions so this remains compatible with supported
  # OTP releases without a compile-time record include.
  @doc false
  def certificate_expiry(certificate) do
    case :public_key.pkix_decode_cert(certificate, :otp) do
      {:OTPCertificate, tbs_certificate, _signature_algorithm, _signature} ->
        validity = elem(tbs_certificate, 5)
        not_after = elem(validity, 2)
        parse_asn1_time(not_after)

      _ ->
        {:error, :invalid_certificate}
    end
  rescue
    _ -> {:error, :invalid_certificate}
  end

  @doc false
  def parse_asn1_time({:utcTime, value}), do: parse_x509_time(to_string(value), :utc)

  def parse_asn1_time({:generalTime, value}), do: parse_x509_time(to_string(value), :general)

  def parse_asn1_time(_), do: {:error, :invalid_certificate_expiry}

  defp parse_x509_time(value, :utc) do
    with [year, month, day, hour, minute, second] <-
           captures(~r/^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/, value),
         {short_year, ""} <- Integer.parse(year) do
      full_year = if short_year >= 50, do: 1900 + short_year, else: 2000 + short_year
      datetime_from_parts(full_year, month, day, hour, minute, second)
    else
      _ -> {:error, :invalid_certificate_expiry}
    end
  end

  defp parse_x509_time(value, :general) do
    with [year, month, day, hour, minute, second] <-
           captures(~r/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/, value),
         {full_year, ""} <- Integer.parse(year) do
      datetime_from_parts(full_year, month, day, hour, minute, second)
    else
      _ -> {:error, :invalid_certificate_expiry}
    end
  end

  # IANA returns the authoritative WHOIS server for a TLD. This is deliberately
  # best-effort: unsupported registries produce no domain date, while SSL
  # results remain useful. Domain expiration is not inferred from DNS records.
  defp domain_expiry(host, timeout) do
    with {:ok, domain} <- registrable_domain(host),
         {:ok, iana_response} <- whois_query("whois.iana.org", domain, timeout),
         {:ok, server} <- referral_server(iana_response),
         {:ok, response} <- whois_query(server, domain, timeout) do
      response |> expiry_from_whois() |> unwrap_optional_expiry()
    else
      _ -> nil
    end
  end

  @doc false
  def unwrap_optional_expiry({:ok, expiry}), do: expiry
  def unwrap_optional_expiry(_), do: nil

  @doc false
  def registrable_domain(host) do
    labels = String.split(host, ".", trim: true)

    case Enum.take(labels, -2) do
      [second_level, top_level] -> {:ok, second_level <> "." <> top_level}
      _ -> {:error, :not_a_domain}
    end
  end

  defp whois_query(server, domain, timeout) do
    with {:ok, socket} <-
           :gen_tcp.connect(String.to_charlist(server), 43, [:binary, active: false], timeout),
         :ok <- :gen_tcp.send(socket, domain <> "\r\n"),
         {:ok, response} <- recv_all(socket, timeout) do
      :gen_tcp.close(socket)
      {:ok, response}
    end
  end

  defp recv_all(socket, timeout), do: recv_all(socket, timeout, [])

  defp recv_all(socket, timeout, chunks) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, chunk} -> recv_all(socket, timeout, [chunk | chunks])
      {:error, :closed} -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def referral_server(response) do
    case Regex.run(~r/^refer:\s*(\S+)/im, response, capture: :all_but_first) do
      [server] -> {:ok, server}
      _ -> {:error, :no_whois_referral}
    end
  end

  @doc false
  def expiry_from_whois(response) do
    expression =
      ~r/^(?:registry expiry date|registrar registration expiration date|expiration date|expiry date|expires on)\s*:\s*(.+)$/im

    case Regex.run(expression, response, capture: :all_but_first) do
      [value] -> parse_whois_date(String.trim(value))
      _ -> {:error, :expiry_not_found}
    end
  end

  @doc false
  def parse_whois_date(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> parse_whois_date_without_time(value)
    end
  end

  defp parse_whois_date_without_time(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
      _ -> parse_day_month_year(value)
    end
  end

  defp parse_day_month_year(value) do
    months = %{
      "jan" => 1,
      "feb" => 2,
      "mar" => 3,
      "apr" => 4,
      "may" => 5,
      "jun" => 6,
      "jul" => 7,
      "aug" => 8,
      "sep" => 9,
      "oct" => 10,
      "nov" => 11,
      "dec" => 12
    }

    with [day, month, year] <- captures(~r/^(\d{1,2})-([A-Za-z]{3})-(\d{4})$/, value),
         month_number when is_integer(month_number) <- months[String.downcase(month)],
         {day, ""} <- Integer.parse(day),
         {year, ""} <- Integer.parse(year),
         {:ok, date} <- Date.new(year, month_number, day) do
      {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
    else
      _ -> {:error, :invalid_domain_expiry}
    end
  end

  defp datetime_from_parts(year, month, day, hour, minute, second) do
    with {month, ""} <- Integer.parse(month),
         {day, ""} <- Integer.parse(day),
         {hour, ""} <- Integer.parse(hour),
         {minute, ""} <- Integer.parse(minute),
         {second, ""} <- Integer.parse(second),
         {:ok, naive} <- NaiveDateTime.new(year, month, day, hour, minute, second) do
      {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
    else
      _ -> {:error, :invalid_certificate_expiry}
    end
  end

  defp captures(expression, value) do
    case Regex.run(expression, value, capture: :all_but_first) do
      nil -> []
      captures -> captures
    end
  end
end
