defmodule Alplus.Mcp.Adapter do
  @moduledoc "Behaviour implemented by each independent MCP pillar adapter."

  alias Alplus.Mcp.Principal
  alias Alplus.Mcp.Tool

  @callback prefix() :: String.t()
  @callback tools() :: [Tool.t()]
  @callback call(String.t(), map(), Principal.t()) ::
              {:ok, map()} | {:error, Alplus.Mcp.Error.t()}
end
