defmodule Alplus.Mcp.Server do
  @moduledoc "Sessionless ExMCP handler for the shared MCP boundary."

  use ExMCP.Server.Handler

  alias Alplus.Mcp.{Error, Gateway, Principal}

  # Declare only what this server implements. ExMCP's `server/discover` handler
  # reads capabilities from this callback, not from `handle_initialize/2`, and
  # falls back to an empty map when a handler does not export it. A 2026-07-28
  # client learns the capability set from discovery rather than from an
  # `initialize` handshake, so an empty map made every tool invisible: the
  # official client reported "server does not advertise tools capability" and
  # returned no tools, while `tools/list` itself answered correctly.
  @capabilities %{"tools" => %{}}

  def __server_capabilities__, do: @capabilities

  @impl true
  def init(opts) do
    {:ok, %{principal: Keyword.get(opts, :principal)}}
  end

  @impl true
  def handle_initialize(params, state) do
    {:ok,
     %{
       protocolVersion: Map.get(params, "protocolVersion", ExMCP.protocol_version()),
       serverInfo: %{name: "Alplus", version: "1.0.0"},
       capabilities: %{tools: %{}}
     }, state}
  end

  @impl true
  def handle_list_tools(_cursor, %{principal: %Principal{} = principal} = state) do
    {:ok, Gateway.wire_tools(principal), nil, state}
  end

  def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}

  @impl true
  def handle_list_resources(_cursor, state), do: {:ok, [], nil, state}

  @impl true
  def handle_list_resource_templates(_cursor, state), do: {:ok, [], nil, state}

  @impl true
  def handle_call_tool(name, args, %{principal: %Principal{} = principal} = state) do
    case Gateway.call(name, args, principal) do
      {:ok, result} -> {:ok, success_result(result), state}
      {:error, %Error{} = error} -> {:ok, error_result(error), state}
    end
  end

  def handle_call_tool(_name, _args, state),
    do: {:ok, error_result(Error.from(:unauthenticated)), state}

  # A tool result is an envelope, never the domain map itself. `content` is
  # required and must be an array, so returning the domain fields directly made
  # the official client reject every successful call with "expected array path
  # content received undefined". Serialize the payload as JSON text for a client
  # that reads only `content`, and repeat it in `structuredContent` for a client
  # that validates against the tool's declared output schema.
  defp success_result(result) when is_map(result) do
    %{
      content: [%{type: "text", text: Jason.encode!(result)}],
      isError: false,
      structuredContent: result
    }
  end

  defp error_result(%Error{} = error) do
    error_payload = %{
      error: %{code: Atom.to_string(error.code), message: error.message, details: error.details}
    }

    %{
      content: [%{type: "text", text: Jason.encode!(error_payload)}],
      isError: true,
      structuredContent: error_payload
    }
  end
end
