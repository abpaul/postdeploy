defmodule Alplus.Changelog do
  @moduledoc "Domain interface for agent-managed changelogs."

  use Ash.Domain, otp_app: :alplus

  require Ash.Query
  require Logger

  alias Alplus.Changelog.{ActivityEvent, Changelog, Entry, Revision, SourceReference}
  alias Alplus.Orgs.Membership
  alias Alplus.Changelog.{FrontMatter, Markdown}
  alias Alplus.Mcp.Idempotency
  alias Alplus.PublicPages.{PublicPage, PublicPageAlias}
  alias Alplus.Projects.Project

  resources do
    resource Changelog
    resource Entry
    resource Revision
    resource SourceReference
    resource ActivityEvent
  end

  @valid_source_kinds ~w(pull_request issue release deployment commit other)

  @spec create_changelog(map(), keyword()) :: {:ok, Changelog.t()} | {:error, term()}
  def create_changelog(attrs, actor: actor) do
    create_changelog_in_transaction(:create, attrs, actor)
  end

  @spec designate_vendor_by_public_token(String.t()) ::
          {:ok, Changelog.t()}
          | {:error, :project_not_found}
          | {:error, {:vendor_already_assigned, Project.t()}}
          | {:error, term()}
  def designate_vendor_by_public_token(public_token) when is_binary(public_token) do
    with {:ok, project} <- read_project_by_public_token(public_token) do
      case read_vendor_changelog() do
        {:ok, vendor} when vendor.project_id == project.id ->
          {:ok, vendor}

        {:ok, vendor} ->
          {:error, {:vendor_already_assigned, vendor_owner(vendor)}}

        {:error, :not_found} ->
          ensure_vendor_changelog(project)
      end
    else
      {:error, :not_found} -> {:error, :project_not_found}
      error -> error
    end
  end

  def designate_vendor_by_public_token(_), do: {:error, :project_not_found}

  defp bootstrap_changelog(attrs, actor: actor) do
    create_changelog_in_transaction(:bootstrap, attrs, actor)
  end

  defp create_changelog_in_transaction(action, attrs, actor) do
    identity_attrs = public_identity_attrs(attrs)

    case Ash.transact([Changelog, PublicPage, PublicPageAlias], fn ->
           with {:ok, identity, created?} <-
                  Alplus.PublicPages.API.ensure_identity_transactional(actor, identity_attrs),
                {:ok, changelog} <-
                  Changelog
                  |> Ash.Changeset.for_create(action, changelog_attrs(attrs), actor: actor)
                  |> Ash.create(),
                :ok <- reserve_changelog_alias(identity, identity_attrs, changelog) do
             {:ok, changelog, created?, identity}
           end
         end) do
      {:ok, {:ok, changelog, true, identity}} ->
        Alplus.Audit.write(%{
          actor: actor,
          org_id: identity.org_id,
          project_id: identity.project_id,
          action: "public_page.create",
          subject_type: "public_page",
          subject_id: identity.id,
          outcome: "allowed",
          metadata: %{}
        })

        {:ok, changelog}

      {:ok, {:ok, changelog, false, _identity}} ->
        {:ok, changelog}

      {:error, error} ->
        {:error, error}
    end
  end

  @spec get_changelog(String.t(), keyword()) :: {:ok, Changelog.t()} | {:error, term()}
  def get_changelog(project_id, actor: actor) do
    case read_changelogs(project_id, actor) do
      {:ok, [changelog]} -> {:ok, changelog}
      {:ok, _} -> {:error, :not_found}
      error -> error
    end
  end

  @spec update_settings(Changelog.t() | String.t(), map(), keyword()) ::
          {:ok, Changelog.t()} | {:error, term()}
  def update_settings(changelog, attrs, actor: actor) do
    with {:ok, changelog} <- resolve_changelog(changelog, actor) do
      with {:ok, identity} <- Alplus.PublicPages.get_for_scope(actor),
           :ok <- validate_setting_keys(attrs),
           {:ok, _updated_identity} <-
             Alplus.PublicPages.update(actor, identity, setting_attrs(attrs),
               alias_kind: "changelog"
             ) do
        {:ok, changelog}
      end
    end
  end

  @spec upsert_draft(map(), keyword()) :: {:ok, Entry.t()} | {:error, term()}
  def upsert_draft(attrs, actor: actor) do
    with {:ok, changelog} <- ensure_changelog(attrs.project_id, actor),
         {:ok, metadata} <- FrontMatter.parse_public(attrs.markdown),
         :ok <- validate_sources(Map.get(attrs, :sources, [])),
         :ok <- record_denied_attempt(nil, actor, "entry.upserted", changelog) do
      transactional(fn ->
        with {:ok, entry} <- find_entry(changelog, attrs, actor),
             {:ok, entry} <-
               upsert_entry(entry, changelog, attrs, metadata, attrs.markdown, actor),
             :ok <- replace_sources(entry, changelog, attrs, actor),
             {:ok, revision} <- current_revision(entry, actor),
             {:ok, sources} <- read_sources(entry, actor),
             {:ok, _event} <-
               record_event("entry.upserted", entry, revision, sources, actor) do
          {:ok, entry}
        end
      end)
    end
  end

  @spec update_draft_markdown(Entry.t() | String.t(), String.t(), keyword()) ::
          {:ok, Entry.t()} | {:error, term()}
  def update_draft_markdown(entry, markdown, actor: actor) when is_binary(markdown) do
    with {:ok, entry} <- resolve_entry(entry, actor),
         :ok <- record_denied_attempt(entry, actor, "entry.updated", nil),
         {:ok, revision} <- current_revision(entry, actor),
         {:ok, metadata} <- FrontMatter.parse_public(markdown) do
      if revision.status == :published do
        {:error, :published_revision_immutable}
      else
        with {:ok, _revision} <- update_revision(revision, markdown, actor) do
          update_entry_metadata(entry, metadata, actor)
        end
      end
    end
  end

  @spec get_entry(String.t() | Entry.t(), keyword()) :: {:ok, Entry.t()} | {:error, term()}
  def get_entry(entry, actor: actor), do: resolve_entry(entry, actor)

  @spec get_entry_by_external_id(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Entry.t()} | {:error, term()}
  def get_entry_by_external_id(project_id, grant_id, external_id, actor: actor) do
    with {:ok, changelog} <- get_changelog(project_id, actor: actor) do
      Entry
      |> Ash.Query.for_read(
        :by_external_id,
        %{changelog_id: changelog.id, grant_id: grant_id, external_id: external_id},
        actor: actor
      )
      |> Ash.read()
      |> one_result()
    end
  end

  @spec list_entries(String.t(), keyword()) :: {:ok, [Entry.t()]} | {:error, term()}
  def list_entries(project_id, opts) do
    actor = Keyword.fetch!(opts, :actor)
    query = Ash.Query.for_read(Entry, :for_project, %{project_id: project_id}, actor: actor)

    query =
      if status = Keyword.get(opts, :status),
        do: Ash.Query.filter(query, status == ^status),
        else: query

    query
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.offset(Keyword.get(opts, :offset, 0))
    |> Ash.Query.limit(Keyword.get(opts, :limit, 50))
    |> Ash.Query.load(:source_count)
    |> Ash.read()
  end

  @spec count_entries(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count_entries(project_id, opts) do
    actor = Keyword.fetch!(opts, :actor)
    query = Ash.Query.for_read(Entry, :for_project, %{project_id: project_id}, actor: actor)

    query =
      if status = Keyword.get(opts, :status),
        do: Ash.Query.filter(query, status == ^status),
        else: query

    Ash.count(query)
  end

  @spec entry_counts(String.t(), keyword()) ::
          {:ok,
           %{draft: non_neg_integer(), published: non_neg_integer(), archived: non_neg_integer()}}
          | {:error, term()}
  def entry_counts(project_id, opts) do
    actor = Keyword.fetch!(opts, :actor)

    Entry
    |> Ash.Query.for_read(:for_project, %{project_id: project_id}, actor: actor)
    |> Ash.aggregate([
      {:draft, :count, query: [filter: [status: :draft]]},
      {:published, :count, query: [filter: [status: :published]]},
      {:archived, :count, query: [filter: [status: :archived]]}
    ])
  end

  @spec list_revisions(String.t() | Entry.t(), keyword()) ::
          {:ok, [Revision.t()]} | {:error, term()}
  def list_revisions(entry, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, entry} <- resolve_entry(entry, actor) do
      Revision
      |> Ash.Query.for_read(:for_entry, %{entry_id: entry.id}, actor: actor)
      |> Ash.Query.sort(revision_number: :desc)
      |> Ash.Query.limit(Keyword.get(opts, :limit, 50))
      |> Ash.read()
    end
  end

  @spec get_revision(String.t() | Revision.t(), keyword()) ::
          {:ok, Revision.t()} | {:error, term()}
  def get_revision(%Revision{} = revision, actor: actor), do: read_revision(revision.id, actor)
  def get_revision(revision_id, actor: actor), do: read_revision(revision_id, actor)

  @spec preview_entry(String.t() | Entry.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def preview_entry(entry, actor: actor) do
    with {:ok, revision} <- current_revision(entry, actor),
         do: {:ok, Markdown.render(revision.markdown)}
  end

  @spec publish_entry(String.t() | Entry.t(), String.t() | integer(), keyword()) ::
          {:ok, Entry.t()} | {:error, term()}
  def publish_entry(entry, expected_revision, actor: actor) do
    with {:ok, entry} <- resolve_entry(entry, actor),
         :ok <- record_denied_attempt(entry, actor, "entry.published", nil),
         {:ok, revision} <- current_revision(entry, actor),
         :ok <- publish_state(entry, revision),
         :ok <- expected_revision?(revision, expected_revision),
         {:ok, metadata} <- FrontMatter.parse_public(revision.markdown),
         :ok <- require_evidence(entry, actor) do
      transactional(fn ->
        with {:ok, published_revision} <- publish_revision(revision, actor),
             {:ok, entry} <- publish_entry_record(entry, metadata, actor),
             {:ok, sources} <- read_sources(entry, actor),
             {:ok, _event} <-
               record_event("entry.published", entry, published_revision, sources, actor) do
          {:ok, entry}
        end
      end)
    end
  end

  @spec archive_entry(String.t() | Entry.t(), keyword()) :: {:ok, Entry.t()} | {:error, term()}
  def archive_entry(entry, actor: actor) do
    with {:ok, entry} <- resolve_entry(entry, actor),
         :ok <- record_denied_attempt(entry, actor, "entry.archived", nil),
         :ok <- transition_state(entry, :archive) do
      transactional(fn ->
        with {:ok, archived} <- update_entry_state(entry, :archive, actor),
             {:ok, revision} <- current_revision(archived, actor),
             {:ok, sources} <- read_sources(archived, actor),
             {:ok, _event} <-
               record_event("entry.archived", archived, revision, sources, actor) do
          {:ok, archived}
        end
      end)
    end
  end

  @spec restore_to_draft(String.t() | Entry.t(), keyword()) ::
          {:ok, Entry.t()} | {:error, term()}
  def restore_to_draft(entry, actor: actor) do
    with {:ok, entry} <- resolve_entry(entry, actor),
         :ok <- record_denied_attempt(entry, actor, "entry.restored", nil),
         :ok <- transition_state(entry, :restore) do
      transactional(fn ->
        with {:ok, restored} <- update_entry_state(entry, :restore, actor),
             {:ok, revision} <- current_revision(restored, actor),
             {:ok, revision} <- maybe_create_restore_revision(restored, revision, actor),
             {:ok, sources} <- read_sources(restored, actor),
             {:ok, _event} <-
               record_event("entry.restored", restored, revision, sources, actor) do
          {:ok, restored}
        end
      end)
    end
  end

  defp publish_state(%Entry{status: :archived}, _revision),
    do: {:error, :invalid_state_transition}

  defp publish_state(_entry, %{status: :published}), do: {:error, :already_published}
  defp publish_state(_entry, _revision), do: :ok

  defp transition_state(%Entry{status: :published}, :archive), do: :ok
  defp transition_state(%Entry{status: :archived}, :restore), do: :ok
  defp transition_state(_entry, _action), do: {:error, :invalid_state_transition}

  defp maybe_create_restore_revision(entry, %{status: :published} = revision, actor) do
    create_revision(entry, revision.markdown, revision.revision_number + 1, actor)
  end

  defp maybe_create_restore_revision(_entry, revision, _actor), do: {:ok, revision}

  @spec delete_permanently(String.t() | Entry.t(), keyword()) :: :ok | {:error, term()}
  def delete_permanently(entry, opts) when is_list(opts) do
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, entry} <- resolve_entry(entry, actor),
         :ok <- record_denied_attempt(entry, actor, "entry.deleted", nil),
         :ok <- authorize_delete(entry, actor),
         {:ok, :ok} <-
           Alplus.Repo.transaction(fn ->
             with {:ok, _event} <- tombstone(entry, actor),
                  :ok <- Idempotency.purge_entry(entry.org_id, entry.id),
                  :ok <- destroy_children(entry, actor),
                  :ok <- run_delete_hook(opts),
                  :ok <- destroy_entry(entry, actor) do
               :ok
             else
               {:error, reason} -> Alplus.Repo.rollback(reason)
               other -> Alplus.Repo.rollback(other)
             end
           end) do
      :ok
    end
  end

  defp run_delete_hook(opts) do
    opts
    |> Keyword.get(:after_children, fn -> :ok end)
    |> then(& &1.())
  end

  defp authorize_delete(entry, actor) do
    if Ash.can?({entry, :destroy}, actor), do: :ok, else: {:error, :forbidden_role}
  end

  defp read_project_by_public_token(public_token) do
    Project
    |> Ash.Query.for_read(:read, %{}, authorize?: false)
    |> Ash.Query.filter(public_token == ^public_token)
    |> Ash.read(authorize?: false)
    |> one_result()
  end

  defp read_project_by_id(project_id) do
    Project
    |> Ash.Query.for_read(:read, %{}, authorize?: false)
    |> Ash.Query.filter(id == ^project_id)
    |> Ash.read(authorize?: false)
    |> one_result()
  end

  defp read_vendor_changelog do
    Changelog
    |> Ash.Query.for_read(:read, %{}, authorize?: false)
    |> Ash.Query.filter(vendor? == true)
    |> Ash.read(authorize?: false)
    |> one_result()
  end

  defp read_changelog_for_project(project_id) do
    Changelog
    |> Ash.Query.for_read(:for_project, %{project_id: project_id}, authorize?: false)
    |> Ash.read(authorize?: false)
    |> one_result()
  end

  defp vendor_owner(vendor) do
    case read_project_by_id(vendor.project_id) do
      {:ok, project} -> project
      _ -> vendor
    end
  end

  defp ensure_vendor_changelog(project) do
    with {:ok, changelog} <- ensure_changelog_for_project(project) do
      mark_vendor(changelog)
    end
  end

  defp ensure_changelog_for_project(project) do
    case read_changelog_for_project(project.id) do
      {:ok, changelog} ->
        {:ok, changelog}

      {:error, :not_found} ->
        attrs = %{
          org_id: project.org_id,
          project_id: project.id,
          public_title: project.name,
          public_slug: bootstrap_slug(project.slug, project.id)
        }

        case Ash.transact([Changelog, PublicPage, PublicPageAlias], fn ->
               with {:ok, identity, created?} <-
                      Alplus.PublicPages.API.bootstrap_system_transactional(project.id),
                    {:ok, changelog} <-
                      Changelog
                      |> Ash.Changeset.for_create(:bootstrap, changelog_attrs(attrs), actor: nil)
                      |> Ash.create(authorize?: false),
                    :ok <-
                      reserve_changelog_alias(identity, public_identity_attrs(attrs), changelog) do
                 {:ok, changelog, created?, identity}
               end
             end) do
          {:ok, {:ok, changelog, true, identity}} ->
            Alplus.Audit.write(%{
              actor: vendor_system_actor(project),
              org_id: identity.org_id,
              project_id: identity.project_id,
              action: "public_page.create",
              subject_type: "public_page",
              subject_id: identity.id,
              outcome: "allowed",
              metadata: %{}
            })

            {:ok, changelog}

          {:ok, {:ok, changelog, false, _identity}} ->
            {:ok, changelog}

          {:error, %Ash.Error.Invalid{} = error} ->
            case read_changelog_for_project(project.id) do
              {:ok, changelog} -> {:ok, changelog}
              _ -> {:error, error}
            end

          {:error, error} ->
            {:error, error}
        end

      error ->
        error
    end
  end

  defp vendor_system_actor(project) do
    query =
      Membership
      |> Ash.Query.for_read(:read, %{}, authorize?: false)
      |> Ash.Query.filter(org_id == ^project.org_id and role == "owner")

    case Ash.read(query, authorize?: false, limit: 1) do
      {:ok, [%{user_id: user_id}]} ->
        %Alplus.Scope{
          user_id: user_id,
          org_id: project.org_id,
          project_id: project.id,
          role: "owner"
        }

      _ ->
        %Alplus.SystemActor{org_id: project.org_id, project_id: project.id}
    end
  end

  defp mark_vendor(changelog) do
    case Ash.update(changelog, %{}, action: :designate_vendor, authorize?: false) do
      {:ok, changelog} ->
        {:ok, changelog}

      {:error, error} ->
        case read_vendor_changelog() do
          {:ok, vendor} when vendor.project_id != changelog.project_id ->
            {:error, {:vendor_already_assigned, vendor_owner(vendor)}}

          _ ->
            {:error, error}
        end
    end
  end

  defp read_changelogs(project_id, actor) do
    Changelog
    |> Ash.Query.for_read(:for_project, %{project_id: project_id}, actor: actor)
    |> Ash.read()
  end

  defp resolve_changelog(%Changelog{id: id}, actor), do: resolve_changelog(id, actor)

  defp resolve_changelog(id, actor) do
    Changelog
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read()
    |> one_result()
  end

  defp ensure_changelog(project_id, actor) do
    case get_changelog(project_id, actor: actor) do
      {:ok, changelog} ->
        {:ok, changelog}

      {:error, :not_found} ->
        with {:ok, project} <- Alplus.Projects.get_project(project_id, actor: actor),
             slug <- bootstrap_slug(project.slug, project.id),
             {:ok, changelog} <-
               bootstrap_changelog(
                 %{
                   org_id: project.org_id,
                   project_id: project.id,
                   public_title: project.name,
                   public_slug: slug
                 },
                 actor: actor
               ) do
          {:ok, changelog}
        else
          {:error, %Ash.Error.Invalid{} = error} ->
            case get_changelog(project_id, actor: actor) do
              {:ok, changelog} -> {:ok, changelog}
              _ -> {:error, error}
            end

          error ->
            error
        end

      error ->
        error
    end
  end

  defp bootstrap_slug(project_slug, project_id) when is_binary(project_slug) do
    if slug_available?(project_slug) do
      project_slug
    else
      suffix = String.slice(project_id, -12, 12)
      project_slug |> String.slice(0, 87) |> String.trim_trailing("-") |> Kernel.<>("-" <> suffix)
    end
  end

  defp bootstrap_slug(_, project_id) do
    bootstrap_slug("project-" <> String.slice(project_id, -12, 12), project_id)
  end

  defp slug_available?(slug) do
    case Alplus.PublicPages.resolve(slug) do
      {:error, :not_found} -> true
      _ -> false
    end
  end

  defp resolve_entry(%Entry{id: id}, actor), do: resolve_entry(id, actor)

  defp resolve_entry(id, actor) do
    Entry
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read()
    |> one_result()
  end

  defp read_revision(id, actor) do
    Revision
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read()
    |> one_result()
  end

  defp one_result({:ok, [item]}), do: {:ok, item}
  defp one_result({:ok, []}), do: {:error, :not_found}
  defp one_result({:ok, _items}), do: {:error, :not_found}
  defp one_result(error), do: error

  defp find_entry(%Changelog{id: changelog_id} = changelog, attrs, actor) do
    case Map.get(attrs, :entry_handle) do
      nil ->
        find_entry_by_external_id(
          changelog_id,
          attrs.grant_id,
          attrs.external_id,
          actor
        )

      entry_handle ->
        with {:ok, entry} <- resolve_entry(entry_handle, actor),
             true <- entry.changelog_id == changelog.id do
          {:ok, entry}
        else
          _ -> {:error, :not_found}
        end
    end
  end

  defp find_entry_by_external_id(changelog_id, grant_id, external_id, actor) do
    Entry
    |> Ash.Query.for_read(
      :by_external_id,
      %{changelog_id: changelog_id, grant_id: grant_id, external_id: external_id},
      actor: actor
    )
    |> Ash.read()
    |> one_result_or_nil()
  end

  defp one_result_or_nil({:ok, []}), do: {:ok, nil}
  defp one_result_or_nil({:ok, [entry]}), do: {:ok, entry}
  defp one_result_or_nil({:ok, _}), do: {:error, :not_found}
  defp one_result_or_nil(error), do: error

  defp upsert_entry(nil, changelog, attrs, metadata, markdown, actor) do
    entry_attrs = %{
      org_id: changelog.org_id,
      project_id: changelog.project_id,
      changelog_id: changelog.id,
      grant_id: attrs.grant_id,
      external_id: attrs.external_id,
      title: metadata.title
    }

    entry_attrs = Map.merge(entry_attrs, metadata_attrs(metadata))

    with {:ok, entry} <- create_entry(entry_attrs, actor),
         {:ok, _revision} <- create_revision(entry, markdown, 1, actor) do
      {:ok, entry}
    end
  end

  defp upsert_entry(
         %Entry{status: :published} = entry,
         _changelog,
         _attrs,
         _metadata,
         markdown,
         actor
       ) do
    with {:ok, revision} <- current_revision(entry, actor) do
      if revision.status == :published do
        with {:ok, _revision} <-
               create_revision(entry, markdown, revision.revision_number + 1, actor) do
          {:ok, entry}
        end
      else
        with {:ok, _revision} <- update_revision(revision, markdown, actor) do
          {:ok, entry}
        end
      end
    end
  end

  defp upsert_entry(entry, _changelog, _attrs, metadata, markdown, actor) do
    with {:ok, revision} <- current_revision(entry, actor),
         {:ok, _revision} <- update_revision(revision, markdown, actor) do
      update_entry_metadata(entry, metadata, actor)
    end
  end

  defp create_entry(attrs, actor) do
    Entry |> Ash.Changeset.for_create(:create, attrs, actor: actor) |> Ash.create()
  end

  defp create_revision(entry, markdown, number, actor) do
    attrs = %{
      org_id: entry.org_id,
      project_id: entry.project_id,
      changelog_id: entry.changelog_id,
      entry_id: entry.id,
      revision_number: number,
      markdown: markdown
    }

    Revision |> Ash.Changeset.for_create(:create, attrs, actor: actor) |> Ash.create()
  end

  defp current_revision(%Entry{} = entry, actor) do
    Revision
    |> Ash.Query.for_read(:for_entry, %{entry_id: entry.id}, actor: actor)
    |> Ash.Query.sort(revision_number: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read()
    |> one_result()
  end

  defp current_revision(entry, actor) do
    with {:ok, entry} <- resolve_entry(entry, actor), do: current_revision(entry, actor)
  end

  defp update_revision(revision, markdown, actor) do
    revision
    |> Ash.Changeset.for_update(:update, %{markdown: markdown}, actor: actor)
    |> Ash.update()
  end

  defp update_entry_metadata(entry, metadata, actor) do
    entry
    |> Ash.Changeset.for_update(
      :update,
      Map.merge(%{title: metadata.title}, metadata_attrs(metadata)),
      actor: actor
    )
    |> Ash.update()
  end

  defp publish_revision(revision, actor) do
    revision
    |> Ash.Changeset.for_update(:publish, %{}, actor: actor)
    |> Ash.update()
  end

  defp publish_entry_record(entry, metadata, actor) do
    attrs = %{
      title: metadata.title,
      public_slug: entry.public_slug || slug_for(metadata.title, entry.id)
    }

    attrs = Map.merge(attrs, metadata_attrs(metadata))

    entry
    |> Ash.Changeset.for_update(:publish, attrs, actor: actor)
    |> Ash.update()
  end

  defp metadata_attrs(metadata) do
    metadata
    |> Map.take([:summary, :area, :version, :media_url, :media_alt, :media_caption])
    |> Map.put(:summary, metadata.summary || metadata.title)
  end

  defp update_entry_state(entry, action, actor) do
    entry
    |> Ash.Changeset.for_update(action, %{}, actor: actor)
    |> Ash.update()
  end

  defp reserve_changelog_alias(identity, attrs, changelog) do
    slug = Map.get(attrs, :public_slug) || Map.get(attrs, "public_slug") || changelog.public_slug

    if is_binary(slug) do
      case Alplus.PublicPages.reserve_alias_system(identity, slug, "changelog", changelog.id) do
        result -> result
      end
    else
      :ok
    end
  end

  defp public_identity_attrs(attrs) do
    %{
      org_id: Map.get(attrs, :org_id, Map.get(attrs, "org_id")),
      project_id: Map.get(attrs, :project_id, Map.get(attrs, "project_id")),
      public_slug: Map.get(attrs, :public_slug, Map.get(attrs, "public_slug")),
      title: Map.get(attrs, :public_title, Map.get(attrs, "public_title")),
      logo_url: Map.get(attrs, :logo_url, Map.get(attrs, "logo_url"))
    }
  end

  defp put_setting_if_present(target_attrs, target, source_attrs, keys) do
    case Enum.find(keys, &Map.has_key?(source_attrs, &1)) do
      nil -> target_attrs
      key -> Map.put(target_attrs, target, Map.get(source_attrs, key))
    end
  end

  defp setting_attrs(attrs) do
    %{}
    |> put_setting_if_present(:title, attrs, [:public_title, :title, "public_title", "title"])
    |> put_setting_if_present(:public_slug, attrs, [:public_slug, "public_slug"])
    |> put_setting_if_present(:logo_url, attrs, [:logo_url, "logo_url"])
  end

  defp validate_setting_keys(attrs) do
    allowed = [
      :public_title,
      :title,
      :public_slug,
      :logo_url,
      "public_title",
      "title",
      "public_slug",
      "logo_url"
    ]

    case Map.keys(attrs) -- allowed do
      [] -> :ok
      keys -> {:error, {:unsupported_settings, keys}}
    end
  end

  defp changelog_attrs(attrs) do
    Map.take(attrs, [:org_id, :project_id])
  end

  defp require_evidence(entry, actor) do
    SourceReference
    |> Ash.Query.for_read(:for_entry, %{entry_id: entry.id}, actor: actor)
    |> Ash.read()
    |> case do
      {:ok, []} -> {:error, :missing_evidence}
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp replace_sources(entry, changelog, attrs, actor) do
    with {:ok, old_sources} <- read_sources(entry, actor),
         :ok <- destroy_all(old_sources, SourceReference, actor) do
      Enum.reduce_while(Map.get(attrs, :sources, []), :ok, fn source, :ok ->
        source_attrs = %{
          org_id: changelog.org_id,
          project_id: changelog.project_id,
          changelog_id: changelog.id,
          entry_id: entry.id,
          grant_id: attrs.grant_id,
          kind: source.kind,
          url: source.url,
          label: Map.get(source, :label)
        }

        case SourceReference
             |> Ash.Changeset.for_create(:create, source_attrs, actor: actor)
             |> Ash.create() do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp destroy_children(entry, actor) do
    with {:ok, revisions} <- list_revisions(entry, actor: actor),
         :ok <- destroy_all(revisions, Revision, actor),
         {:ok, sources} <- read_sources(entry, actor) do
      destroy_all(sources, SourceReference, actor)
    end
  end

  defp read_sources(entry, actor) do
    SourceReference
    |> Ash.Query.for_read(:for_entry, %{entry_id: entry.id}, actor: actor)
    |> Ash.read()
  end

  defp destroy_all(items, _resource, actor) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case Ash.Changeset.for_destroy(item, :destroy, %{}, actor: actor) |> Ash.destroy() do
        :ok -> {:cont, :ok}
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp destroy_entry(entry, actor) do
    Ash.Changeset.for_destroy(entry, :destroy, %{}, actor: actor) |> Ash.destroy()
  end

  defp transactional(fun) do
    case Ash.transaction([Changelog, Entry, Revision, SourceReference, ActivityEvent], fn ->
           case fun.() do
             {:ok, _} = result -> result
             :ok -> :ok
             {:error, reason} -> Alplus.Repo.rollback(reason)
             other -> Alplus.Repo.rollback(other)
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_event(event_type, entry, revision, sources, actor) do
    attrs = %{
      org_id: entry.org_id,
      project_id: entry.project_id,
      changelog_id: entry.changelog_id,
      entry_id: entry.id,
      revision_id: revision.id,
      actor_id: actor.user_id,
      grant_id: actor.grant_id,
      event_type: event_type,
      public_slug: entry.public_slug,
      evidence_ids: Enum.map(sources, & &1.id),
      correlation_id: actor.correlation_id,
      outcome: "success",
      request_metadata: %{}
    }

    ActivityEvent |> Ash.Changeset.for_create(:record, attrs, actor: actor) |> Ash.create()
  end

  defp record_denied_attempt(%Entry{} = entry, actor, event_type, _changelog) do
    if actor.role in ["owner", "admin"] do
      :ok
    else
      attrs = %{
        org_id: entry.org_id,
        project_id: entry.project_id,
        changelog_id: entry.changelog_id,
        entry_id: entry.id,
        actor_id: actor.user_id,
        grant_id: actor.grant_id,
        event_type: event_type,
        public_slug: entry.public_slug,
        evidence_ids: [],
        correlation_id: actor.correlation_id,
        outcome: "denied",
        request_metadata: %{reason: "forbidden_role"}
      }

      case ActivityEvent
           |> Ash.Changeset.for_create(:record, attrs, actor: actor)
           |> Ash.create() do
        {:ok, _event} ->
          :ok

        {:error, reason} ->
          Logger.error("could not record denied changelog activity: #{inspect(reason)}")
          :ok
      end
    end
  end

  defp record_denied_attempt(nil, actor, event_type, changelog) do
    if actor.role in ["owner", "admin"] do
      :ok
    else
      attrs = %{
        org_id: changelog.org_id,
        project_id: changelog.project_id,
        changelog_id: changelog.id,
        entry_id: nil,
        actor_id: actor.user_id,
        grant_id: actor.grant_id,
        event_type: event_type,
        public_slug: nil,
        evidence_ids: [],
        correlation_id: actor.correlation_id,
        outcome: "denied",
        request_metadata: %{reason: "forbidden_role"}
      }

      case ActivityEvent
           |> Ash.Changeset.for_create(:record, attrs, actor: actor)
           |> Ash.create() do
        {:ok, _event} ->
          :ok

        {:error, reason} ->
          Logger.error("could not record denied changelog activity: #{inspect(reason)}")
          :ok
      end
    end
  end

  defp tombstone(entry, actor) do
    attrs = %{
      org_id: entry.org_id,
      project_id: entry.project_id,
      changelog_id: entry.changelog_id,
      entry_id: entry.id,
      actor_id: actor.user_id,
      grant_id: actor.grant_id,
      event_type: "entry.deleted",
      public_slug: entry.public_slug,
      evidence_ids: [],
      correlation_id: actor.correlation_id,
      outcome: "success",
      request_metadata: %{}
    }

    ActivityEvent |> Ash.Changeset.for_create(:record, attrs, actor: actor) |> Ash.create()
  end

  defp expected_revision?(revision, expected) when expected == revision.revision_number, do: :ok
  defp expected_revision?(_revision, _expected), do: {:error, :stale_revision}
  defp validate_sources([]), do: :ok

  defp validate_sources(sources) when is_list(sources) and sources != [] do
    Enum.reduce_while(sources, :ok, fn source, :ok ->
      with {:ok, kind} <- fetch_source(source, :kind),
           :ok <- validate_source_kind(kind),
           {:ok, url} <- fetch_source(source, :url),
           :ok <- validate_url(url) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_sources(_), do: {:error, :missing_evidence}

  defp fetch_source(source, key) when is_map(source) do
    case Map.fetch(source, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(source, Atom.to_string(key))
    end
  end

  defp validate_source_kind(kind) when kind in @valid_source_kinds, do: :ok
  defp validate_source_kind(_), do: {:error, :invalid_source_kind}

  defp validate_url(url) when is_binary(url) do
    parsed = URI.parse(url)

    if parsed.scheme in ["http", "https"] and is_binary(parsed.host),
      do: :ok,
      else: {:error, :invalid_source_url}
  end

  defp validate_url(_), do: {:error, :invalid_source_url}

  defp slug_for(title, id) do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 86)

    case slug do
      "" -> "entry-" <> String.slice(id, -12, 12)
      value -> value <> "-" <> String.slice(id, -12, 12)
    end
  end
end
