defmodule Alplus.Mcp.Scope do
  @moduledoc "Shared MCP tool-scope mapping and authorization decisions."

  alias Alplus.Mcp.{Catalog, Principal, Tool}

  # Product analytics shares the `analytics:*` scopes with Measure and SEO.
  # All three answer "how is this product doing", so one consent decision
  # covers them and the authorization screen stays readable.
  @scope_by_prefix %{
    "analytics" => %{read: "analytics:read", read_write: "analytics:write"},
    "changelog" => %{read: "changelog:read", read_write: "changelog:write"},
    "measure" => %{read: "analytics:read", read_write: "analytics:write"},
    "monitor" => %{read: "monitor:read", read_write: "monitor:write"},
    "observe" => %{read: "errors:read", read_write: "errors:write"},
    "projects" => %{read: "projects:read", read_write: "projects:write"},
    "seo" => %{read: "analytics:read", read_write: "analytics:write"},
    "public" => %{read: "status:read", read_write: "status:write"},
    "status" => %{read: "status:read", read_write: "status:write"}
  }

  @all @scope_by_prefix
       |> Map.values()
       |> Enum.flat_map(&Map.values/1)
       |> Enum.uniq()
       |> Enum.sort()

  @spec all() :: [String.t()]
  def all, do: @all

  @scope_labels %{
    "analytics:read" => "Analytics read",
    "analytics:write" => "Analytics write",
    "changelog:read" => "Changelog read",
    "changelog:write" => "Changelog write",
    "errors:read" => "Errors read",
    "errors:write" => "Errors write",
    "monitor:read" => "Monitor read",
    "monitor:write" => "Monitor write",
    "projects:read" => "Projects read",
    "projects:write" => "Projects write",
    "status:read" => "Status read",
    "status:write" => "Status write"
  }

  @spec labels(String.t()) :: [String.t()]
  def labels(scopes) when is_binary(scopes) do
    scopes
    |> String.split(" ", trim: true)
    |> Enum.map(&Map.fetch!(@scope_labels, &1))
  end

  @spec required(Tool.t() | String.t()) :: String.t() | nil
  def required(%Tool{name: name, requires_access: access}) do
    with [prefix | _rest] <- String.split(name, ".", parts: 2),
         {:ok, by_access} <- Map.fetch(@scope_by_prefix, prefix),
         {:ok, scope} <- Map.fetch(by_access, access) do
      scope
    else
      _ -> nil
    end
  end

  def required(tool_name) when is_binary(tool_name) do
    case Catalog.get(tool_name) do
      {:ok, _adapter, tool} -> required(tool)
      {:error, :not_found} -> nil
    end
  end

  @spec allowed?(Principal.t(), Tool.t() | String.t()) :: boolean()
  def allowed?(%Principal{} = principal, %Tool{} = tool), do: allowed_tool?(principal, tool)

  def allowed?(%Principal{} = principal, tool_name) when is_binary(tool_name) do
    case Catalog.get(tool_name) do
      {:ok, _adapter, tool} -> allowed_tool?(principal, tool)
      {:error, :not_found} -> false
    end
  end

  defp allowed_tool?(%Principal{source: :oauth, scopes: scopes}, tool) when is_list(scopes) do
    case required(tool) do
      scope when is_binary(scope) -> scope in scopes
      nil -> false
    end
  end

  defp allowed_tool?(%Principal{source: :oauth}, _tool), do: false
  defp allowed_tool?(%Principal{access: :read_write}, %Tool{}), do: true
  defp allowed_tool?(%Principal{}, %Tool{requires_access: :read}), do: true
  defp allowed_tool?(%Principal{}, %Tool{}), do: false
end
