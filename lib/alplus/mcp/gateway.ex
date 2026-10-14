defmodule Alplus.Mcp.Gateway do
  @moduledoc "The eight-tool MCP boundary over the canonical internal registry."

  alias Alplus.Mcp.{
    Audit,
    Catalog,
    Confirmations,
    Discovery,
    Error,
    Principal,
    RateLimit,
    Schema,
    Scope,
    Tenancy,
    Tool
  }

  @tool_names ~w(
    context.get actions.search actions.get actions.read actions.write actions.publish
    actions.destroy confirmations.get
  )

  @spec wire_tools(Principal.t()) :: [map()]
  def wire_tools(%Principal{} = _principal) do
    Enum.map(Schema.gateway_tools(), &wire_tool/1)
  end

  @spec call(String.t(), map(), Principal.t()) :: {:ok, map()} | {:error, Error.t()}
  def call(name, args, %Principal{} = principal) when is_binary(name) and is_map(args) do
    with {:ok, tool} <- gateway_tool(name),
         clean_args <- strip_meta(args),
         :ok <- validate_gateway_requirements(name, clean_args),
         :ok <- validate_envelope(clean_args, tool),
         accounting_principal <- gateway_accounting_principal(name, clean_args, principal),
         rate_result <- gateway_rate_limit(name, tool, accounting_principal),
         _audit <- audit_gateway_rate_denial(name, clean_args, accounting_principal, rate_result),
         :ok <- rate_result,
         result <- invoke(name, clean_args, principal),
         _audit <- audit_gateway_result(name, clean_args, accounting_principal, result),
         {:ok, result} <- result,
         :ok <- validate_output(result, tool) do
      {:ok, Schema.stringify(result)}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def call(_name, _args, _principal), do: {:error, Error.from(:invalid_argument)}

  @doc "Returns the gateway names in their stable wire order."
  def names, do: @tool_names

  defp gateway_accounting_principal("context.get", args, %Principal{} = principal) do
    case value(args, "project_ref") do
      project_ref when is_binary(project_ref) ->
        case Tenancy.resolve(principal, project_ref) do
          {:ok, scope} -> Principal.put_project(principal, scope)
          _ -> principal
        end

      _ ->
        principal
    end
  end

  defp gateway_accounting_principal(_name, _args, principal), do: principal

  defp gateway_rate_limit("context.get", tool, principal),
    do: RateLimit.check(principal, tool)

  defp gateway_rate_limit(_name, _tool, _principal), do: :ok

  defp audit_gateway_rate_denial(
         "context.get",
         args,
         principal,
         {:error, %Error{} = error}
       ) do
    audit_gateway_call(principal, args, {:error, error})
  end

  defp audit_gateway_rate_denial(_name, _args, _principal, _result), do: :ok

  defp audit_gateway_result("context.get", args, principal, result),
    do: audit_gateway_call(principal, args, result)

  defp audit_gateway_result(_name, _args, _principal, _result), do: :ok

  defp audit_gateway_call(principal, args, result) do
    Audit.record(%{
      actor: principal,
      org_id: principal.org_id,
      project_id: principal.project_id,
      tool: "context.get",
      correlation_id: principal.correlation_id,
      outcome: if(match?({:ok, _}, result), do: "allowed", else: "denied"),
      request_metadata: %{
        project_ref: is_binary(value(args, "project_ref")),
        query: is_binary(value(args, "query")),
        limit: value(args, "limit")
      }
    })
  end

  defp invoke("context.get", args, principal), do: Discovery.context(principal, args)
  defp invoke("actions.search", args, principal), do: Discovery.search(principal, args)

  defp invoke("actions.get", args, principal), do: Discovery.get(principal, value(args, "action"))

  defp invoke("actions.read", args, principal), do: execute(:read, args, principal)
  defp invoke("actions.write", args, principal), do: execute(:write, args, principal)
  defp invoke("actions.publish", args, principal), do: execute(:publish, args, principal)
  defp invoke("actions.destroy", args, principal), do: request_confirmation(args, principal)

  defp invoke("confirmations.get", args, principal),
    do: get_confirmation(principal, value(args, "confirmation_id"), value(args, "project_ref"))

  defp execute(expected_class, args, principal) do
    action = value(args, "action")
    arguments = value(args, "arguments")

    with {:ok, _adapter, %Tool{} = tool} <- Catalog.get(action),
         :ok <- class_matches(tool, expected_class),
         {:ok, internal_args, execution_principal} <-
           internal_arguments(tool, arguments, args, principal),
         :ok <- validate_action_arguments(tool, internal_args),
         {:ok, result} <-
           Alplus.Mcp.Dispatch.call(action, internal_args, execution_principal),
         :ok <- validate_action_result(tool, result) do
      {:ok, %{"action" => action, "result" => result}}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, :not_found} -> {:error, Error.from(:not_found)}
    end
  end

  defp request_confirmation(args, principal) do
    action = value(args, "action")
    arguments = value(args, "arguments")
    idempotency_key = value(args, "idempotency_key")

    with {:ok, _adapter, %Tool{} = tool} <- Catalog.get(action),
         :ok <- class_matches(tool, :destructive),
         :ok <- authorize_action(principal, tool),
         {:ok, internal_args, execution_principal} <-
           internal_arguments(tool, arguments, args, principal),
         :ok <- validate_action_arguments(tool, internal_args),
         {:ok, confirmation} <-
           Confirmations.request(
             execution_principal,
             action,
             internal_args,
             idempotency_key
           ) do
      {:ok, confirmation_request_payload(confirmation)}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, :not_found} -> {:error, Error.from(:not_found)}
      {:error, reason} -> {:error, Error.from(reason)}
    end
  end

  defp get_confirmation(principal, id, project_ref) do
    with {:ok, execution_principal} <- confirmation_principal(principal, project_ref) do
      case Confirmations.get(execution_principal, id) do
        {:ok, confirmation} -> {:ok, confirmation_payload(confirmation)}
        {:error, reason} -> {:error, Error.from(reason)}
      end
    end
  end

  defp confirmation_request_payload(%{id: id, status: status}),
    do: %{"confirmation_id" => id, "status" => to_string(status)}

  defp confirmation_payload(%{id: id, status: status, result: result}),
    do: %{"confirmation_id" => id, "status" => to_string(status), "result" => result}

  defp gateway_tool(name) when name in @tool_names do
    {:ok, Enum.find(Schema.gateway_tools(), &(&1.name == name))}
  end

  defp gateway_tool(_name), do: {:error, Error.from(:not_found)}

  defp wire_tool(%Tool{} = tool) do
    %{
      name: tool.name,
      title: tool.title,
      description: tool.description,
      inputSchema: Schema.stringify(tool.input_schema),
      outputSchema: Schema.stringify(tool.output_schema),
      annotations: Schema.stringify(tool.annotations)
    }
  end

  defp validate_gateway_requirements(name, args)
       when name in ["actions.write", "actions.publish", "actions.destroy"] do
    case value(args, "idempotency_key") do
      key when is_binary(key) and key != "" -> :ok
      _ -> {:error, Error.from(:missing_idempotency_key)}
    end
  end

  defp validate_gateway_requirements(_name, _args), do: :ok

  defp authorize_action(principal, tool) do
    if Scope.allowed?(principal, tool) do
      :ok
    else
      {:error, Error.from({:insufficient_scope, List.wrap(Scope.required(tool))})}
    end
  end

  defp validate_envelope(args, %Tool{input_schema: schema}) do
    case Schema.validate(args, schema) do
      :ok ->
        :ok

      {:error, field} ->
        {:error, Error.new(:invalid_argument, "The gateway envelope is invalid", %{field: field})}
    end
  end

  defp validate_output(result, %Tool{output_schema: schema}) do
    case Schema.validate(result, schema) do
      :ok ->
        :ok

      {:error, field} ->
        {:error,
         Error.new(:invalid_result, "The action returned an invalid result", %{field: field})}
    end
  end

  defp class_matches(%Tool{} = tool, expected) do
    if Tool.safety_class(tool) == expected,
      do: :ok,
      else:
        {:error,
         Error.new(:safety_class_mismatch, "The action is not valid for this gateway", %{
           action: tool.name,
           expected: expected,
           actual: Tool.safety_class(tool)
         })}
  end

  defp internal_arguments(
         %Tool{tenancy: :project},
         arguments,
         args,
         %Principal{} = principal
       ) do
    with {:ok, scope} <- resolve_project(principal, value(args, "project_ref")) do
      execution_principal = Principal.put_project(principal, scope)

      {:ok,
       arguments
       |> drop_project()
       |> Map.put("project_handle", scope.project_id)
       |> maybe_idempotency(args), execution_principal}
    end
  end

  defp internal_arguments(%Tool{tenancy: :organization}, arguments, args, principal),
    do: {:ok, arguments |> drop_project() |> maybe_idempotency(args), principal}

  defp resolve_project(%Principal{scope_mode: :organization}, nil),
    do: {:error, Error.from(:project_required)}

  defp resolve_project(%Principal{scope_mode: :organization} = principal, project_ref)
       when is_binary(project_ref),
       do: Tenancy.resolve(principal, project_ref)

  defp resolve_project(%Principal{project_id: project_id} = principal, nil)
       when is_binary(project_id),
       do: Tenancy.resolve(principal, project_id)

  defp resolve_project(%Principal{} = principal, project_ref) when is_binary(project_ref),
    do: Tenancy.resolve(principal, project_ref)

  defp resolve_project(_principal, _project_ref), do: {:error, Error.from(:not_found)}

  defp confirmation_principal(%Principal{} = principal, project_ref) do
    with {:ok, scope} <- resolve_project(principal, project_ref) do
      {:ok, Principal.put_project(principal, scope)}
    end
  end

  defp drop_project(arguments),
    do:
      Map.drop(arguments, [
        "project_ref",
        :project_ref,
        "project_handle",
        :project_handle,
        "project_id",
        :project_id
      ])

  defp maybe_idempotency(arguments, %{"idempotency_key" => key}),
    do: Map.put(arguments, "idempotency_key", key)

  defp maybe_idempotency(arguments, %{idempotency_key: key}),
    do: Map.put(arguments, "idempotency_key", key)

  defp maybe_idempotency(arguments, _args), do: arguments

  defp validate_action_arguments(%Tool{input_schema: schema}, arguments) do
    case Schema.validate(arguments, schema) do
      :ok ->
        :ok

      {:error, field} ->
        {:error,
         Error.new(:invalid_argument, "The action arguments are invalid", %{field: field})}
    end
  end

  defp validate_action_result(%Tool{output_schema: schema}, result) do
    case Schema.validate(result, schema) do
      :ok ->
        :ok

      {:error, field} ->
        {:error,
         Error.new(:invalid_result, "The action returned an invalid result", %{field: field})}
    end
  end

  defp value(args, key), do: Map.get(args, key) || Map.get(args, atom_key(key))

  defp atom_key(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> key
    end
  end

  defp strip_meta(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, _} -> key in ["_meta", :_meta] end)
    |> Map.new(fn {key, nested} -> {key, strip_meta(nested)} end)
  end

  defp strip_meta(value) when is_list(value), do: Enum.map(value, &strip_meta/1)
  defp strip_meta(value), do: value
end
