defmodule Alplus.Mcp.Schema do
  @moduledoc "Fixed MCP gateway schemas and small JSON-schema validator."

  alias Alplus.Mcp.Tool

  @safety_values Enum.map(Tool.safety_classes(), &Atom.to_string/1)

  @doc "Returns the eight stable gateway tool definitions in wire order."
  @spec gateway_tools() :: [Tool.t()]
  def gateway_tools do
    [
      gateway_tool(
        "context.get",
        "Get organization context",
        "Return the grant organization, access mode, scopes, and project discovery. Use project_ref for one exact project.",
        object_schema(
          %{
            "project_ref" => string_schema(1, 128),
            "query" => string_schema(1, 200),
            "cursor" => string_schema(1, 4096),
            "limit" => integer_schema(1, 50)
          },
          []
        ),
        object_schema(
          %{
            "organization" =>
              object_schema(%{"id" => string_schema(), "name" => string_schema()}, ["id", "name"]),
            "access_mode" => enum_schema(["read", "read_write"]),
            "project" => nullable_object_schema(),
            "projects" => array_schema(project_summary_schema()),
            "next_cursor" => nullable_string_schema(),
            "scopes" => array_schema(string_schema()),
            "product_areas" => array_schema(string_schema())
          },
          [
            "organization",
            "access_mode",
            "project",
            "projects",
            "next_cursor",
            "scopes",
            "product_areas"
          ]
        ),
        %{readOnlyHint: true},
        :read,
        :read
      ),
      gateway_tool(
        "actions.search",
        "Search actions",
        "Find public registered actions by intent without returning tenant data. A result may name a missing required scope.",
        object_schema(
          %{
            "intent" => string_schema(1, 500),
            "area" =>
              enum_schema([
                "monitor",
                "observe",
                "measure",
                "seo",
                "changelog",
                "status",
                "platform"
              ]),
            "limit" => integer_schema(1, 50)
          },
          ["intent"]
        ),
        object_schema(
          %{
            "matches" => array_schema(action_summary_schema()),
            "next_cursor" => nullable_string_schema()
          },
          ["matches", "next_cursor"]
        ),
        %{readOnlyHint: true},
        :read,
        :read
      ),
      gateway_tool(
        "actions.get",
        "Inspect an action",
        "Return the exact registered action schemas, safety class, scope, rate, idempotency rule, prerequisites, examples, and availability.",
        object_schema(%{"action" => string_schema(1, 128)}, ["action"]),
        object_schema(%{"action" => action_metadata_schema()}, ["action"]),
        %{readOnlyHint: true},
        :read,
        :read
      ),
      gateway_tool(
        "actions.read",
        "Read through an action",
        "Resolve one registered read action, validate its arguments, authorize it against the live grant, and dispatch it once.",
        action_call_schema(false),
        action_result_schema(),
        %{readOnlyHint: true},
        :read,
        :read
      ),
      gateway_tool(
        "actions.write",
        "Write through an action",
        "Resolve one registered reversible closed-world write, validate and authorize it, then dispatch it once with an idempotency key.",
        action_call_schema(true),
        action_result_schema(),
        %{openWorldHint: false, idempotentHint: true},
        :write,
        :read_write
      ),
      gateway_tool(
        "actions.publish",
        "Publish through an action",
        "Resolve one registered customer-visible or open-world publish action, then validate, authorize, dispatch once, and audit it.",
        action_call_schema(true),
        action_result_schema(),
        %{openWorldHint: true, idempotentHint: true},
        :publish,
        :read_write
      ),
      gateway_tool(
        "actions.destroy",
        "Request destructive action",
        "Create a durable dashboard confirmation for a registered destructive action. Never execute it before approval.",
        action_call_schema(true),
        object_schema(
          %{"confirmation_id" => string_schema(), "status" => enum_schema(["pending"])},
          ["confirmation_id", "status"]
        ),
        %{destructiveHint: true, idempotentHint: true},
        :destructive,
        :read_write
      ),
      gateway_tool(
        "confirmations.get",
        "Get confirmation status",
        "Return the status and result of a destructive confirmation: pending, approved, rejected, expired, or failed.",
        object_schema(
          %{
            "confirmation_id" => string_schema(1, 128),
            "project_ref" => string_schema(1, 128)
          },
          ["confirmation_id"]
        ),
        object_schema(
          %{
            "confirmation_id" => string_schema(),
            "status" => enum_schema(["pending", "approved", "rejected", "expired", "failed"]),
            "result" => nullable_object_schema()
          },
          ["confirmation_id", "status", "result"]
        ),
        %{readOnlyHint: true},
        :read,
        :read
      )
    ]
  end

  @doc "Returns a strict validation result for a value against a JSON schema."
  @spec validate(term(), map()) :: :ok | {:error, String.t()}
  def validate(value, schema) when is_map(value) and is_map(schema) do
    data = stringify(value)
    json_schema = stringify(schema)

    try do
      case ExJsonSchema.Validator.validate(json_schema, data) do
        :ok ->
          :ok

        {:error, [{_message, path} | _]} ->
          {:error, field_from_path(path)}

        {:error, _errors} ->
          {:error, "arguments"}
      end
    rescue
      _exception ->
        {:error, "arguments"}
    end
  end

  def validate(_value, _schema), do: {:error, "arguments"}

  @doc "Converts schema and result maps to JSON-safe string keys."
  @spec stringify(term()) :: term()
  def stringify(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def stringify(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def stringify(%Date{} = value), do: Date.to_iso8601(value)
  def stringify(%Time{} = value), do: Time.to_iso8601(value)
  def stringify(%Decimal{} = value), do: Decimal.to_string(value)

  def stringify(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)
  end

  def stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)

  # `stringify/1` is the JSON-serialization boundary: an Ash atom-constrained
  # attribute (e.g. `:active`) must render as its string name ("active") to
  # match a `type: "string"` schema and to be correct on the wire. `nil`,
  # `true`, and `false` stay as-is so JSON null/booleans and schema keywords
  # (e.g. `additionalProperties: false`) are unaffected.
  def stringify(value) when value in [nil, true, false], do: value
  def stringify(value) when is_atom(value), do: Atom.to_string(value)

  def stringify(value), do: value

  def object_schema(properties, required),
    do: %{type: "object", properties: properties, required: required, additionalProperties: false}

  def free_object_schema, do: %{type: "object", additionalProperties: true}

  defp gateway_tool(name, title, description, input, output, annotations, safety, access) do
    %Tool{
      name: name,
      title: title,
      description: description,
      input_schema: input,
      output_schema: output,
      annotations: annotations,
      safety_class: safety,
      requires_access: access,
      cost_weight: 1,
      tenancy: :organization
    }
    |> Tool.normalize!()
  end

  defp action_call_schema(idempotent?) do
    properties = %{
      "action" => string_schema(1, 128),
      "arguments" => free_object_schema(),
      "project_ref" => string_schema(1, 128)
    }

    if idempotent? do
      object_schema(
        Map.put(properties, "idempotency_key", string_schema(1, 256)),
        ["action", "arguments", "idempotency_key"]
      )
    else
      object_schema(properties, ["action", "arguments"])
    end
  end

  defp project_summary_schema do
    object_schema(
      %{
        "handle" => string_schema(),
        "project_ref" => string_schema(),
        "name" => string_schema()
      },
      ["handle", "project_ref", "name"]
    )
  end

  defp action_summary_schema do
    object_schema(
      %{
        "action" => string_schema(),
        "title" => string_schema(),
        "description" => string_schema(),
        "required_scope" => string_schema(),
        "safety" => enum_schema(@safety_values),
        "missing_scope" => nullable_string_schema(),
        "input_schema" => free_object_schema()
      },
      ["action", "title", "description", "required_scope", "safety", "missing_scope"]
    )
  end

  defp action_metadata_schema do
    object_schema(
      %{
        "name" => string_schema(),
        "title" => string_schema(),
        "description" => string_schema(),
        "input_schema" => free_object_schema(),
        "output_schema" => free_object_schema(),
        "safety" => enum_schema(@safety_values),
        "required_scope" => string_schema(),
        "rate_weight" => integer_schema(1, 100),
        "idempotent" => boolean_schema(),
        "prerequisites" => array_schema(string_schema()),
        "examples" => array_schema(free_object_schema()),
        "availability" => string_schema()
      },
      [
        "name",
        "title",
        "description",
        "input_schema",
        "output_schema",
        "safety",
        "required_scope",
        "rate_weight",
        "idempotent",
        "prerequisites",
        "examples",
        "availability"
      ]
    )
  end

  defp action_result_schema,
    do:
      object_schema(%{"action" => string_schema(), "result" => free_object_schema()}, [
        "action",
        "result"
      ])

  defp string_schema, do: %{type: "string"}

  defp string_schema(minimum, maximum),
    do: %{type: "string", minLength: minimum, maxLength: maximum}

  defp integer_schema(minimum, maximum),
    do: %{type: "integer", minimum: minimum, maximum: maximum}

  defp enum_schema(values), do: %{type: "string", enum: values}
  defp boolean_schema, do: %{type: "boolean"}
  defp nullable_string_schema, do: %{type: ["string", "null"]}
  defp nullable_object_schema, do: %{type: ["object", "null"]}
  defp array_schema(items), do: %{type: "array", items: items}

  defp field_from_path("#/" <> rest) do
    rest
    |> String.split("/")
    |> Enum.reject(&(&1 == ""))
    |> List.last() || "arguments"
  end

  defp field_from_path(_path), do: "arguments"
end
