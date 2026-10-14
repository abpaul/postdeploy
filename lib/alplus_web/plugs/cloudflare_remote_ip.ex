defmodule AlplusWeb.Plugs.CloudflareRemoteIp do
  @moduledoc """
  Restores the visitor IP that Cloudflare sends to the origin.

  Cloudflare Tunnel is the only public path to the application, so this
  header is trusted here. Requests without exactly one valid IP keep the
  socket address.
  """

  @behaviour Plug
  @header "cf-connecting-ip"

  import Plug.Conn, only: [get_req_header: 2]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case conn |> get_req_header(@header) |> parse() do
      {:ok, remote_ip} -> %{conn | remote_ip: remote_ip}
      :error -> conn
    end
  end

  @doc """
  The visitor IP for a LiveView socket, which never passes through the plug
  pipeline. `connect_info` carries the tunnel header in `:x_headers` and the
  socket address in `:peer_data`; the header wins for the same reason it wins
  above. Returns `nil` when neither is available, which a caller treats as an
  unidentified client rather than as a trusted one.
  """
  @spec connect_ip(map()) :: :inet.ip_address() | nil
  def connect_ip(connect_info) when is_map(connect_info) do
    case connect_info |> header_values() |> parse() do
      {:ok, remote_ip} -> remote_ip
      :error -> peer_address(connect_info)
    end
  end

  def connect_ip(_connect_info), do: nil

  defp header_values(%{x_headers: headers}) when is_list(headers) do
    for {name, value} <- headers, String.downcase(to_string(name)) == @header, do: value
  end

  defp header_values(_connect_info), do: []

  defp peer_address(%{peer_data: %{address: address}}), do: address
  defp peer_address(_connect_info), do: nil

  defp parse([header]) when is_binary(header) do
    with true <- String.valid?(header),
         false <- String.contains?(header, ","),
         {:ok, remote_ip} <- :inet.parse_address(String.to_charlist(header)) do
      {:ok, remote_ip}
    else
      _ -> :error
    end
  end

  defp parse(_headers), do: :error
end
