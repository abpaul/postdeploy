defmodule Alplus.Mcp.ToolSpec do
  @moduledoc "Builds the MCP tool descriptions and JSON schemas shared by the pillar adapters."

  alias Alplus.Mcp.Tool

  @doc "Builds a read-only tool."
  @spec read_tool(String.t(), String.t(), String.t(), map(), map()) :: Tool.t()
  def read_tool(name, title, description, input_schema, output_schema) do
    %Tool{
      name: name,
      title: title,
      description: description,
      input_schema: input_schema,
      output_schema: output_schema,
      annotations: %{readOnlyHint: true},
      cost_weight: 1,
      requires_access: :read
    }
  end

  @doc "Builds a mutation tool. The caller supplies the tool annotations."
  @spec mutation_tool(String.t(), String.t(), String.t(), map(), map(), map()) :: Tool.t()
  def mutation_tool(name, title, description, input_schema, output_schema, annotations) do
    %Tool{
      name: name,
      title: title,
      description: description,
      input_schema: input_schema,
      output_schema: output_schema,
      annotations: annotations,
      cost_weight: 2,
      requires_access: :read_write
    }
  end

  @doc "Builds a closed object schema that requires the listed properties."
  @spec strict_object(map(), [String.t()]) :: map()
  def strict_object(properties, required) do
    %{
      type: "object",
      properties: properties,
      required: required,
      additionalProperties: false
    }
  end

  @doc "Builds a closed object schema that requires every property."
  @spec object_schema(map()) :: map()
  def object_schema(properties),
    do: strict_object(properties, properties |> Map.keys() |> Enum.map(&to_string/1))

  @doc "Builds a bounded string schema."
  @spec string(non_neg_integer(), pos_integer()) :: map()
  def string(minimum, maximum), do: %{type: "string", minLength: minimum, maxLength: maximum}

  @doc "Builds a schema for a string that may be null."
  @spec nullable_string() :: map()
  def nullable_string, do: %{type: ["string", "null"]}
end
