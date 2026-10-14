defmodule AlplusWeb.Plugs.RedactHeartbeatToken do
  @moduledoc "Redacts a heartbeat bearer before request capture and completion logs."

  def init(opts), do: opts

  def call(%{path_info: ["h", token | _rest]} = conn, _opts) when is_binary(token) do
    %{conn | request_path: String.replace(conn.request_path, token, "[FILTERED]")}
  end

  def call(conn, _opts), do: conn
end
