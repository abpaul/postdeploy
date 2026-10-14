defmodule Alplus.Mcp.Dispatch do
  @moduledoc "Runs every MCP call through the shared policy boundary."

  alias Alplus.Mcp.{
    Audit,
    Catalog,
    Error,
    Idempotency,
    Principal,
    RateLimit,
    Schema,
    Scope,
    Tenancy,
    Tool
  }

  @metadata_limit 8192

  @spec call(String.t(), map(), Principal.t()) :: {:ok, map()} | {:error, Error.t()}
  def call(tool_name, args, %Principal{} = principal)
      when is_binary(tool_name) and is_map(args) do
    with {:ok, adapter, %Tool{} = tool} <- adapter_for(tool_name),
         :ok <- RateLimit.check(principal, tool),
         :ok <- access_allowed?(tool, principal),
         :ok <- tenancy_allowed?(tool, args, principal) do
      result = invoke(adapter, tool, tool_name, args, principal)
      record_audit(principal, tool_name, args, result)
      result
    else
      {:error, %Error{} = error} ->
        record_audit(principal, tool_name, args, {:error, error})
        {:error, error}

      {:error, reason} ->
        error = Error.from(reason)
        record_audit(principal, tool_name, args, {:error, error})
        {:error, error}
    end
  end

  @spec tools() :: [Tool.t()]
  def tools, do: Catalog.all()

  @spec tools(Principal.t()) :: [Tool.t()]
  def tools(%Principal{} = principal), do: Catalog.tools(principal)

  defp record_audit(principal, tool_name, args, result) do
    Audit.record(%{
      actor: principal,
      org_id: principal.org_id,
      project_id: audit_project_id(principal, args),
      entry_id: subject_handle(args),
      tool: tool_name,
      correlation_id: principal.correlation_id,
      outcome: outcome(result),
      request_metadata: metadata(args)
    })
  end

  defp audit_project_id(principal, args) do
    handle =
      Map.get(args, "project_handle") || Map.get(args, :project_handle) ||
        Map.get(args, "project_id") || Map.get(args, :project_id)

    with handle when is_binary(handle) <- handle,
         {:ok, scope} <- Tenancy.resolve(principal, handle) do
      scope.project_id
    else
      _ -> nil
    end
  end

  defp subject_handle(args) do
    Enum.find_value(
      ~w(entry_id entry_handle issue_handle monitor_handle incident_handle source_handle release_handle),
      &Map.get(args, &1)
    )
  end

  defp invoke(adapter, %Tool{requires_access: :read_write} = tool, tool_name, args, principal) do
    case Map.get(args, "idempotency_key") || Map.get(args, :idempotency_key) do
      nil ->
        {:error, Error.from(:missing_idempotency_key)}

      _key ->
        Idempotency.run(
          principal,
          tool_name,
          args,
          fn -> adapter.call(tool_name, args, principal) end,
          fn result -> Schema.validate(result, tool.output_schema) end
        )
    end
  end

  defp invoke(adapter, %Tool{}, tool_name, args, principal),
    do: adapter.call(tool_name, args, principal)

  defp tenancy_allowed?(%Tool{tenancy: :organization}, _args, _principal), do: :ok

  defp tenancy_allowed?(%Tool{}, args, principal) do
    handle =
      Map.get(args, "project_handle") || Map.get(args, :project_handle) ||
        Map.get(args, "project_id") || Map.get(args, :project_id)

    case handle do
      handle when is_binary(handle) ->
        case Tenancy.resolve(principal, handle) do
          {:ok, _scope} -> :ok
          {:error, :not_found} -> {:error, Error.from(:not_found)}
        end

      _ ->
        {:error,
         Error.new(
           :invalid_argument,
           "A project_handle is required for this tool",
           %{field: "project_handle"}
         )}
    end
  end

  defp access_allowed?(%Tool{} = tool, %Principal{} = principal) do
    if Scope.allowed?(principal, tool) do
      :ok
    else
      denied_access(tool, principal)
    end
  end

  defp denied_access(%Tool{} = tool, %Principal{source: :oauth}) do
    {:error, Error.from({:insufficient_scope, required_scopes(tool)})}
  end

  defp denied_access(_tool, _principal),
    do: {:error, Error.new(:forbidden_role, "Read-only credentials cannot mutate data", %{})}

  defp required_scopes(tool) do
    case Scope.required(tool) do
      scope when is_binary(scope) -> [scope]
      _ -> []
    end
  end

  defp adapter_for(tool_name), do: Catalog.get(tool_name)

  defp outcome({:ok, _result}), do: "allowed"

  defp outcome({:error, %Error{code: code}})
       when code in [:forbidden_role, :insufficient_scope, :rate_limited, :not_found],
       do: "denied"

  defp outcome({:error, %Error{}}), do: "allowed"
  defp outcome(_result), do: "denied"

  defp metadata(args) do
    sources = Map.get(args, "sources") || Map.get(args, :sources)

    metadata =
      args
      |> Map.drop([
        "token",
        "access_token",
        "credential",
        "cursor",
        "raw_cursor",
        "markdown",
        "content",
        "sources",
        :token,
        :access_token,
        :credential,
        :cursor,
        :raw_cursor,
        :markdown,
        :content,
        :sources
      ])
      |> redact_sources(sources)

    if byte_size(Jason.encode!(metadata)) <= @metadata_limit do
      metadata
    else
      %{"truncated" => true}
    end
  end

  defp redact_sources(metadata, sources) when is_list(sources) do
    kinds =
      sources
      |> Enum.map(&source_kind/1)
      |> Enum.filter(&is_binary/1)

    Map.put(metadata, "sources", %{"count" => length(sources), "kinds" => kinds})
  end

  defp redact_sources(metadata, _sources), do: metadata

  defp source_kind(source) when is_map(source) do
    Map.get(source, "kind") || Map.get(source, :kind)
  end

  defp source_kind(_source), do: nil
end
