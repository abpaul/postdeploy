defmodule Alplus.Accounts.Hibp.Client do
  @moduledoc """
  Client for the Have I Been Pwned Pwned Passwords range API.

  Sends only the first 5 hex characters of the password's SHA-1 hash to
  the Have I Been Pwned range API (k-anonymity) — never the password,
  never the full hash. See https://haveibeenpwned.com/API/v3#PwnedPasswords.

  Warning: never log the password, the hash, or the response body.
  """

  @base_url "https://api.pwnedpasswords.com"

  def pwned?(password) when is_binary(password) do
    <<prefix::binary-size(5), suffix::binary-size(35)>> =
      :sha |> :crypto.hash(password) |> Base.encode16(case: :upper)

    request()
    |> Req.get(url: "/range/#{prefix}")
    |> handle_response(suffix)
  end

  defp request do
    Req.new(
      base_url: @base_url,
      receive_timeout: timeout_ms(),
      connect_options: [timeout: timeout_ms()],
      retry: false,
      headers: [{"add-padding", "true"}]
    )
    |> maybe_plug()
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}, suffix) do
    breached? =
      body
      |> to_string()
      |> String.split("\r\n", trim: true)
      |> Enum.any?(fn line ->
        case String.split(line, ":", parts: 2) do
          [hash_suffix, _count] -> hash_suffix == suffix
          _ -> false
        end
      end)

    {:ok, breached?}
  end

  defp handle_response({:ok, %Req.Response{status: status}}, _suffix) do
    {:error, {:unexpected_status, status}}
  end

  defp handle_response({:error, reason}, _suffix) do
    {:error, reason}
  end

  defp timeout_ms, do: Application.get_env(:alplus, :hibp_timeout_ms, 3_000)

  defp maybe_plug(req) do
    case Application.get_env(:alplus, :hibp_req_plug) do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end
end
