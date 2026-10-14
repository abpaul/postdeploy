defmodule Alplus.Mcp.Catalog do
  @moduledoc "The transport-neutral MCP operation catalog."

  alias Alplus.Mcp.{Principal, Scope, Tool}

  def all do
    adapters()
    |> Enum.flat_map(& &1.tools())
    |> Enum.map(&Tool.normalize!/1)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Returns the operations visible to a verified principal."
  @spec tools(Principal.t()) :: [Tool.t()]
  def tools(%Principal{} = principal) do
    Enum.filter(all(), &Scope.allowed?(principal, &1))
  end

  @doc "Returns the transport-neutral wire catalog visible to a verified principal."
  @spec wire_tools(Principal.t()) :: [map()]
  def wire_tools(%Principal{} = principal) do
    principal
    |> tools()
    |> Enum.map(&wire_tool/1)
  end

  @spec get(String.t()) :: {:ok, module(), Tool.t()} | {:error, :not_found}
  def get(tool_name) when is_binary(tool_name) do
    prefix = tool_name |> String.split(".", parts: 2) |> List.first()

    Enum.find_value(adapters(), {:error, :not_found}, fn adapter ->
      if adapter.prefix() == prefix do
        case Enum.find(adapter.tools(), &(&1.name == tool_name)) do
          %Tool{} = tool -> {:ok, adapter, Tool.normalize!(tool)}
          _ -> nil
        end
      end
    end)
  end

  defp wire_tool(%Tool{} = tool) do
    %{
      name: tool.name,
      title: tool.title,
      description: tool.description,
      inputSchema: tool.input_schema,
      outputSchema: tool.output_schema,
      annotations: tool.annotations
    }
  end

  defp adapters do
    Application.get_env(:alplus, :mcp_adapters, [])
    |> Enum.filter(fn module ->
      is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :prefix, 0)
    end)
    |> Enum.sort_by(& &1.prefix())
  end
end
