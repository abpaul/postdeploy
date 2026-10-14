defmodule Alplus.Scope do
  @moduledoc """
  Request-scoped tenant context (ARCHITECTURE.md §4).

  `%Scope{user_id, org_id, role, project_id, environment, grant_id, correlation_id}` is
  the actor for every Ash call in the app. Pass it as `actor:` on every action; pass
  `scope.org_id` as `tenant:` where the resource is org-scoped.

  `grant_id` is the OAuth grant that authenticated a remote MCP caller. Browser
  sessions leave it nil.

  `role` is a convenience cache filled in when the scope is built (see
  `Alplus.Orgs.build_scope/2`). It is never the source of truth for
  authorization — every Ash policy re-checks role against the live
  `memberships` row at the query, because an earlier scoped lookup excuses
  nothing (ARCHITECTURE.md §4, "Tenancy" hard rule).
  """

  defstruct [
    :user_id,
    :org_id,
    :role,
    :project_id,
    :environment,
    :grant_id,
    :correlation_id
  ]

  @type role :: String.t()

  @type t :: %__MODULE__{
          user_id: String.t() | nil,
          org_id: String.t() | nil,
          role: role() | nil,
          project_id: String.t() | nil,
          environment: String.t() | nil,
          grant_id: String.t() | nil,
          correlation_id: String.t() | nil
        }

  @doc "Builds a scope for a user with no org selected yet."
  @spec for_user(String.t()) :: t()
  def for_user(user_id) when is_binary(user_id) do
    %__MODULE__{user_id: user_id, correlation_id: Alplus.Id.generate(:request)}
  end

  @doc "Returns a copy of `scope` with the org and cached role attached."
  @spec put_org(t(), String.t(), role()) :: t()
  def put_org(%__MODULE__{} = scope, org_id, role) when is_binary(org_id) and is_binary(role) do
    %{scope | org_id: org_id, role: role}
  end

  @doc "Returns a copy of `scope` with the project attached."
  @spec put_project(t(), String.t()) :: t()
  def put_project(%__MODULE__{} = scope, project_id) when is_binary(project_id) do
    %{scope | project_id: project_id}
  end
end
