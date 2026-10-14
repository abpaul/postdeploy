defmodule AlplusWeb.Plugs.HeartbeatRateLimit do
  @moduledoc "Absolute per-token safety limit for public heartbeat writes."

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{path_params: %{"token" => token}} = conn, _opts) do
    case Alplus.Monitoring.HeartbeatRateLimiter.check(token) do
      :ok ->
        conn

      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_resp(429, "")
        |> halt()
    end
  end

  def call(conn, _opts), do: conn
end
