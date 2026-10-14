defmodule Alplus.PublicPages.API do
  @moduledoc "Domain interface for public-page identity changes."

  require Ash.Query

  alias Alplus.PublicPages.Public
  alias Alplus.PublicPages.PublicPage
  alias Alplus.PublicPages.PublicPageAlias
  alias Alplus.Projects.Project

  def create(scope, attrs) when is_map(attrs),
    do: Ash.create(PublicPage, attrs, action: :create, actor: scope)

  @doc false
  def bootstrap_system_transactional(project_id) when is_binary(project_id) do
    case system_project(project_id) do
      {:ok, project} ->
        case unscoped_identity_for_project(project_id) do
          {:ok, identity} ->
            {:ok, identity, false}

          :not_found ->
            attrs = %{
              org_id: project.org_id,
              project_id: project.id,
              public_slug: project.slug || "project-" <> String.slice(project.id, -12, 12),
              title: project.name,
              public_token: project.public_token
            }

            case create_bootstrap_with_collision_fallback(attrs, action: :create_internal) do
              {:ok, identity} -> {:ok, identity, true}
              error -> error
            end
        end

      error ->
        error
    end
  end

  @doc "Returns the identity for a scoped project, or `:not_found`."
  def get_for_project(scope, project_id) when is_binary(project_id) do
    if Map.get(scope, :project_id) == project_id do
      get_for_scope(scope)
    else
      {:error, :not_found}
    end
  end

  def get_for_project(_scope, _project_id), do: {:error, :not_found}

  @doc "Lists legacy public URLs retained for a scoped project identity."
  def aliases_for_project(scope, project_id) when is_binary(project_id) do
    if Map.get(scope, :project_id) == project_id do
      PublicPageAlias
      |> Ash.Query.for_read(:for_project, %{project_id: project_id}, actor: scope)
      |> Ash.Query.sort(public_slug: :asc)
      |> Ash.read()
    else
      {:error, :not_found}
    end
  end

  def aliases_for_project(_scope, _project_id), do: {:error, :not_found}

  @doc "Returns the identity for the scope's organization and project."
  def get_for_scope(scope) do
    with {:ok, org_id} <- scope_value(scope, :org_id),
         {:ok, project_id} <- scope_value(scope, :project_id) do
      PublicPage
      |> Ash.Query.for_read(:for_project, %{org_id: org_id, project_id: project_id}, actor: scope)
      |> Ash.read_one()
      |> case do
        {:ok, nil} -> {:error, :not_found}
        {:ok, identity} -> {:ok, identity}
        {:error, _} = error -> error
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Creates the identity once when a project first configures a public surface."
  def ensure_identity(scope, attrs) when is_map(attrs) do
    case ensure_identity_transactional(scope, attrs) do
      {:ok, identity, true} ->
        Alplus.Audit.write(%{
          actor: scope,
          org_id: identity.org_id,
          project_id: identity.project_id,
          action: "public_page.create",
          subject_type: "public_page",
          subject_id: identity.id,
          outcome: "allowed",
          metadata: %{}
        })

        {:ok, identity}

      {:ok, identity, false} ->
        {:ok, identity}

      error ->
        error
    end
  end

  @doc false
  def ensure_identity_transactional(scope, attrs) when is_map(attrs) do
    project_id = Map.get(attrs, :project_id) || Map.get(attrs, "project_id")
    org_id = Map.get(attrs, :org_id) || Map.get(attrs, "org_id")

    with :ok <- validate_scope(scope, org_id, project_id) do
      attrs = Map.put_new(attrs, :public_token, project_token(project_id))

      case get_for_scope(scope) do
        {:ok, identity} ->
          {:ok, identity, false}

        {:error, :not_found} ->
          case create_with_collision_fallback(scope, attrs, action: :create_internal) do
            {:ok, identity} -> {:ok, identity, true}
            error -> error
          end

        {:error, _} = error ->
          error
      end
    end
  end

  def update(scope, identity, attrs, opts \\ []) when is_map(attrs) do
    old_slug = identity.public_slug
    # The shared identity has required title and slug attributes. Callers may
    # update one setting at a time, so pass the current values for omitted
    # required fields. This keeps validation strict without making each
    # boundary duplicate merge logic.
    attrs = Map.merge(%{public_slug: identity.public_slug, title: identity.title}, attrs)

    case Ash.transact([PublicPage, PublicPageAlias], fn ->
           with :ok <- validate_slug_available(identity, attrs.public_slug),
                :ok <- validate_slug_available(identity, old_slug),
                {:ok, updated} <- update_identity(scope, identity, attrs, :update_internal),
                :ok <-
                  preserve_slug_alias(
                    scope,
                    updated,
                    old_slug,
                    Keyword.get(opts, :alias_kind, "status")
                  ) do
             {:ok, updated}
           end
         end) do
      {:ok, {:ok, updated}} ->
        Alplus.Audit.write(%{
          actor: scope,
          org_id: updated.org_id,
          project_id: updated.project_id,
          action: "public_page.update",
          subject_type: "public_page",
          subject_id: updated.id,
          outcome: "allowed",
          metadata: %{}
        })

        {:ok, updated}

      {:ok, result} ->
        result

      {:error, %Ash.Error.Unknown.UnknownError{}} ->
        {:error, :legacy_slug_collision}

      {:error, error} ->
        {:error, error}
    end
  end

  defp validate_slug_available(identity, slug) do
    if Enum.any?(slug_records(slug), &(&1.project_id != identity.project_id)) do
      {:error, :legacy_slug_collision}
    else
      :ok
    end
  end

  def publish(scope, identity), do: update_identity(scope, identity, %{}, :publish)
  def unpublish(scope, identity), do: update_identity(scope, identity, %{}, :unpublish)

  @doc "Reserves a legacy alias for a scoped public identity."
  def reserve_alias(scope, identity, slug, kind, source_id \\ nil)
      when is_binary(slug) and is_binary(kind) do
    reserve_alias_record(identity, slug, kind, source_id, actor: scope, authorize?: true)
  end

  @doc "Reserves an internal legacy alias after a domain-owned migration or bootstrap."
  def reserve_alias_system(identity, slug, kind, source_id \\ nil)
      when is_binary(slug) and is_binary(kind) do
    reserve_alias_record(identity, slug, kind, source_id, actor: nil, authorize?: false)
  end

  defp create_with_collision_fallback(scope, attrs, opts) do
    action = Keyword.get(opts, :action, :create)
    create_attrs = Map.drop(attrs, [:public_token, "public_token"])
    create_attrs = displace_taken_slug(create_attrs, attrs)

    case Ash.create(PublicPage, create_attrs, action: action, actor: scope) do
      {:ok, identity} ->
        {:ok, identity}

      {:error, error} = result ->
        if collision_error?(error) do
          project_token = Map.get(attrs, :public_token) || Map.get(attrs, "public_token")
          public_slug = Map.get(attrs, :public_slug) || Map.get(attrs, "public_slug")

          if is_binary(public_slug) and is_binary(project_token) do
            Ash.create(
              PublicPage,
              Map.put(
                create_attrs,
                :public_slug,
                Public.slug_with_project_token(public_slug, project_token)
              ),
              action: action,
              actor: scope
            )
          else
            result
          end
        else
          result
        end
    end
  end

  defp create_bootstrap_with_collision_fallback(attrs, opts) do
    action = Keyword.get(opts, :action, :create)
    create_attrs = Map.drop(attrs, [:public_token, "public_token"])
    create_attrs = displace_taken_slug(create_attrs, attrs)

    case Ash.create(PublicPage, create_attrs, action: action, authorize?: false) do
      {:ok, _identity} = result ->
        result

      {:error, error} = result ->
        cond do
          project_identity_conflict?(error) ->
            project_id = Map.get(create_attrs, :project_id) || Map.get(create_attrs, "project_id")

            case unscoped_identity_for_project(project_id) do
              {:ok, identity} -> {:ok, identity}
              :not_found -> result
            end

          collision_error?(error) ->
            project_token = Map.get(attrs, :public_token) || Map.get(attrs, "public_token")
            public_slug = Map.get(attrs, :public_slug) || Map.get(attrs, "public_slug")

            if is_binary(public_slug) and is_binary(project_token) do
              Ash.create(
                PublicPage,
                Map.put(
                  create_attrs,
                  :public_slug,
                  Public.slug_with_project_token(public_slug, project_token)
                ),
                action: action,
                authorize?: false
              )
            else
              result
            end

          true ->
            result
        end
    end
  end

  defp collision_error?(%_{} = error) do
    message = Exception.message(error)
    details = inspect(error)

    String.contains?(message, "already been taken") or
      String.contains?(message, "public_pages_slug_unique_index") or
      String.contains?(details, "unique_public_slug") or
      String.contains?(details, "public_pages_slug_unique_index")
  end

  defp project_identity_conflict?(%_{} = error) do
    String.contains?(Exception.message(error), "project_id") or
      String.contains?(inspect(error), "project_id")
  end

  defp displace_taken_slug(create_attrs, attrs) do
    public_slug = Map.get(attrs, :public_slug) || Map.get(attrs, "public_slug")
    project_token = Map.get(attrs, :public_token) || Map.get(attrs, "public_token")

    project_id = Map.get(attrs, :project_id) || Map.get(attrs, "project_id")

    if is_binary(public_slug) and is_binary(project_token) and
         public_slug_taken?(public_slug, project_id) do
      Map.put(
        create_attrs,
        :public_slug,
        Public.slug_with_project_token(public_slug, project_token)
      )
    else
      create_attrs
    end
  end

  defp public_slug_taken?(slug, project_id) do
    alias_taken? = Enum.any?(slug_records(slug), &(&1.project_id != project_id))

    canonical_taken? =
      PublicPage
      |> Ash.Query.filter(public_slug == ^slug)
      |> Ash.read!(authorize?: false)
      |> Enum.any?(&(&1.project_id != project_id))

    alias_taken? or canonical_taken?
  end

  defp slug_records(slug) do
    aliases =
      PublicPageAlias
      |> Ash.Query.for_read(:by_slug_internal, %{slug: slug})
      |> Ash.read!(action: :by_slug_internal, authorize?: false)

    List.wrap(aliases)
  end

  defp unscoped_identity_for_project(project_id) when is_binary(project_id) do
    PublicPage
    |> Ash.Query.for_read(:for_project, %{project_id: project_id})
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> :not_found
      {:ok, identity} -> {:ok, identity}
      _ -> :not_found
    end
  end

  defp unscoped_identity_for_project(_project_id), do: :not_found

  # The token is used only to derive a deterministic replacement slug during
  # the expand phase. It never enters public output.
  defp project_token(project_id) when is_binary(project_id) do
    case Ash.get(Project, project_id, authorize?: false) do
      {:ok, project} -> project.public_token
      _ -> nil
    end
  end

  defp project_token(_project_id), do: nil

  defp validate_scope(scope, org_id, project_id) do
    if scope_value(scope, :org_id) == {:ok, org_id} and
         scope_value(scope, :project_id) == {:ok, project_id} do
      :ok
    else
      {:error, :tenant_scope_mismatch}
    end
  end

  defp scope_value(scope, key) do
    case Map.get(scope, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp system_project(project_id) do
    case Ash.get(Project, project_id, authorize?: false) do
      {:ok, project} -> {:ok, project}
      _ -> {:error, :project_not_found}
    end
  end

  defp update_identity(scope, identity, attrs, action, opts \\ []) do
    Ash.update(identity, attrs, [action: action, actor: scope] ++ opts)
  end

  defp preserve_slug_alias(_scope, _identity, nil, _kind), do: :ok

  defp preserve_slug_alias(_scope, identity, old_slug, _kind)
       when identity.public_slug == old_slug,
       do: :ok

  defp preserve_slug_alias(scope, identity, old_slug, kind) do
    reserve_alias(scope, identity, old_slug, kind)
  end

  defp reserve_alias_record(identity, slug, kind, source_id, opts) do
    if identity.public_slug == slug do
      :ok
    else
      attrs = %{
        id: alias_id(identity.project_id, slug, kind),
        org_id: identity.org_id,
        project_id: identity.project_id,
        public_page_id: identity.id,
        public_slug: slug,
        kind: kind,
        source_id: source_id
      }

      actor = Keyword.fetch!(opts, :actor)
      authorize? = Keyword.fetch!(opts, :authorize?)

      case slug_records(slug) do
        [] ->
          create_opts = [action: :create, authorize?: authorize?]

          create_opts =
            if authorize?, do: Keyword.put(create_opts, :actor, actor), else: create_opts

          case Ash.create(PublicPageAlias, attrs, create_opts) do
            {:ok, _alias} -> :ok
            {:error, error} -> {:error, error}
          end

        [record | _] ->
          if record.project_id == identity.project_id and
               Map.get(record, :public_page_id, record.id) == identity.id and
               record.kind == kind,
             do: :ok,
             else: {:error, :legacy_slug_collision}
      end
    end
  end

  defp alias_id(project_id, slug, "status") do
    "palias_" <> Base.encode16(:crypto.hash(:sha256, project_id <> ":" <> slug), case: :lower)
  end

  defp alias_id(project_id, slug, kind) do
    "palias_" <>
      Base.encode16(:crypto.hash(:sha256, project_id <> ":" <> kind <> ":" <> slug),
        case: :lower
      )
  end
end
