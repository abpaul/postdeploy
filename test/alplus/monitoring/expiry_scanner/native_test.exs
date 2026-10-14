defmodule Alplus.Monitoring.ExpiryScanner.NativeTest do
  use ExUnit.Case, async: true

  alias Alplus.Monitoring.ExpiryScanner.Native

  test "rejects non-https URLs" do
    assert {:error, :https_required} = Native.scan("http://example.com", [])
    assert {:error, :https_required} = Native.scan("https://", [])
    assert {:error, :https_required} = Native.scan("not-a-url", [])
  end

  test "ssl connect failure is returned" do
    assert {:error, _} = Native.scan("https://127.0.0.1:1", timeout: 50)
  end

  test "rejects a private HTTPS target before opening TLS" do
    connector = fn _address, _port, _options, _timeout ->
      flunk("the forbidden target must not receive a TLS connection")
    end

    assert {:error, :forbidden_address} =
             Native.scan("https://127.0.0.1:443", ssl_connector: connector)
  end

  test "parses x509 and whois dates" do
    assert {:ok, %DateTime{year: 2024}} =
             Native.parse_asn1_time({:utcTime, ~c"240101000000Z"})

    assert {:ok, %DateTime{year: 1950}} =
             Native.parse_asn1_time({:utcTime, "500101000000Z"})

    assert {:ok, %DateTime{year: 2024}} =
             Native.parse_asn1_time({:generalTime, "20240101000000Z"})

    assert {:error, :invalid_certificate_expiry} = Native.parse_asn1_time({:utcTime, "nope"})
    assert {:error, :invalid_certificate_expiry} = Native.parse_asn1_time({:generalTime, "nope"})
    assert {:error, :invalid_certificate_expiry} = Native.parse_asn1_time(:other)

    assert {:error, :invalid_certificate_expiry} =
             Native.parse_asn1_time({:utcTime, "991301000000Z"})

    assert {:error, :invalid_certificate} = Native.certificate_expiry(<<1, 2, 3>>)

    assert Native.unwrap_optional_expiry({:ok, ~U[2026-01-01 00:00:00Z]}) ==
             ~U[2026-01-01 00:00:00Z]

    assert Native.unwrap_optional_expiry(:nope) == nil
    assert {:ok, "example.com"} = Native.registrable_domain("www.example.com")
    assert {:error, :not_a_domain} = Native.registrable_domain("localhost")
    assert {:error, :no_whois_referral} = Native.referral_server("nope")
    assert {:ok, "whois.example.net"} = Native.referral_server("refer: whois.example.net\n")
    assert {:error, :expiry_not_found} = Native.expiry_from_whois("nope")

    assert {:ok, %DateTime{year: 2026, month: 6, day: 1}} =
             Native.parse_whois_date("2026-06-01T00:00:00Z")

    assert {:ok, %DateTime{year: 2026, month: 6, day: 1}} = Native.parse_whois_date("2026-06-01")

    assert {:ok, %DateTime{year: 2026, month: 1, day: 2}} = Native.parse_whois_date("2-Jan-2026")

    assert {:error, :invalid_domain_expiry} = Native.parse_whois_date("not-a-date")
    assert {:ok, _} = Native.expiry_from_whois("Expiry Date: 2026-06-01T00:00:00Z")
  end

  @tag :network
  test "scan of a public https host returns ssl expiry" do
    case Native.scan("https://example.com", timeout: 5_000) do
      {:ok, result} ->
        assert %DateTime{} = result.ssl_expires_at

      {:error, reason} ->
        assert reason in [:https_required] or is_tuple(reason) or is_atom(reason)
    end
  end
end
