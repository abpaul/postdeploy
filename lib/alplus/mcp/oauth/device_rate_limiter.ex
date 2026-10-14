defmodule Alplus.Mcp.OAuth.DeviceRateLimiter do
  @moduledoc """
  Per-address limits for the two device-flow entry points.

  `POST /oauth/device_authorization` needs no credentials and writes a row, so
  one host could otherwise fill the table at request rate. `POST /activate`
  answers whether a user code exists, so it is a guessing oracle. RFC 8628
  section 5.2 requires a limit on the second; the first is ordinary abuse
  protection.
  """

  use Hammer, backend: :ets, algorithm: :sliding_window

  @window_ms :timer.minutes(1)
  @authorization_requests_per_minute 30
  @user_code_attempts_per_minute 10

  @spec check_authorization(:inet.ip_address() | nil) :: :ok | {:error, pos_integer()}
  def check_authorization(address),
    do: limit("mcp_device_authorization", address, @authorization_requests_per_minute)

  @spec check_user_code(:inet.ip_address() | nil) :: :ok | {:error, pos_integer()}
  def check_user_code(address),
    do: limit("mcp_device_user_code", address, @user_code_attempts_per_minute)

  defp limit(bucket, address, allowed) do
    case hit(bucket <> ":" <> key(address), @window_ms, allowed) do
      {:allow, _count} -> :ok
      {:deny, retry_after} -> {:error, max(1, ceil(retry_after / 1_000))}
    end
  end

  defp key(nil), do: "unknown"
  defp key(address), do: address |> :inet.ntoa() |> to_string()
end
