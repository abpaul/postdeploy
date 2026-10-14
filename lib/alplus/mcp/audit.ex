defmodule Alplus.Mcp.Audit do
  @moduledoc "Records MCP actions through the shared audit log without content or secrets."

  @sensitive_keys ~w(
    token bearer credential secret access_token authorization api_key source_token cookie private_key
    markdown content body comments email name raw_cursor cursor password
    exception contexts tags breadcrumbs user message fingerprint payload item
    code code_verifier code_challenge refresh_token
  )a

  @spec record(map()) :: :ok
  def record(attrs) when is_map(attrs) do
    actor = Map.get(attrs, :actor) || Map.get(attrs, "actor")

    Alplus.Audit.write(%{
      actor: actor,
      org_id: Map.get(attrs, :org_id) || get(actor, :org_id),
      project_id: Map.get(attrs, :project_id),
      grant_id: get(actor, :grant_id),
      actor_kind: "agent",
      transport: transport(actor),
      action: Map.get(attrs, :tool) || Map.get(attrs, :action, "mcp.call"),
      subject_type: subject_type(Map.get(attrs, :tool)),
      subject_id:
        Map.get(attrs, :entry_id) || Map.get(attrs, :revision_id) || Map.get(attrs, :subject_id),
      outcome: Map.get(attrs, :outcome, "allowed"),
      request_id: Map.get(attrs, :correlation_id),
      metadata:
        attrs
        |> Map.get(:request_metadata, Map.get(attrs, "request_metadata", %{}))
        |> drop_protocol_meta()
        |> redact()
    })
  end

  defp transport(%Alplus.Mcp.Principal{source: :session}), do: "webmcp"
  defp transport(%Alplus.Mcp.Principal{}), do: "remote_mcp"
  defp transport(_), do: "session"

  defp get(nil, _key), do: nil
  defp get(value, key), do: Map.get(value, key)
  defp subject_type("changelog." <> _), do: "changelog_entry"
  defp subject_type("projects." <> _), do: "project"
  defp subject_type(_tool), do: "mcp_tool"

  defp drop_protocol_meta(value) when is_map(value) do
    Map.drop(value, ["_meta", :_meta])
  end

  defp drop_protocol_meta(value), do: value

  defp redact(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, _value} -> normalize_key(key) in @sensitive_keys end)
    |> Map.new(fn {key, nested} -> {key, redact(nested)} end)
  end

  defp redact(value) when is_list(value), do: Enum.map(value, &redact/1)
  defp redact(value), do: value

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    Enum.find(@sensitive_keys, :unknown, &(Atom.to_string(&1) == key))
  end

  defp normalize_key(_key), do: :unknown
end
