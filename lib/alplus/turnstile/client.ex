defmodule Alplus.Turnstile.Client do
  @moduledoc """
  Client for Cloudflare's Turnstile siteverify endpoint.

  Calls Cloudflare's siteverify endpoint. Never logs the secret or the
  token.
  """
  @verify_url "https://challenges.cloudflare.com/turnstile/v0/siteverify"

  def verify(token, remote_ip) when is_binary(token) and byte_size(token) in 1..2048 do
    form = [{"secret", secret()}, {"response", token}] ++ ip_field(remote_ip)

    request()
    |> Req.post(url: @verify_url, form: form)
    |> handle_response()
  end

  def verify(_token, _remote_ip), do: {:ok, false}

  defp ip_field(nil), do: []
  defp ip_field(ip) when is_tuple(ip), do: [{"remoteip", ip |> :inet.ntoa() |> to_string()}]
  defp ip_field(ip), do: [{"remoteip", ip}]

  defp request do
    Req.new(receive_timeout: timeout_ms(), retry: false)
    |> maybe_plug()
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: %{"success" => success}}}) do
    {:ok, success == true}
  end

  defp handle_response({:ok, %Req.Response{status: status}}) do
    {:error, {:unexpected_status, status}}
  end

  defp handle_response({:error, reason}), do: {:error, reason}

  defp secret do
    Application.get_env(:alplus, :turnstile_secret) ||
      raise "missing config :alplus, :turnstile_secret"
  end

  defp timeout_ms, do: Application.get_env(:alplus, :turnstile_timeout_ms, 3_000)

  defp maybe_plug(req) do
    case Application.get_env(:alplus, :turnstile_req_plug) do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end
end
