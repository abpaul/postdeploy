defmodule Alplus.Monitoring.HttpExecutorTest do
  use ExUnit.Case, async: true

  alias Alplus.Monitoring.HttpExecutor

  test "evaluate covers status, keyword, slow, and up paths" do
    base = %{
      expected_status: %{"kind" => "range", "min" => 200, "max" => 299},
      keyword_match: nil,
      response_time_threshold_ms: nil
    }

    assert %{status: "down", error_class: "unexpected_status"} =
             HttpExecutor.evaluate(base, 500, "ok", 1)

    assert %{status: "down", error_class: "keyword_not_matched"} =
             HttpExecutor.evaluate(
               Map.put(base, :keyword_match, %{"mode" => "contains", "value" => "needle"}),
               200,
               "haystack",
               1
             )

    assert %{status: "degraded", error_class: "response_time_threshold"} =
             HttpExecutor.evaluate(
               base
               |> Map.put(:response_time_threshold_ms, 5)
               |> Map.put(:keyword_match, nil),
               200,
               "ok",
               50
             )

    assert %{status: "up"} = HttpExecutor.evaluate(base, 200, "ok", 1)

    assert %{status: "down"} =
             HttpExecutor.evaluate(
               %{
                 expected_status: %{"kind" => "list", "values" => [201]},
                 keyword_match: nil,
                 response_time_threshold_ms: nil
               },
               200,
               "",
               1
             )

    assert %{status: "up"} =
             HttpExecutor.evaluate(
               %{expected_status: nil, keyword_match: nil, response_time_threshold_ms: nil},
               200,
               "",
               1
             )

    assert %{status: "down"} =
             HttpExecutor.evaluate(
               Map.put(base, :keyword_match, %{"mode" => "other"}),
               200,
               "x",
               1
             )

    assert %{status: "up"} =
             HttpExecutor.evaluate(
               Map.put(base, :keyword_match, %{
                 "mode" => "not_contains",
                 "value" => "needle",
                 "scanBytes" => 2048
               }),
               200,
               "haystack",
               1
             )

    assert %{status: "down"} =
             HttpExecutor.evaluate(
               Map.put(base, :keyword_match, %{
                 "mode" => "contains",
                 "value" => "needle",
                 "scan_bytes" => "bad"
               }),
               200,
               :not_binary,
               1
             )

    assert %{status: "up"} =
             HttpExecutor.evaluate(
               %{
                 expected_status: %{"kind" => "nope"},
                 keyword_match: nil,
                 response_time_threshold_ms: "x"
               },
               200,
               "ok",
               1
             )
  end

  test "run hits the network error path" do
    result =
      HttpExecutor.run(%{
        method: "GET",
        url: "http://127.0.0.1:1/",
        headers: %{"x-test" => "1"},
        body: nil,
        follow_redirects: false,
        max_redirects: 0,
        timeout_seconds: 1,
        expected_status: %{"kind" => "range", "min" => 200, "max" => 299}
      })

    assert result.status == "down"
    assert result.error_class == "network_error"
  end

  test "run rejects non-global IPv4 and IPv6 literals before making a request" do
    for url <- [
          "http://127.0.0.1/",
          "http://10.0.0.1/",
          "http://169.254.1.1/",
          "http://[::1]/",
          "http://[fc00::1]/",
          "http://[fe80::1]/"
        ] do
      request = fn _opts -> flunk("the forbidden target must not receive a request") end

      assert %{status: "down", error_class: "network_error"} =
               HttpExecutor.run(http_config(url), request: request)
    end
  end

  test "run rejects a DNS result when any resolved address is non-global" do
    request = fn _opts -> flunk("the forbidden DNS result must not receive a request") end
    resolver = fn "mixed.example.test" -> {:ok, [{93, 184, 216, 34}, {10, 0, 0, 1}]} end

    assert %{status: "down", error_class: "network_error"} =
             HttpExecutor.run(http_config("http://mixed.example.test/"),
               resolver: resolver,
               request: request
             )
  end

  test "run validates every redirect target" do
    test_pid = self()

    request = fn opts ->
      send(test_pid, {:request, Keyword.get(opts, :url)})

      {:ok,
       %{
         status: 302,
         headers: [{"location", "http://127.0.0.1/private"}],
         body: ""
       }}
    end

    resolver = fn "public.example.test" -> {:ok, [{93, 184, 216, 34}]} end

    assert %{status: "down", error_class: "network_error"} =
             HttpExecutor.run(http_config("http://public.example.test/"),
               resolver: resolver,
               request: request
             )

    assert_receive {:request, "http://93.184.216.34/"}
    refute_receive {:request, "http://127.0.0.1/private"}
  end

  test "run changes POST to GET and drops the body headers for 302 redirects" do
    test_pid = self()

    request = fn opts ->
      send(test_pid, {:request, opts})

      case Keyword.get(opts, :method) do
        :post -> {:ok, %{status: 302, headers: [{"location", "/next"}], body: ""}}
        :get -> {:ok, %{status: 200, headers: [], body: "ok"}}
      end
    end

    config =
      http_config("http://public.example.test/")
      |> Map.merge(%{
        method: "POST",
        body: "abc",
        headers: %{"content-type" => "application/json", "content-length" => "3"}
      })

    resolver = fn "public.example.test" -> {:ok, [{93, 184, 216, 34}]} end

    assert %{status: "up"} = HttpExecutor.run(config, resolver: resolver, request: request)

    assert_receive {:request, first}
    assert Keyword.get(first, :method) == :post
    assert Keyword.get(first, :body) == "abc"

    assert_receive {:request, second}
    assert Keyword.get(second, :method) == :get
    assert Keyword.get(second, :body) == nil
    refute {"content-type", "application/json"} in Keyword.get(second, :headers)
    refute {"content-length", "3"} in Keyword.get(second, :headers)
  end

  test "run preserves POST method and body headers for 307 redirects" do
    test_pid = self()
    request_count = :atomics.new(1, [])

    request = fn opts ->
      send(test_pid, {:request, opts})

      case :atomics.add_get(request_count, 1, 1) do
        1 -> {:ok, %{status: 307, headers: [{"location", "/next"}], body: ""}}
        2 -> {:ok, %{status: 200, headers: [], body: "ok"}}
      end
    end

    config =
      http_config("http://public.example.test/")
      |> Map.merge(%{
        method: "POST",
        body: "abc",
        headers: %{"content-type" => "application/json", "content-length" => "3"}
      })

    resolver = fn "public.example.test" -> {:ok, [{93, 184, 216, 34}]} end

    assert %{status: "up"} = HttpExecutor.run(config, resolver: resolver, request: request)

    assert_receive {:request, first}
    assert Keyword.get(first, :method) == :post
    assert Keyword.get(first, :body) == "abc"

    assert_receive {:request, second}
    assert Keyword.get(second, :method) == :post
    assert Keyword.get(second, :body) == "abc"
    assert {"content-type", "application/json"} in Keyword.get(second, :headers)
    assert {"content-length", "3"} in Keyword.get(second, :headers)
  end

  test "run connects to an injected public address while retaining the hostname" do
    test_pid = self()

    request = fn opts ->
      send(test_pid, opts)
      {:ok, %{status: 200, headers: [], body: "ok"}}
    end

    resolver = fn "public.example.test" -> {:ok, [{93, 184, 216, 34}]} end

    assert %{status: "up"} =
             HttpExecutor.run(http_config("https://public.example.test/health"),
               resolver: resolver,
               request: request
             )

    assert_received opts when is_list(opts)
    assert Keyword.get(opts, :url) == "https://93.184.216.34/health"
    assert Keyword.get(opts, :connect_options)[:hostname] == "public.example.test"
    assert {"host", "public.example.test"} in Keyword.get(opts, :headers)
  end

  defp http_config(url) do
    %{
      method: "GET",
      url: url,
      headers: %{},
      body: nil,
      follow_redirects: true,
      max_redirects: 3,
      timeout_seconds: 1,
      expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
      keyword_match: nil,
      response_time_threshold_ms: nil
    }
  end
end
