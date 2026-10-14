defmodule AlplusWeb.OAuthConsent do
  @moduledoc """
  Consent screen logic shared by the authorization-code flow
  (`/oauth/authorize`) and the device flow (`/activate`).

  Both flows show the same permissions, resolve the same organization and
  project choices, and apply the same subset rules. Only the redirect back to
  the client differs, so only that part stays in the controllers.
  """

  alias Alplus.Mcp.OAuth
  alias Alplus.Mcp.Scope, as: McpScope
  alias Alplus.Scope

  @doc """
  Loads the organizations and projects the person may grant, or the single
  organization an organization-scoped request names.
  """
  @spec context(String.t(), map()) ::
          {:ok, %{mode: :organization | :project, organization: map() | nil, choices: list()}}
          | {:error, term()}
  def context(resource, user) do
    case OAuth.resource_mode(resource) do
      :organization ->
        with {:ok, scope} <- OAuth.resolve_selected_organization(user.id, resource),
             {:ok, organization} <-
               Ash.get(Alplus.Orgs.Organization, scope.org_id, authorize?: false) do
          {:ok, %{mode: :organization, organization: organization, choices: []}}
        end

      :project ->
        with {:ok, choices} <- OAuth.authorization_choices(user) do
          {:ok, %{mode: :project, organization: nil, choices: choices}}
        end

      :invalid ->
        {:error, :invalid_request}
    end
  end

  @doc "Resolves the organization or project the person selected."
  @spec selected_scope(String.t() | nil, String.t(), map()) :: Scope.t() | nil
  def selected_scope(user_id, resource, params) do
    case OAuth.resource_mode(resource) do
      :organization -> selected_organization_scope(user_id, resource)
      :project -> selected_project_scope(user_id, params)
      :invalid -> nil
    end
  end

  @doc """
  Maps the submitted form to the permissions to grant. Returns `:error` when
  the person selected nothing, or selected something that was not requested.
  """
  @spec granted_scopes(String.t(), String.t(), map()) :: {:ok, [String.t()]} | :error
  def granted_scopes(resource, requested_scope, params) do
    if OAuth.resource_mode(resource) == :organization do
      organization_scopes(requested_scope, params["access"])
    else
      project_scopes(requested_scope, params)
    end
  end

  @doc "The message shown when the person selects no permission."
  @spec empty_selection_message(String.t()) :: String.t()
  def empty_selection_message(resource) do
    if OAuth.resource_mode(resource) == :organization,
      do: "Choose an access level.",
      else: "Choose at least one of the requested permissions."
  end

  @doc "The message shown when the selected organization and project disagree."
  @spec invalid_selection_message(String.t()) :: String.t()
  def invalid_selection_message(resource) do
    if OAuth.resource_mode(resource) == :organization,
      do: "This organization connection is not available.",
      else: "Choose a project that belongs to the selected organization."
  end

  @doc "Permission checkboxes grouped by capability, for the consent table."
  @spec scope_groups(String.t(), MapSet.t() | :all) :: [map()]
  def scope_groups(requested_scope, selected_ids) do
    requested_scope
    |> scope_options(selected_ids)
    |> Enum.chunk_by(& &1.category)
    |> Enum.map(fn category_options ->
      category = hd(category_options).category

      %{
        label: String.capitalize(category),
        options: [
          Enum.find(category_options, &(&1.access == "read")),
          Enum.find(category_options, &(&1.access == "write"))
        ]
      }
    end)
  end

  @doc "True when the request asks for any write permission."
  @spec requested_write?(String.t()) :: boolean()
  def requested_write?(scope),
    do: scope |> String.split(" ", trim: true) |> Enum.any?(&String.ends_with?(&1, ":write"))

  @doc "The checkbox ids the person submitted."
  @spec selected_scope_ids(map()) :: MapSet.t()
  def selected_scope_ids(%{"scope_indices" => indices})
      when is_binary(indices) or is_list(indices) do
    indices = List.wrap(indices)
    if Enum.all?(indices, &is_binary/1), do: MapSet.new(indices), else: MapSet.new()
  end

  def selected_scope_ids(_params), do: MapSet.new()

  defp scope_options(scope, selected_ids) do
    scope
    |> String.split(" ", trim: true)
    |> Enum.zip(McpScope.labels(scope))
    |> Enum.with_index()
    |> Enum.map(fn {{scope, label}, index} ->
      id = Integer.to_string(index)
      [category, access] = String.split(scope, ":", parts: 2)

      %{
        id: id,
        scope: scope,
        label: label,
        category: category,
        access: access,
        checked: selected_ids == :all or id in selected_ids
      }
    end)
  end

  defp project_scopes(requested_scope, params) do
    selected_ids = selected_scope_ids(params)
    options = scope_options(requested_scope, :all)
    valid_ids = MapSet.new(options, & &1.id)

    if MapSet.size(selected_ids) > 0 and MapSet.subset?(selected_ids, valid_ids) do
      {:ok, for(option <- options, MapSet.member?(selected_ids, option.id), do: option.scope)}
    else
      :error
    end
  end

  defp organization_scopes(scope, "read") do
    scopes =
      scope
      |> String.split(" ", trim: true)
      |> Enum.filter(&String.ends_with?(&1, ":read"))

    if scopes == [], do: :error, else: {:ok, scopes}
  end

  defp organization_scopes(scope, "read_write") do
    scopes = String.split(scope, " ", trim: true)

    if scopes != [] and Enum.any?(scopes, &String.ends_with?(&1, ":write")),
      do: {:ok, scopes},
      else: :error
  end

  defp organization_scopes(_scope, _access), do: :error

  defp selected_organization_scope(user_id, resource) when is_binary(user_id) do
    case OAuth.resolve_selected_organization(user_id, resource) do
      {:ok, %Scope{} = scope} -> scope
      _ -> nil
    end
  end

  defp selected_organization_scope(_user_id, _resource), do: nil

  defp selected_project_scope(user_id, %{"org_id" => org_id, "project_id" => project_id})
       when is_binary(user_id) and is_binary(org_id) and is_binary(project_id) and
              org_id != "" and project_id != "" do
    case OAuth.resolve_selected_project(user_id, org_id, project_id) do
      {:ok, %Scope{} = scope} -> scope
      _ -> nil
    end
  end

  defp selected_project_scope(_user_id, _params), do: nil
end
