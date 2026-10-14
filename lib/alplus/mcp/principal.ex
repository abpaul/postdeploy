defmodule Alplus.Mcp.Principal do
  @moduledoc """
  A verified caller and its current organization grant.

  OAuth callers stay bound to the consented organization, resource, grant, and
  scopes. Legacy grants carry a pinned project. Organization grants receive a
  request-local project only after the gateway resolves `project_ref`.
  """

  defstruct [
    :grant_id,
    :org_id,
    :project_id,
    :user_id,
    :role,
    :correlation_id,
    :scopes,
    :resource,
    access: :read,
    scope_mode: :project,
    source: :session
  ]

  @type access :: :read | :read_write
  @type scope_mode :: :project | :organization
  @type source :: :oauth | :session

  @type t :: %__MODULE__{
          grant_id: String.t() | nil,
          org_id: String.t(),
          project_id: String.t() | nil,
          user_id: String.t(),
          role: String.t() | nil,
          access: access(),
          correlation_id: String.t(),
          scopes: [String.t()] | nil,
          resource: String.t() | nil,
          scope_mode: scope_mode(),
          source: source()
        }

  @doc "Builds a grant-free principal from a freshly resolved dashboard scope."
  @spec from_session(Alplus.Scope.t()) :: t()
  def from_session(%Alplus.Scope{
        user_id: user_id,
        org_id: org_id,
        project_id: project_id,
        role: role
      })
      when is_binary(user_id) and is_binary(org_id) and is_binary(project_id) and is_binary(role) do
    %__MODULE__{
      grant_id: nil,
      org_id: org_id,
      project_id: project_id,
      user_id: user_id,
      role: role,
      access: role_access(role),
      correlation_id: Alplus.Id.generate(:request),
      scopes: nil,
      resource: nil,
      scope_mode: :project,
      source: :session
    }
  end

  @doc "Builds a principal from a validated OAuth grant."
  @spec from_oauth(Alplus.Mcp.OAuthGrant.t(), [String.t()]) :: t()
  def from_oauth(
        %Alplus.Mcp.OAuthGrant{
          id: grant_id,
          org_id: org_id,
          project_id: project_id,
          user_id: user_id,
          resource: resource,
          scope_mode: scope_mode
        },
        scopes
      )
      when is_binary(grant_id) and is_binary(org_id) and
             (is_nil(project_id) or is_binary(project_id)) and is_binary(user_id) and
             is_binary(resource) and is_list(scopes) do
    %__MODULE__{
      grant_id: grant_id,
      org_id: org_id,
      project_id: project_id,
      user_id: user_id,
      role: nil,
      access: :read,
      correlation_id: Alplus.Id.generate(:request),
      scopes: scopes,
      resource: resource,
      scope_mode: normalize_scope_mode(scope_mode),
      source: :oauth
    }
  end

  @doc "Binds a resolved project and live role for one request."
  @spec put_project(t(), Alplus.Scope.t()) :: t()
  def put_project(
        %__MODULE__{org_id: org_id, user_id: user_id} = principal,
        %Alplus.Scope{org_id: org_id, user_id: user_id, project_id: project_id, role: role}
      )
      when is_binary(project_id) and is_binary(role) do
    %{principal | project_id: project_id, role: role, access: role_access(role)}
  end

  defp normalize_scope_mode("organization"), do: :organization
  defp normalize_scope_mode(:organization), do: :organization
  defp normalize_scope_mode(_scope_mode), do: :project

  defp role_access(role) when role in ["owner", "admin"], do: :read_write
  defp role_access(_role), do: :read
end
