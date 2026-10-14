defmodule Alplus.Monitoring.AnonymousProbeTest do
  use ExUnit.Case, async: true

  alias Alplus.Monitoring.AnonymousProbe
  alias Alplus.Monitoring.AnonymousProbe.Url

  @public {93, 184, 216, 34}

  describe "Url.parse/1" do
    test "accepts http and https on ports 80 and 443" do
      assert {:ok, %URI{scheme: "https", host: "example.com"}} =
               Url.parse("https://example.com/status")

      assert {:ok, %URI{scheme: "http"}} = Url.parse("http://example.com")
    end

    test "rejects credentials, fragments, schemes, and non-http ports" do
      assert {:error, :userinfo} = Url.parse("https://user:pass@example.com/")
      assert {:error, :fragment} = Url.parse("https://example.com/#secret")
      assert {:error, :forbidden_scheme} = Url.parse("ftp://example.com/")
      assert {:error, :forbidden_port} = Url.parse("https://example.com:8443/")
      assert {:error, :malformed_host} = Url.parse("https://exa mple.com/")

      assert {:error, :url_too_long} =
               Url.parse("https://example.com/" <> String.duplicate("a", 3_000))
    end

    test "a bare host or a scheme-less path is checked over HTTPS" do
      assert {:ok, %URI{scheme: "https", host: "superbeinglabs.org", path: "/"}} =
               Url.parse("superbeinglabs.org")

      assert {:ok, %URI{scheme: "https", host: "example.com", path: "/status"}} =
               Url.parse("  example.com/status  ")

      assert {:ok, %URI{scheme: "https", host: "example.com"}} = Url.parse("//example.com")
      assert {:error, :forbidden_scheme} = Url.parse("ftp://example.com/")
      assert {:error, :forbidden_port} = Url.parse("example.com:8443/")
    end
  end

  test "a successful HTTP result includes status, time, hops, and DNS answers" do
    request = fn opts ->
      assert Keyword.get(opts, :method) == :get
      assert Keyword.get(opts, :url) == "http://93.184.216.34/"
      assert {"host", "public.example.test"} in Keyword.get(opts, :headers)

      refute Enum.any?(Keyword.get(opts, :headers), fn {name, _} ->
               name in ["cookie", "authorization"]
             end)

      {:ok,
       %{
         status: 200,
         headers: [
           {"server", "cloudflare"},
           {"content-type", "text/html; charset=utf-8"},
           {"set-cookie", "session=secret"}
         ],
         body: "ok"
       }}
    end

    resolver = fn "public.example.test" -> {:ok, [@public]} end

    assert {:ok, result} =
             AnonymousProbe.run("http://public.example.test/", nil,
               resolver: resolver,
               request: request
             )

    assert result.outcome == :ok
    assert result.final_status == 200
    assert is_integer(result.elapsed_ms)
    assert [%{host: "public.example.test", addresses: ["93.184.216.34"]}] = result.dns_answers
    assert [%{url: "http://public.example.test/", status: 200}] = result.hops
    assert result.tls == nil
    assert result.keyword == nil
    assert result.body_bytes == 2

    assert result.headers == %{
             "server" => "cloudflare",
             "content-type" => "text/html; charset=utf-8"
           }

    refute Map.has_key?(result.headers, "set-cookie")
  end

  test "HTTPS records a trust verdict and certificate expiry" do
    expires_at = ~U[2027-01-01 00:00:00Z]

    tls = fn "secure.example.test", @public, 443, _timeout ->
      {:ok, %{trusted: true, expires_at: expires_at}}
    end

    request = fn _opts -> {:ok, %{status: 200, headers: [], body: "ok"}} end
    resolver = fn "secure.example.test" -> {:ok, [@public]} end

    assert {:ok, result} =
             AnonymousProbe.run("https://secure.example.test/", nil,
               resolver: resolver,
               request: request,
               tls: tls
             )

    assert result.tls == %{trusted: true, expires_at: expires_at}
  end

  test "keyword match and mismatch search bounded bytes as plain text" do
    request = fn _opts -> {:ok, %{status: 200, headers: [], body: "Status: healthy"}} end
    resolver = fn "public.example.test" -> {:ok, [@public]} end

    assert {:ok, %{keyword: %{value: "healthy", matched: true}}} =
             AnonymousProbe.run("http://public.example.test/", "healthy",
               resolver: resolver,
               request: request
             )

    assert {:ok, %{keyword: %{value: "Healthy", matched: false}}} =
             AnonymousProbe.run("http://public.example.test/", "Healthy",
               resolver: resolver,
               request: request
             )
  end

  test "follows a redirect chain and keeps hop records" do
    test_pid = self()

    request = fn opts ->
      send(test_pid, {:request, Keyword.get(opts, :url)})

      case Keyword.get(opts, :url) do
        "http://93.184.216.34/" ->
          {:ok,
           %{status: 301, headers: [{"location", "http://public.example.test/app"}], body: ""}}

        "http://93.184.216.34/app" ->
          {:ok, %{status: 200, headers: [], body: "ok"}}
      end
    end

    resolver = fn "public.example.test" -> {:ok, [@public]} end

    assert {:ok, result} =
             AnonymousProbe.run("http://public.example.test/", nil,
               resolver: resolver,
               request: request
             )

    assert result.final_status == 200
    assert length(result.hops) == 2
    assert_receive {:request, "http://93.184.216.34/"}
    assert_receive {:request, "http://93.184.216.34/app"}
  end

  test "rejects mixed DNS answers before connecting" do
    request = fn _opts -> flunk("mixed DNS must not connect") end
    resolver = fn "mixed.example.test" -> {:ok, [@public, {10, 0, 0, 1}]} end

    assert {:ok, %{outcome: :forbidden_address, hops: []}} =
             AnonymousProbe.run("http://mixed.example.test/", nil,
               resolver: resolver,
               request: request
             )
  end

  test "rejects a private IP literal" do
    request = fn _opts -> flunk("loopback must not connect") end

    assert {:ok, %{outcome: :forbidden_address}} =
             AnonymousProbe.run("http://127.0.0.1/", nil, request: request)
  end

  test "rejects DNS rebinding on a later hop" do
    test_pid = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    resolver = fn "rebind.example.test" ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

      if n == 0 do
        {:ok, [@public]}
      else
        {:ok, [{127, 0, 0, 1}]}
      end
    end

    request = fn opts ->
      send(test_pid, {:request, Keyword.get(opts, :url)})
      {:ok, %{status: 302, headers: [{"location", "http://rebind.example.test/next"}], body: ""}}
    end

    assert {:ok, result} =
             AnonymousProbe.run("http://rebind.example.test/", nil,
               resolver: resolver,
               request: request
             )

    assert result.outcome == :forbidden_address
    assert_receive {:request, "http://93.184.216.34/"}
    refute_receive {:request, "http://127.0.0.1/next"}
  end

  test "rejects a redirect that escapes to a forbidden port" do
    request = fn _opts ->
      {:ok,
       %{status: 302, headers: [{"location", "https://public.example.test:8443/admin"}], body: ""}}
    end

    resolver = fn "public.example.test" -> {:ok, [@public]} end

    assert {:ok, %{outcome: :forbidden_port}} =
             AnonymousProbe.run("http://public.example.test/", nil,
               resolver: resolver,
               request: request
             )
  end

  test "timeout and oversized bodies are bounded failures" do
    resolver = fn "public.example.test" -> {:ok, [@public]} end

    timeout_request = fn _opts -> {:error, :timeout} end

    assert {:ok, %{outcome: :timeout}} =
             AnonymousProbe.run("http://public.example.test/", nil,
               resolver: resolver,
               request: timeout_request
             )

    oversized = fn _opts ->
      {:ok, %{status: 200, headers: [], body: :binary.copy("x", 256 * 1024 + 1)}}
    end

    assert {:ok, %{outcome: :response_too_large}} =
             AnonymousProbe.run("http://public.example.test/", nil,
               resolver: resolver,
               request: oversized
             )
  end

  test "untrusted TLS is a bounded failure and skips an unverified fetch" do
    tls = fn _host, _address, _port, _timeout -> {:error, :tls_untrusted} end
    request = fn _opts -> flunk("untrusted TLS must not fetch") end
    resolver = fn "bad-tls.example.test" -> {:ok, [@public]} end

    assert {:ok, %{outcome: :tls_untrusted, tls: %{trusted: false}}} =
             AnonymousProbe.run("https://bad-tls.example.test/", nil,
               resolver: resolver,
               request: request,
               tls: tls
             )
  end

  test "validation errors do not start a probe" do
    request = fn _opts -> flunk("invalid input must not connect") end

    assert {:error, :forbidden_scheme} =
             AnonymousProbe.run("file:///etc/passwd", nil, request: request)
  end
end
