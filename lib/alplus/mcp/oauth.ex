defmodule Alplus.Mcp.OAuth do
  @moduledoc """
  MCP OAuth 2.1 authorization-code + S256 PKCE service.

  Public delegates for browser consent, code issue, token exchange, refresh
  rotation, revocation, and access-token authentication. Discovery URL
  helpers remain here.
  """
  require Ash.Query

  alias Alplus.Mcp.OAuth.Flow
  alias Alplus.Mcp.Principal

  @spec issuer() :: String.t()
  def issuer do
    AlplusWeb.Endpoint.url()
    |> String.trim_trailing("/")
  end

  @spec resource_uri() :: String.t()
  def resource_uri, do: issuer() <> "/mcp"

  @spec resource_uri(String.t()) :: String.t()
  def resource_uri(org_public_token) when is_binary(org_public_token),
    do: issuer() <> "/mcp/org/" <> org_public_token

  @spec protected_resource_metadata_uri() :: String.t()
  def protected_resource_metadata_uri,
    do: issuer() <> "/.well-known/oauth-protected-resource/mcp"

  @spec protected_resource_metadata_uri(String.t()) :: String.t()
  def protected_resource_metadata_uri(org_public_token) when is_binary(org_public_token),
    do: issuer() <> "/.well-known/oauth-protected-resource/mcp/org/" <> org_public_token

  @spec authorization_endpoint() :: String.t()
  def authorization_endpoint, do: issuer() <> "/oauth/authorize"

  @spec token_endpoint() :: String.t()
  def token_endpoint, do: issuer() <> "/oauth/token"

  @spec revocation_endpoint() :: String.t()
  def revocation_endpoint, do: issuer() <> "/oauth/revoke"

  @spec registration_endpoint() :: String.t()
  def registration_endpoint, do: issuer() <> "/oauth/register"

  @spec device_authorization_endpoint() :: String.t()
  def device_authorization_endpoint, do: issuer() <> "/oauth/device_authorization"

  @doc "Where a person types the user code shown by the client."
  @spec verification_uri() :: String.t()
  def verification_uri, do: issuer() <> "/activate"

  @spec device_grant_type() :: String.t()
  def device_grant_type, do: Flow.device_grant_type()

  @spec device_poll_interval_seconds() :: pos_integer()
  def device_poll_interval_seconds, do: Flow.device_poll_interval_seconds()

  @spec start_device_authorization(map()) ::
          {:ok, %{String.t() => term()}}
          | {:error, :invalid_request | :invalid_scope | :invalid_client}
  def start_device_authorization(params), do: Flow.start_device_authorization(params)

  @spec device_code_for_user_code(String.t()) ::
          {:ok, Alplus.Mcp.OAuthDeviceCode.t()} | {:error, :not_found | :expired | :settled}
  def device_code_for_user_code(user_code), do: Flow.device_code_for_user_code(user_code)

  @spec approve_device_code(Alplus.Mcp.OAuthDeviceCode.t(), Alplus.Scope.t(), [String.t()]) ::
          :ok | {:error, :forbidden | :invalid_request}
  def approve_device_code(record, scope, granted_scopes),
    do: Flow.approve_device_code(record, scope, granted_scopes)

  @spec deny_device_code(Alplus.Mcp.OAuthDeviceCode.t()) :: :ok | {:error, :invalid_request}
  def deny_device_code(record), do: Flow.deny_device_code(record)

  @spec redeem_device_code(map()) ::
          {:ok, %{String.t() => term()}} | {:error, Flow.device_error()}
  def redeem_device_code(params), do: Flow.redeem_device_code(params)

  @spec supported_scopes() :: [String.t()]
  def supported_scopes, do: Alplus.Mcp.Scope.all()

  @spec register_client(map()) :: {:ok, map()} | {:error, term()}
  def register_client(params), do: Flow.register_client(params)
  @spec prune_expired() :: :ok
  def prune_expired, do: Flow.prune_expired()

  @spec error_redirect(Flow.Request.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_request}
  def error_redirect(request, error), do: Flow.error_redirect(request, error)

  @spec registered_error_redirect(map(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_request}
  def registered_error_redirect(params, error), do: Flow.registered_error_redirect(params, error)

  @spec validate_authorization_syntax(map()) ::
          :ok | {:error, :invalid_request | :invalid_scope}
  def validate_authorization_syntax(params), do: Flow.validate_authorization_syntax(params)

  @spec validate_authorization_request(map()) ::
          {:ok, Flow.Request.t()} | {:error, :invalid_request | :invalid_scope}
  def validate_authorization_request(params), do: Flow.validate_authorization_request(params)

  @spec serialize_authorization_request(Flow.Request.t()) :: %{String.t() => String.t()}
  def serialize_authorization_request(request), do: Flow.serialize_authorization_request(request)

  @spec restore_authorization_request(map()) ::
          {:ok, Flow.Request.t()} | {:error, :invalid_request | :invalid_scope}
  def restore_authorization_request(params), do: Flow.restore_authorization_request(params)

  @spec authorize(Flow.Request.t(), Alplus.Scope.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, :forbidden | :invalid_request}
  def authorize(request, scope, granted_scopes),
    do: Flow.authorize(request, scope, granted_scopes)

  @spec deny(Flow.Request.t()) :: {:ok, String.t()} | {:error, :invalid_request}
  def deny(request), do: Flow.deny(request)

  @spec exchange_code(map()) :: {:ok, %{String.t() => term()}} | {:error, :invalid_grant}
  def exchange_code(params), do: Flow.exchange_code(params)

  @spec refresh_token(map()) :: {:ok, %{String.t() => term()}} | {:error, :invalid_grant}
  def refresh_token(params), do: Flow.refresh_token(params)

  @spec revoke_token(term(), term()) :: :ok
  def revoke_token(token, token_type_hint), do: Flow.revoke_token(token, token_type_hint)

  @spec authenticate_access_token(String.t()) ::
          {:ok, Principal.t()} | {:error, :unauthenticated | :revoked}
  def authenticate_access_token(token), do: Flow.authenticate_access_token(token, resource_uri())

  @spec authenticate_access_token(String.t(), String.t()) ::
          {:ok, Principal.t()} | {:error, :unauthenticated | :revoked}
  def authenticate_access_token(token, resource),
    do: Flow.authenticate_access_token(token, resource)

  @doc """
  Loads the organizations and projects one owner or admin may grant to an MCP
  client. Ordinary members cannot create grants.
  """
  @spec authorization_choices(map() | String.t()) ::
          {:ok, [%{organization: map(), projects: [map()]}]} | {:error, term()}
  def authorization_choices(%{id: user_id}), do: authorization_choices(user_id)

  def authorization_choices(user_id) when is_binary(user_id) do
    scope = Alplus.Scope.for_user(user_id)

    with {:ok, organizations} <- Alplus.Orgs.list_organizations(actor: scope) do
      privileged_organizations =
        Enum.filter(organizations, fn organization ->
          case Alplus.Orgs.build_scope(scope, organization.id) do
            {:ok, %Alplus.Scope{role: role}} when role in ["owner", "admin"] -> true
            _ -> false
          end
        end)

      with {:ok, projects} <-
             Alplus.Projects.list_projects_for_orgs(
               Enum.map(privileged_organizations, & &1.id),
               actor: scope
             ) do
        projects_by_org = Enum.group_by(projects, & &1.org_id)

        choices =
          privileged_organizations
          |> Enum.map(&%{organization: &1, projects: Map.get(projects_by_org, &1.id, [])})
          |> Enum.reject(&(&1.projects == []))

        if choices == [], do: {:error, :no_choices}, else: {:ok, choices}
      end
    end
  end

  def authorization_choices(_user), do: {:error, :no_choices}

  @doc "Resolves a submitted organization and project pair for the user."
  @spec resolve_selected_project(String.t(), String.t(), String.t()) ::
          {:ok, Alplus.Scope.t()} | {:error, :not_found | :not_authorized}
  def resolve_selected_project(user_id, org_id, project_id)
      when is_binary(user_id) and is_binary(org_id) and is_binary(project_id) and
             user_id != "" and org_id != "" and project_id != "" do
    with {:ok, %Alplus.Scope{role: role} = org_scope} <-
           Alplus.Orgs.build_scope(Alplus.Scope.for_user(user_id), org_id),
         true <- role in ["owner", "admin"],
         {:ok, project} <- Alplus.Projects.get_project(project_id, actor: org_scope),
         true <- project.org_id == org_scope.org_id do
      {:ok, Alplus.Scope.put_project(org_scope, project.id)}
    else
      false -> {:error, :not_found}
      {:error, _} -> {:error, :not_authorized}
    end
  end

  def resolve_selected_project(_user_id, _org_id, _project_id), do: {:error, :not_found}

  @doc "Resolves an organization resource URI to its live organization."
  @spec organization_for_resource(String.t()) ::
          {:ok, Alplus.Orgs.Organization.t()} | {:error, :not_found}
  def organization_for_resource(resource) when is_binary(resource) do
    prefix = issuer() <> "/mcp/org/"

    with true <- String.starts_with?(resource, prefix),
         public_token <- String.replace_prefix(resource, prefix, ""),
         true <- Regex.match?(~r/\A[0-9A-Za-z]{16}\z/, public_token),
         {:ok, %Alplus.Orgs.Organization{} = organization} <-
           Alplus.Orgs.Organization
           |> Ash.Query.filter(public_token == ^public_token)
           |> Ash.read_one(authorize?: false) do
      {:ok, organization}
    else
      _ -> {:error, :not_found}
    end
  end

  def organization_for_resource(_resource), do: {:error, :not_found}

  @doc "Builds an owner/admin organization scope from an organization MCP resource."
  @spec resolve_selected_organization(String.t(), String.t()) ::
          {:ok, Alplus.Scope.t()} | {:error, :not_found | :not_authorized}
  def resolve_selected_organization(user_id, resource)
      when is_binary(user_id) and is_binary(resource) do
    with {:ok, organization} <- organization_for_resource(resource),
         {:ok, %Alplus.Scope{role: role} = scope} <-
           Alplus.Orgs.build_scope(Alplus.Scope.for_user(user_id), organization.id),
         true <- role in ["owner", "admin"] do
      {:ok, scope}
    else
      false -> {:error, :not_authorized}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  def resolve_selected_organization(_user_id, _resource), do: {:error, :not_found}

  @spec resource_mode(String.t()) :: :project | :organization | :invalid
  def resource_mode(resource) when is_binary(resource) do
    cond do
      resource == resource_uri() ->
        :project

      match?({:ok, _organization}, organization_for_resource(resource)) ->
        :organization

      true ->
        :invalid
    end
  end

  def resource_mode(_resource), do: :invalid
end
