defmodule Alplus.Mcp.Tool do
  @moduledoc """
  Canonical metadata for one registered MCP operation.

  ## Safety classes

  A tool carries one of four classes, and the class decides which gateway a
  caller must route through. `classify/1` derives it from the established
  annotations unless the tool sets `:safety_class` outright.

    * `:read` — returns data and changes nothing.
    * `:write` — changes state that stays inside the organization.
    * `:publish` — creates, rotates, or exposes something usable from outside
      the organization: a public URL, or an ingest credential that will live in
      a third-party property such as the customer's own site or application.
    * `:destructive` — removes or invalidates something a caller cannot
      recreate by repeating the call.

  `:publish` is the boundary class. Ask one question: after this call, can
  somebody outside the organization reach or use something they could not
  before? Issuing an ingest secret answers yes, because the secret leaves for a
  third-party property. Resolving an issue answers no, however visible it is
  inside the console.

  Annotate a `:publish` tool with `openWorldHint: true`, which is the same
  boundary MCP's own hint describes. A `:destructive` tool adds
  `destructiveHint: true` and outranks `:publish`.

  Changing a tool's class is a wire-contract change. A caller that routes an
  action through `actions.publish` today gets `safety_class_mismatch` once that
  action becomes a `:write`, and the reverse holds too.
  """

  @safety_classes [:read, :write, :publish, :destructive]

  @enforce_keys [
    :name,
    :title,
    :description,
    :input_schema,
    :output_schema,
    :annotations,
    :requires_access
  ]
  defstruct [
    :name,
    :title,
    :description,
    :input_schema,
    :output_schema,
    :annotations,
    :requires_access,
    safety_class: nil,
    audit_subject: nil,
    prerequisites: [],
    examples: [],
    cost_weight: 1,
    tenancy: :project
  ]

  @type safety_class :: :read | :write | :publish | :destructive
  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t(),
          description: String.t(),
          input_schema: map(),
          output_schema: map(),
          annotations: map(),
          requires_access: :read | :read_write,
          safety_class: safety_class() | nil,
          audit_subject: String.t() | nil,
          prerequisites: [String.t()],
          examples: [map()],
          cost_weight: pos_integer(),
          tenancy: :project | :organization
        }

  @doc "Returns the supported server-owned safety classes."
  @spec safety_classes() :: [safety_class()]
  def safety_classes, do: @safety_classes

  @doc "Returns the normalized safety class for a tool."
  @spec safety_class(t()) :: safety_class()
  def safety_class(%__MODULE__{} = tool) do
    tool
    |> normalize()
    |> case do
      {:ok, normalized} -> normalized.safety_class
      {:error, reason} -> raise ArgumentError, "invalid MCP tool metadata: #{inspect(reason)}"
    end
  end

  @doc "Normalizes established annotations into canonical metadata."
  @spec normalize(t()) :: {:ok, t()} | {:error, term()}
  def normalize(%__MODULE__{} = tool) do
    with {:ok, safety} <- classify(tool),
         :ok <- validate_metadata(tool, safety) do
      {:ok,
       %{
         tool
         | safety_class: safety,
           audit_subject: tool.audit_subject || tool.name,
           prerequisites: normalize_prerequisites(tool.prerequisites, tool.input_schema),
           examples: normalize_examples(tool.examples)
       }}
    end
  end

  def normalize(_tool), do: {:error, :not_a_tool}

  @doc "Normalizes tool metadata or raises for a broken registry entry."
  @spec normalize!(t()) :: t()
  def normalize!(%__MODULE__{} = tool) do
    case normalize(tool) do
      {:ok, normalized} ->
        normalized

      {:error, reason} ->
        raise ArgumentError,
              "invalid MCP tool metadata for #{inspect(tool.name)}: #{inspect(reason)}"
    end
  end

  @spec cost_weight!(t()) :: pos_integer()
  def cost_weight!(%__MODULE__{cost_weight: weight})
      when is_integer(weight) and weight > 0,
      do: weight

  def cost_weight!(%__MODULE__{cost_weight: weight}) do
    raise ArgumentError,
          "MCP tool cost_weight must be a positive integer, got: #{inspect(weight)}"
  end

  defp classify(%__MODULE__{safety_class: safety} = tool) when safety in @safety_classes do
    if contradictory_explicit?(tool, safety),
      do: {:error, :contradictory_safety_metadata},
      else: {:ok, safety}
  end

  defp classify(%__MODULE__{annotations: annotations, requires_access: access}) do
    read_only = annotation(annotations, :readOnlyHint) == true
    destructive = annotation(annotations, :destructiveHint) == true
    open_world = annotation(annotations, :openWorldHint) == true
    mutation = access == :read_write
    flags = Enum.count([read_only, destructive, open_world], & &1)

    cond do
      read_only and (mutation or destructive or open_world) ->
        {:error, :contradictory_safety_metadata}

      not mutation and (destructive or open_world) ->
        {:error, :contradictory_safety_metadata}

      destructive ->
        {:ok, :destructive}

      open_world ->
        {:ok, :publish}

      read_only or not mutation ->
        {:ok, :read}

      flags == 0 ->
        {:ok, :write}

      true ->
        {:error, :contradictory_safety_metadata}
    end
  end

  defp validate_metadata(%__MODULE__{requires_access: :read}, safety)
       when safety in [:write, :publish, :destructive],
       do: {:error, :contradictory_safety_metadata}

  defp validate_metadata(%__MODULE__{requires_access: access}, :read)
       when access not in [:read, :read_write],
       do: {:error, {:invalid_access, access}}

  defp validate_metadata(%__MODULE__{requires_access: :read_write}, :read),
    do: {:error, :contradictory_safety_metadata}

  defp validate_metadata(%__MODULE__{requires_access: access}, _safety)
       when access not in [:read, :read_write],
       do: {:error, {:invalid_access, access}}

  defp validate_metadata(
         %__MODULE__{name: name, title: title, description: description},
         _safety
       )
       when is_binary(name) and is_binary(title) and is_binary(description),
       do: :ok

  defp validate_metadata(_tool, _safety), do: {:error, :invalid_description_metadata}

  defp contradictory_explicit?(
         %__MODULE__{annotations: annotations, requires_access: access},
         safety
       ) do
    read_only = annotation(annotations, :readOnlyHint) == true
    destructive = annotation(annotations, :destructiveHint) == true
    open_world = annotation(annotations, :openWorldHint) == true
    mutation = access == :read_write

    (read_only and (safety != :read or mutation)) or
      (destructive and safety != :destructive) or
      (open_world and safety not in [:publish, :destructive]) or
      (not mutation and safety != :read)
  end

  defp annotation(annotations, key) when is_map(annotations) do
    Map.get(annotations, key) || Map.get(annotations, Atom.to_string(key))
  end

  defp annotation(_annotations, _key), do: nil

  defp normalize_prerequisites(prerequisites, schema) when is_list(prerequisites) do
    required =
      case schema do
        %{"required" => fields} when is_list(fields) -> fields
        %{required: fields} when is_list(fields) -> Enum.map(fields, &to_string/1)
        _ -> []
      end

    (prerequisites ++ required)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_prerequisites(_prerequisites, schema),
    do: normalize_prerequisites([], schema)

  defp normalize_examples(examples) when is_list(examples), do: examples
  defp normalize_examples(_examples), do: []
end
