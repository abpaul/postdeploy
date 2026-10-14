defmodule Alplus.Measure.SiteCreator do
  @moduledoc """
  Creates a Measure site in one step: allow-lists its domain and creates its
  `:measure` Source (issue #36 wizard unification). A site is a domain, so
  the old two-section flow (a "New site" form plus a standalone "Domains"
  panel) collapses into this single call.

  Idempotent on the domain half: re-submitting an already allow-listed
  hostname reuses the existing `Alplus.Projects.ProjectDomain` row instead
  of erroring on `unique_hostname_per_project`. The domain is allow-listed
  first, then the Source is created; a domain surviving a failed Source
  create is harmless (an allow-listed origin with no Source is inert), so
  this stays two plain calls rather than one nested transaction, which
  would otherwise fire `Alplus.Sources.Source`'s `Alplus.Audit.Change`
  `after_transaction` hook while still inside a surrounding transaction.
  """

  require Ash.Query

  alias Alplus.Measure.OriginAllowlist
  alias Alplus.Projects.ProjectDomain
  alias Alplus.Sources.Source

  @type attrs :: %{
          optional(:hostname) => String.t() | nil,
          optional(:name) => String.t() | nil,
          optional(:environment) => String.t() | nil
        }

  @spec create(attrs(), Alplus.Scope.t()) ::
          {:ok, %{source: Source.t(), domain: ProjectDomain.t()}} | {:error, term()}
  def create(attrs, scope) do
    with {:ok, hostname} <- validate_hostname(Map.get(attrs, :hostname)),
         {:ok, domain} <- find_or_create_domain(hostname, scope),
         {:ok, source} <- create_source(hostname, attrs, scope) do
      {:ok, %{source: source, domain: domain}}
    end
  end

  @doc "Configures the origin and allowlist entry for a legacy Measure Source."
  @spec configure(Source.t(), String.t(), Alplus.Scope.t()) ::
          {:ok, %{source: Source.t(), domain: ProjectDomain.t()}} | {:error, term()}
  def configure(%Source{} = source, hostname, scope) do
    with {:ok, hostname} <- validate_hostname(hostname),
         {:ok, domain} <- find_or_create_domain(hostname, scope),
         {:ok, source} <-
           Ash.update(source, %{hostname: hostname},
             action: :configure_hostname,
             actor: scope
           ) do
      {:ok, %{source: source, domain: domain}}
    end
  end

  defp validate_hostname(hostname) do
    case OriginAllowlist.normalize(hostname) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, :invalid_hostname} -> {:error, :invalid_hostname}
    end
  end

  defp find_or_create_domain(hostname, scope) do
    ProjectDomain
    |> Ash.Query.filter(project_id == ^scope.project_id and hostname == ^hostname)
    |> Ash.read_one(actor: scope)
    |> case do
      {:ok, %ProjectDomain{} = domain} ->
        {:ok, domain}

      {:ok, nil} ->
        Alplus.Projects.create_project_domain(
          %{org_id: scope.org_id, project_id: scope.project_id, hostname: hostname},
          actor: scope
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_source(hostname, attrs, scope) do
    Alplus.Sources.create_source(
      %{
        org_id: scope.org_id,
        project_id: scope.project_id,
        type: :measure,
        hostname: hostname,
        name: presence_or(Map.get(attrs, :name), hostname),
        environment: presence_or(Map.get(attrs, :environment), "production")
      },
      actor: scope
    )
  end

  defp presence_or(nil, default), do: default
  defp presence_or("", default), do: default
  defp presence_or(value, _default), do: value
end
