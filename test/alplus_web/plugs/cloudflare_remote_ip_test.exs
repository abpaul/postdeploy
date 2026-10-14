defmodule AlplusWeb.Plugs.CloudflareRemoteIpTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias AlplusWeb.Plugs.CloudflareRemoteIp

  test "uses one valid Cloudflare visitor IP" do
    conn =
      :get
      |> conn("/")
      |> Map.put(:remote_ip, {10, 0, 0, 7})
      |> put_req_header("cf-connecting-ip", "203.0.113.7")
      |> CloudflareRemoteIp.call([])

    assert conn.remote_ip == {203, 0, 113, 7}
  end

  test "keeps the socket IP for malformed or ambiguous headers" do
    for header <- ["not-an-ip", "203.0.113.7, 198.51.100.8", <<255>>] do
      conn =
        :get
        |> conn("/")
        |> Map.put(:remote_ip, {10, 0, 0, 7})
        |> put_req_header("cf-connecting-ip", header)
        |> CloudflareRemoteIp.call([])

      assert conn.remote_ip == {10, 0, 0, 7}
    end
  end

  test "keeps the socket IP when the header appears more than once" do
    conn =
      :get
      |> conn("/")
      |> Map.put(:remote_ip, {10, 0, 0, 7})
      |> Map.put(:req_headers, [
        {"cf-connecting-ip", "203.0.113.7"},
        {"cf-connecting-ip", "198.51.100.8"}
      ])
      |> CloudflareRemoteIp.call([])

    assert conn.remote_ip == {10, 0, 0, 7}
  end
end
