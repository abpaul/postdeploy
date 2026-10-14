defmodule Alplus.PublicPages.Public do
  @moduledoc "Reads published public-page identities with a least-privilege actor."

  require Ash.Query

  alias Alplus.Billing.Access
  alias Alplus.PublicPages.{PublicActor, PublicPage, PublicPageAlias}

  @max_slug_length 100

  @spec resolve(String.t(), keyword()) ::
          {:ok,
           %{
             identity: PublicPage.t(),
             actor: PublicActor.t(),
             alias?: boolean(),
             requested_slug: String.t()
           }}
          | {:error, :not_found}
  def resolve(slug, opts \\ [])

  def resolve(slug, opts) when is_binary(slug) do
    actor = PublicActor.for_slug(slug)
    alias_kind = Keyword.get(opts, :alias_kind)

    case find_by_slug(slug, actor) do
      {:ok, identity} -> resolve_identity(identity, false, slug)
      {:error, :not_found} -> resolve_alias(slug, actor, alias_kind)
    end
  end

  def resolve(_slug, _opts), do: {:error, :not_found}

  @doc "Resolves a Changelog legacy alias without accepting a Status alias."
  def resolve_changelog(slug), do: resolve(slug, alias_kind: "changelog")

  @doc "Resolves the published identity for one project without exposing tenant data."
  @spec public_identity_for_project(String.t()) ::
          {:ok, PublicPage.t()} | {:error, :not_found}
  def public_identity_for_project(project_id) when is_binary(project_id) do
    actor = PublicActor.for_project(project_id)

    with {:ok, identity} <- find_by_project(project_id, actor),
         {:ok, _access} <- Access.check(identity.org_id),
         resolved_actor <- PublicActor.for_identity(identity),
         {:ok, identity} <- read_public(identity.id, resolved_actor) do
      {:ok, identity}
    else
      _ -> {:error, :not_found}
    end
  end

  def public_identity_for_project(_project_id), do: {:error, :not_found}

  @doc "Returns a published legacy alias without exposing its tenant fields."
  @spec public_alias_for_slug(String.t()) ::
          {:ok, PublicPageAlias.t()} | {:error, :not_found}
  def public_alias_for_slug(slug, opts \\ [])

  def public_alias_for_slug(slug, opts) when is_binary(slug) do
    find_alias(slug, PublicActor.for_slug(slug), Keyword.get(opts, :kind))
  end

  def public_alias_for_slug(_slug, _opts), do: {:error, :not_found}

  @doc "Builds the deterministic replacement used when a legacy slug collides."
  @spec slug_with_project_token(String.t(), String.t()) :: String.t()
  def slug_with_project_token(slug, public_token)
      when is_binary(slug) and is_binary(public_token) do
    suffix = "-" <> String.downcase(public_token)
    base_length = max(@max_slug_length - byte_size(suffix), 1)

    slug
    |> String.downcase()
    |> String.slice(0, base_length)
    |> String.trim_trailing("-")
    |> Kernel.<>(suffix)
  end

  def slug_with_project_token(slug, _public_token) when is_binary(slug), do: slug

  defp find_by_slug(slug, actor) do
    PublicPage
    |> Ash.Query.for_read(:public_by_slug, %{slug: slug}, actor: actor)
    |> Ash.read_one()
    |> one_result()
  end

  defp find_alias(slug, actor, nil) do
    PublicPageAlias
    |> Ash.Query.for_read(:public_by_slug, %{slug: slug}, actor: actor)
    |> Ash.read_one()
    |> one_result()
  end

  defp find_alias(slug, _actor, kind) do
    PublicPageAlias
    |> Ash.Query.for_read(:public_by_kind, %{slug: slug, kind: kind},
      actor: PublicActor.for_slug(slug, kind)
    )
    |> Ash.read_one()
    |> one_result()
  end

  defp resolve_alias(slug, actor, kind) do
    with {:ok, alias_record} <- find_alias(slug, actor, kind),
         project_actor <- PublicActor.for_project(alias_record.project_id),
         {:ok, identity} <- find_by_project(alias_record.project_id, project_actor) do
      resolve_identity(identity, true, slug)
    end
  end

  defp resolve_identity(identity, alias?, requested_slug) do
    with {:ok, _access} <- Access.check(identity.org_id),
         resolved_actor <- PublicActor.for_identity(identity),
         {:ok, identity} <- read_public(identity.id, resolved_actor) do
      {:ok,
       %{
         identity: identity,
         actor: resolved_actor,
         alias?: alias?,
         requested_slug: requested_slug
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  defp find_by_project(project_id, actor) do
    PublicPage
    |> Ash.Query.for_read(:public_by_project, %{project_id: project_id}, actor: actor)
    |> Ash.read_one()
    |> one_result()
  end

  defp read_public(id, actor) do
    PublicPage
    |> Ash.Query.for_read(:read_public, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one()
    |> one_result()
  end

  defp one_result({:ok, nil}), do: {:error, :not_found}
  defp one_result({:ok, value}), do: {:ok, value}
  defp one_result(_), do: {:error, :not_found}
end
