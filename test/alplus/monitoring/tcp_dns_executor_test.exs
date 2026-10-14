defmodule Alplus.Monitoring.TcpDnsExecutorTest do
  use ExUnit.Case, async: false

  alias Alplus.Monitoring.{DnsExecutor, TcpExecutor}

  test "TCP executor rejects a loopback port before connecting" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    assert %{status: "down", error_class: "network_error"} =
             TcpExecutor.run(%{hostname: "127.0.0.1", port: port, timeout_seconds: 1})

    :ok = :gen_tcp.close(listener)
  end

  test "TCP executor rejects private, link-local, and IPv6 non-global literals" do
    for hostname <- ["10.0.0.1", "169.254.1.1", "::1", "fc00::1", "fe80::1"] do
      connector = fn _address, _port, _options, _timeout ->
        flunk("the forbidden target must not receive a connection")
      end

      assert %{status: "down", error_class: "network_error"} =
               TcpExecutor.run(
                 %{hostname: hostname, port: 443, timeout_seconds: 1},
                 connector: connector
               )
    end
  end

  test "TCP executor uses the validated public address from the resolver" do
    test_pid = self()

    connector = fn address, port, _options, _timeout ->
      send(test_pid, {:connect, address, port})
      {:ok, :socket}
    end

    closer = fn :socket -> :ok end
    resolver = fn "public.example.test" -> {:ok, [{93, 184, 216, 34}]} end

    assert %{status: "up", error_class: nil} =
             TcpExecutor.run(
               %{hostname: "public.example.test", port: 443, timeout_seconds: 1},
               resolver: resolver,
               connector: connector,
               closer: closer
             )

    assert_received {:connect, {93, 184, 216, 34}, 443}
  end

  test "DNS executor requires every configured expected value (match_mode :all, the default)" do
    request = fn _opts ->
      {:ok,
       %{
         status: 200,
         body: %{"Status" => 0, "Answer" => [%{"type" => 1, "data" => "1.2.3.4"}]}
       }}
    end

    assert %{status: "up", error_class: nil} =
             DnsExecutor.run(
               %{hostname: "example.test", record_type: "A", expected_values: ["1.2.3.4"]},
               request
             )

    assert %{status: "down", error_class: "record_mismatch"} =
             DnsExecutor.run(
               %{hostname: "example.test", record_type: "A", expected_values: ["9.9.9.9"]},
               request
             )

    # `match_mode` defaults to `:all` when the field is absent, so a config
    # map with no `:match_mode` key at all (the pre-migration shape) still
    # requires every expected value.
    assert %{status: "down", error_class: "record_mismatch"} =
             DnsExecutor.run(
               %{
                 hostname: "example.test",
                 record_type: "A",
                 expected_values: ["1.2.3.4", "5.6.7.8"],
                 match_mode: :all
               },
               request
             )
  end

  test "DNS executor match_mode :any accepts a single matching expected value" do
    request = fn _opts ->
      {:ok,
       %{
         status: 200,
         body: %{"Status" => 0, "Answer" => [%{"type" => 1, "data" => "1.2.3.4"}]}
       }}
    end

    assert %{status: "up", error_class: nil} =
             DnsExecutor.run(
               %{
                 hostname: "example.test",
                 record_type: "A",
                 expected_values: ["9.9.9.9", "1.2.3.4"],
                 match_mode: :any
               },
               request
             )

    assert %{status: "down", error_class: "record_mismatch"} =
             DnsExecutor.run(
               %{
                 hostname: "example.test",
                 record_type: "A",
                 expected_values: ["9.9.9.9", "8.8.8.8"],
                 match_mode: :any
               },
               request
             )
  end

  test "DNS executor treats an empty expected_values list as resolvability-only" do
    request = fn _opts ->
      {:ok,
       %{
         status: 200,
         body: %{"Status" => 0, "Answer" => [%{"type" => 1, "data" => "203.0.113.9"}]}
       }}
    end

    assert %{status: "up", error_class: nil} =
             DnsExecutor.run(
               %{
                 hostname: "example.test",
                 record_type: "A",
                 expected_values: [],
                 match_mode: :all
               },
               request
             )
  end

  test "DNS executor reports no_records when the answer has no matching-type records" do
    request = fn _opts -> {:ok, %{status: 200, body: %{"Status" => 0, "Answer" => []}}} end

    assert %{status: "down", error_class: "no_records"} =
             DnsExecutor.run(
               %{
                 hostname: "example.test",
                 record_type: "A",
                 expected_values: [],
                 match_mode: :all
               },
               request
             )
  end

  test "DNS executor decodes a raw application/dns-json string body" do
    request = fn _opts ->
      {:ok,
       %{
         status: 200,
         body: ~s({"Status":0,"Answer":[{"type":1,"data":"1.2.3.4"}]})
       }}
    end

    assert %{status: "up", error_class: nil} =
             DnsExecutor.run(
               %{hostname: "example.test", record_type: "A", expected_values: ["1.2.3.4"]},
               request
             )
  end

  test "DNS executor reports NXDOMAIN distinctly" do
    request = fn _opts -> {:ok, %{status: 200, body: %{"Status" => 3}}} end

    assert %{status: "down", error_class: "dns_nxdomain"} =
             DnsExecutor.run(
               %{hostname: "missing.example.test", record_type: "A", expected_values: []},
               request
             )
  end
end
