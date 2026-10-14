defmodule AlplusWeb.Plugs.McpHttp do
  @moduledoc "Passes the runtime MCP origin allowlist to ExMCP."

  @behaviour Plug

  @impl true
  def init(opts), do: ExMCP.HttpPlug.init(opts)

  @impl true
  def call(conn, opts) do
    allowed_origins =
      Application.get_env(:alplus, :mcp_allowed_origins, [
        "http://localhost",
        "https://localhost"
      ])

    ExMCP.HttpPlug.call(conn, %{opts | allowed_origins: allowed_origins})
  end
end
