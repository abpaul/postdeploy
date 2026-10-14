defmodule AlplusWeb.Plugs.AuthTurnstile do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  @sign_in_path ["auth", "user", "password", "sign_in"]

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST", path_info: @sign_in_path} = conn, _opts) do
    verify(conn)
  end

  def call(
        %Plug.Conn{method: "POST", path_info: ["auth", "user", "password", "sign_in", ""]} = conn,
        _opts
      ) do
    verify(conn)
  end

  def call(conn, _opts), do: conn

  defp verify(conn) do
    token = token_from_params(conn.params)

    case Alplus.Turnstile.Client.verify(token, remote_ip(conn)) do
      {:ok, true} -> strip_token(conn)
      _ -> reject(conn)
    end
  end

  defp token_from_params(%{"user" => user}) when is_map(user),
    do: Map.get(user, "turnstile_token")

  defp token_from_params(_params), do: nil

  defp strip_token(%Plug.Conn{} = conn) do
    params = update_in(conn.params, ["user"], &Map.delete(&1 || %{}, "turnstile_token"))
    body_params = update_in(conn.body_params, ["user"], &Map.delete(&1 || %{}, "turnstile_token"))
    %{conn | params: params, body_params: body_params}
  end

  defp reject(conn) do
    conn
    |> put_flash(:error, "Security check failed. Please try again.")
    |> redirect(to: "/sign-in")
    |> halt()
  end

  defp remote_ip(%Plug.Conn{remote_ip: {a, b, c, d}}), do: Enum.join([a, b, c, d], ".")
  defp remote_ip(%Plug.Conn{remote_ip: ip}), do: :inet.ntoa(ip) |> to_string()
end
