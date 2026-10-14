defmodule Alplus.Monitoring.TcpExecutor do
  @moduledoc false

  def run(config, opts \\ []) do
    started = System.monotonic_time(:millisecond)
    timeout = config.timeout_seconds * 1_000

    resolver = Keyword.get(opts, :resolver)
    connector = Keyword.get(opts, :connector, &:gen_tcp.connect/4)
    closer = Keyword.get(opts, :closer, &:gen_tcp.close/1)

    result =
      with {:ok, address} <- Alplus.Monitoring.PublicAddress.resolve(config.hostname, resolver) do
        connector.(address, config.port, [:binary, active: false], timeout)
      end

    latency = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, socket} ->
        :ok = closer.(socket)
        %{status: "up", status_code: nil, latency_ms: latency, error_class: nil}

      {:error, :timeout} ->
        %{status: "down", status_code: nil, latency_ms: latency, error_class: "timeout"}

      {:error, reason} when reason in [:forbidden_address, :dns_error] ->
        %{status: "down", status_code: nil, latency_ms: latency, error_class: "network_error"}

      {:error, _reason} ->
        %{
          status: "down",
          status_code: nil,
          latency_ms: latency,
          error_class: "connection_refused"
        }
    end
  end
end
