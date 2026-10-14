defmodule Alplus.Mcp.Tenancy do
  @moduledoc "Resolves immutable project references against the live organization membership."
  require Ash.Query

  alias Alplus.Mcp.Principal
  alias Alplus.Projects.Project
  alias Alplus.Scope

  @spec resolve(Principal.t(), String.t()) :: {:ok, Scope.t()} | {:error, :not_found}
  def resolve(%Principal{} = principal, reference) when is_binary(reference) do
    with {:ok, membership} <- membership(principal),
         {:ok, project} <- project(principal, reference),
         :ok <- selected_project_allowed?(principal, project.id) do
      {:ok,
       %Scope{
         user_id: principal.user_id,
         org_id: principal.org_id,
         role: membership.role,
         project_id: project.id,
         grant_id: principal.grant_id,
         correlation_id: principal.correlation_id
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  def resolve(_principal, _reference), do: {:error, :not_found}

  defp selected_project_allowed?(%Principal{scope_mode: :organization}, _project_id), do: :ok
  defp selected_project_allowed?(%Principal{project_id: project_id}, project_id), do: :ok
  defp selected_project_allowed?(_principal, _project_id), do: {:error, :not_found}

  defp membership(principal) do
    Alplus.Orgs.Membership
    |> Ash.Query.filter(org_id == ^principal.org_id and user_id == ^principal.user_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Alplus.Orgs.Membership{} = membership} -> {:ok, membership}
      _ -> {:error, :not_found}
    end
  end

  defp project(principal, reference) do
    query =
      Project
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(org_id == ^principal.org_id)

    query =
      if String.starts_with?(reference, "project_"),
        do: Ash.Query.filter(query, id == ^reference),
        else: Ash.Query.filter(query, public_token == ^reference)

    query
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Project{} = project} -> {:ok, project}
      _ -> {:error, :not_found}
    end
  end
end
