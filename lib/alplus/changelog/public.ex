defmodule Alplus.Changelog.Public do
  @moduledoc "Read published changelog content without exposing tenant actors."

  require Ash.Query
  require Logger

  alias Alplus.Changelog.{
    ActivityEvent,
    Changelog,
    Entry,
    FrontMatter,
    Markdown,
    PublicActor,
    Revision
  }

  # Public reads intentionally fetch one bounded page plus one sentinel row.
  # Feeds use the same cap as HTML, so a large tenant cannot turn a request into
  # an unbounded revision scan.
  @public_page_size 24
  @max_public_page 100
  @public_areas ~w(monitor observe measure platform)

  @spec resolve(String.t()) ::
          {:ok,
           %{
             changelog: Changelog.t(),
             actor: PublicActor.t(),
             identity: Alplus.PublicPages.PublicPage.t()
           }}
          | {:error, :not_found}
  def resolve(slug) when is_binary(slug) do
    with {:ok, %{identity: identity}} <- Alplus.PublicPages.resolve_changelog(slug),
         {:ok, changelog} <- find_changelog_for_project(identity.project_id),
         actor <- actor_for(changelog, identity),
         {:ok, changelog} <- read_public_changelog(changelog.id, actor) do
      {:ok, %{changelog: changelog, actor: actor, identity: identity}}
    else
      _ -> {:error, :not_found}
    end
  end

  def resolve(_), do: {:error, :not_found}

  @spec resolve_vendor() ::
          {:ok,
           %{
             changelog: Changelog.t(),
             actor: PublicActor.t(),
             identity: Alplus.PublicPages.PublicPage.t()
           }}
          | {:error, :not_found}
  def resolve_vendor do
    actor = PublicActor.for_vendor()

    with {:ok, changelog} <- read_vendor_changelog(actor),
         {:ok, identity} <- Alplus.PublicPages.public_identity_for_project(changelog.project_id) do
      {:ok, %{changelog: changelog, actor: actor_for(changelog, identity), identity: identity}}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  True when a project is the designated PostDeploy vendor project.

  Vendor designation is the one authoritative statement that a public page
  belongs to PostDeploy rather than to a customer. It lives on the changelog
  row, is globally unique, and is never inferred from a slug, a title, or an
  uploaded logo, all of which a tenant controls.
  """
  @spec vendor_project?(String.t()) :: boolean()
  def vendor_project?(project_id) when is_binary(project_id) do
    case read_vendor_changelog(PublicActor.for_vendor()) do
      {:ok, changelog} -> changelog.project_id == project_id
      _ -> false
    end
  end

  def vendor_project?(_project_id), do: false

  defp resolve_for_project(project_id) do
    with {:ok, changelog} <- find_changelog_for_project(project_id),
         {:ok, identity} <- Alplus.PublicPages.public_identity_for_project(changelog.project_id),
         actor <- actor_for(changelog, identity),
         {:ok, changelog} <- read_public_changelog(changelog.id, actor) do
      {:ok, %{changelog: changelog, actor: actor, identity: identity}}
    else
      _ -> {:error, :not_found}
    end
  end

  @spec load(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def load(slug, opts \\ []) do
    with {:ok, resolved} <- resolve(slug) do
      load_resolved(resolved, :read_public, public_options(opts))
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Loads a legacy Changelog alias without accepting a Status alias."
  @spec load_for_legacy_slug(String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found}
  def load_for_legacy_slug(slug, opts \\ [])

  def load_for_legacy_slug(slug, opts) when is_binary(slug) do
    with {:ok, %{identity: identity, alias?: alias?}} <-
           Alplus.PublicPages.resolve_changelog(slug),
         {:ok, public} <- load_identity(identity, public_options(opts)) do
      {:ok,
       public
       |> Map.put(:requested_slug, slug)
       |> Map.put(:alias?, alias?)}
    else
      _ -> {:error, :not_found}
    end
  end

  def load_for_legacy_slug(_, _), do: {:error, :not_found}

  @spec load_vendor(keyword()) :: {:ok, map()} | {:error, :not_found}
  def load_vendor(opts \\ []) do
    with {:ok, resolved} <- resolve_vendor() do
      load_resolved(resolved, :public_for_vendor, public_options(opts))
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Loads every published vendor entry for sitemap generation."
  @spec all_vendor_entries() :: {:ok, [map()]} | {:error, :not_found}
  def all_vendor_entries do
    with {:ok, %{changelog: changelog, actor: actor}} <- resolve_vendor(),
         {:ok, entries} <- list_all_entries(actor, :public_for_vendor, changelog.id),
         {:ok, revisions} <- current_revisions(entries, actor) do
      {:ok, Enum.flat_map(entries, &public_entry(&1, revisions))}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Loads a bounded public vendor changelog from an already resolved vendor."
  @spec load_resolved_vendor(map(), keyword()) ::
          {:ok, map()} | {:error, :not_found}
  def load_resolved_vendor(resolved, opts \\ []) do
    load_resolved(resolved, :public_for_vendor, public_options(opts))
  end

  @spec load_for_project(String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found}
  def load_for_project(project_id, opts \\ [])

  def load_for_project(project_id, opts) when is_binary(project_id) do
    with {:ok, resolved} <- resolve_for_project(project_id) do
      load_resolved(resolved, :public_for_changelog, public_options(opts))
    else
      _ -> {:error, :not_found}
    end
  end

  def load_for_project(_, _), do: {:error, :not_found}

  @doc "Loads the public Changelog through the shared project-page identity."
  @spec load_for_public_slug(String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found}
  def load_for_public_slug(slug, opts \\ [])

  def load_for_public_slug(slug, opts) when is_binary(slug) do
    with {:ok, %{identity: identity, alias?: alias?}} <-
           Alplus.PublicPages.resolve(slug, alias_kind: "changelog"),
         {:ok, public} <- load_identity(identity, public_options(opts)) do
      {:ok,
       public
       |> Map.put(:requested_slug, slug)
       |> Map.put(:alias?, alias?)}
    else
      _ -> {:error, :not_found}
    end
  end

  def load_for_public_slug(_, _), do: {:error, :not_found}

  @doc "Finds one published entry through the shared project-page identity."
  @spec entry_for_public_slug(String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :gone | :unavailable}
  def entry_for_public_slug(public_slug, entry_slug)
      when is_binary(public_slug) and is_binary(entry_slug) do
    with {:ok, %{identity: identity}} <-
           Alplus.PublicPages.resolve(public_slug, alias_kind: "changelog"),
         {:ok, changelog} <- find_changelog_for_project(identity.project_id),
         actor <- actor_for(changelog, identity) do
      case find_entry(changelog.id, entry_slug, actor) do
        {:ok, entry} ->
          case current_revisions([entry], actor) do
            {:ok, revisions} ->
              case public_entry(entry, revisions) do
                [public] ->
                  with {:ok, adjacent} <- adjacent_entries(changelog.id, entry, actor) do
                    {:ok, Map.merge(public, adjacent)}
                  end

                [] ->
                  {:error, :not_found}
              end

            {:error, _reason} ->
              {:error, :unavailable}
          end

        {:error, :not_found} ->
          tombstone(changelog.id, entry_slug, actor)
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def entry_for_public_slug(_, _), do: {:error, :not_found}

  @doc "Finds one published PostDeploy entry without accepting a customer slug."
  @spec vendor_entry(String.t()) ::
          {:ok, map()} | {:error, :not_found | :gone | :unavailable}
  def vendor_entry(entry_slug) when is_binary(entry_slug) do
    with {:ok, %{changelog: changelog, actor: actor}} <- resolve_vendor(),
         {:ok, entry} <- find_entry(changelog.id, entry_slug, actor) do
      case current_revisions([entry], actor) do
        {:ok, revisions} ->
          case public_entry(entry, revisions) do
            [public] ->
              with {:ok, adjacent} <- adjacent_entries(changelog.id, entry, actor) do
                {:ok, Map.merge(public, adjacent)}
              end

            [] ->
              {:error, :not_found}
          end

        {:error, _reason} ->
          {:error, :unavailable}
      end
    else
      {:error, :not_found} -> tombstone_for_vendor(entry_slug)
    end
  end

  def vendor_entry(_), do: {:error, :not_found}

  defp load_identity(identity, opts) do
    case find_changelog_for_project(identity.project_id) do
      {:ok, changelog} ->
        actor = actor_for(changelog, identity)

        with {:ok, changelog} <- read_public_changelog(changelog.id, actor),
             {:ok, entries, pagination} <-
               list_entries(actor, :public_for_changelog, changelog.id, opts),
             {:ok, revisions} <- current_revisions(entries, actor) do
          {:ok, public_snapshot(changelog, identity, revisions, entries, pagination, opts)}
        end

      {:error, :not_found} ->
        {:ok, empty_snapshot(identity, opts)}
    end
  end

  defp load_resolved(
         %{changelog: changelog, actor: actor, identity: identity},
         entry_action,
         opts
       ) do
    with {:ok, entries, pagination} <- list_entries(actor, entry_action, changelog.id, opts),
         {:ok, revisions} <- current_revisions(entries, actor) do
      {:ok, public_snapshot(changelog, identity, revisions, entries, pagination, opts)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp public_snapshot(changelog, identity, revisions, entries, pagination, opts) do
    entries = Enum.flat_map(entries, &public_entry(&1, revisions))

    %{
      changelog: %{
        public_title: identity.title,
        public_slug: identity.public_slug,
        logo_url: identity.logo_url
      },
      public_page: public_page(identity, changelog),
      entries: entries,
      pagination: pagination,
      filters: %{area: opts[:area], version: opts[:version], year: opts[:year]},
      available_areas: @public_areas
    }
  end

  defp empty_snapshot(identity, opts) do
    changelog = %{
      public_title: identity.title,
      public_slug: identity.public_slug,
      logo_url: identity.logo_url
    }

    %{
      changelog: changelog,
      public_page: public_page(identity, nil),
      entries: [],
      pagination: %{page: opts[:page], page_size: opts[:page_size], has_next: false},
      filters: %{area: opts[:area], version: opts[:version], year: opts[:year]},
      available_areas: @public_areas
    }
  end

  @spec entry(String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :gone | :unavailable}
  def entry(changelog_slug, entry_slug)
      when is_binary(changelog_slug) and is_binary(entry_slug) do
    case resolve(changelog_slug) do
      {:ok, %{changelog: changelog, actor: actor}} ->
        case find_entry(changelog.id, entry_slug, actor) do
          {:ok, entry} ->
            case current_revisions([entry], actor) do
              {:ok, revisions} ->
                case public_entry(entry, revisions) do
                  [public] ->
                    with {:ok, adjacent} <- adjacent_entries(changelog.id, entry, actor) do
                      {:ok, Map.merge(public, adjacent)}
                    end

                  [] ->
                    {:error, :not_found}
                end

              {:error, _reason} ->
                {:error, :unavailable}
            end

          {:error, :not_found} ->
            tombstone(changelog.id, entry_slug, actor)
        end

      _ ->
        {:error, :not_found}
    end
  end

  def entry(_, _), do: {:error, :not_found}

  defp actor_for(changelog, identity) do
    %PublicActor{
      slug: identity.public_slug,
      changelog_id: changelog.id,
      org_id: changelog.org_id,
      project_id: changelog.project_id,
      now: DateTime.utc_now()
    }
  end

  defp public_page(identity, changelog) do
    %{
      id: identity.id,
      public_slug: identity.public_slug,
      title: identity.title,
      logo_url: identity.logo_url,
      published_at: identity.published_at,
      status_slug: if(changelog && changelog.vendor?, do: nil, else: identity.public_slug),
      changelog_slug: identity.public_slug,
      vendor?: changelog && changelog.vendor? == true
    }
  end

  defp find_changelog_for_project(project_id) do
    actor = PublicActor.for_project(project_id)

    Changelog
    |> Ash.Query.for_read(:public_by_project, %{project_id: project_id}, actor: actor)
    |> Ash.read()
    |> one_result()
  end

  defp read_public_changelog(id, actor) do
    Ash.get(Changelog, id, action: :read_public, actor: actor)
  end

  defp read_vendor_changelog(actor) do
    Changelog
    |> Ash.Query.for_read(:read_vendor, %{}, actor: actor)
    |> Ash.read()
    |> one_result()
  end

  defp list_entries(actor, :read_public, _changelog_id, opts) do
    Entry
    |> Ash.Query.for_read(:read_public, %{}, actor: actor)
    |> filter_public_query(opts)
    |> paginate_entries(opts)
    |> Ash.read()
    |> page_result(opts)
  end

  defp list_entries(actor, action, changelog_id, opts) do
    Entry
    |> Ash.Query.for_read(action, %{changelog_id: changelog_id}, actor: actor)
    |> filter_public_query(opts)
    |> paginate_entries(opts)
    |> Ash.read()
    |> page_result(opts)
  end

  defp list_all_entries(actor, action, changelog_id) do
    Entry
    |> Ash.Query.for_read(action, %{changelog_id: changelog_id}, actor: actor)
    |> Ash.Query.sort(published_at: :desc, id: :desc)
    |> Ash.read()
  end

  defp paginate_entries(query, opts) do
    query
    |> Ash.Query.sort(published_at: :desc, id: :desc)
    |> Ash.Query.offset((opts[:page] - 1) * opts[:page_size])
    |> Ash.Query.limit(opts[:page_size] + 1)
  end

  # Keep filtering in SQL so the sentinel row and page metadata describe the
  # filtered result set. Applying these predicates after `limit/offset` would
  # silently drop matching entries and make pagination inaccurate.
  defp filter_public_query(query, opts) do
    query
    |> maybe_filter_area(opts[:area])
    |> maybe_filter_version(opts[:version])
    |> maybe_filter_year(opts[:year])
  end

  defp maybe_filter_area(query, nil), do: query
  defp maybe_filter_area(query, area), do: Ash.Query.filter(query, area == ^area)

  defp maybe_filter_version(query, nil), do: query
  defp maybe_filter_version(query, version), do: Ash.Query.filter(query, version == ^version)

  defp maybe_filter_year(query, nil), do: query

  defp maybe_filter_year(query, year) do
    {:ok, from} = DateTime.new(Date.new!(year, 1, 1), ~T[00:00:00], "Etc/UTC")
    {:ok, until} = DateTime.new(Date.new!(year + 1, 1, 1), ~T[00:00:00], "Etc/UTC")

    Ash.Query.filter(query, published_at >= ^from and published_at < ^until)
  end

  defp page_result({:ok, entries}, opts) do
    page_entries = Enum.take(entries, opts[:page_size])

    {:ok, page_entries,
     %{
       page: opts[:page],
       page_size: opts[:page_size],
       has_next: length(entries) > opts[:page_size]
     }}
  end

  defp page_result(other, _opts), do: other

  defp find_entry(changelog_id, slug, actor) do
    Entry
    |> Ash.Query.for_read(
      :public_by_slug,
      %{changelog_id: changelog_id, slug: slug},
      actor: actor
    )
    |> Ash.read()
    |> one_result()
  end

  defp tombstone(changelog_id, slug, actor) do
    ActivityEvent
    |> Ash.Query.for_read(
      :tombstone_for_slug,
      %{changelog_id: changelog_id, slug: slug},
      actor: actor
    )
    |> Ash.read()
    |> case do
      {:ok, [_event | _]} -> {:error, :gone}
      _ -> {:error, :not_found}
    end
  end

  # A published entry always has a revision, because publication creates one.
  # Return a list so a row that breaks that invariant drops out of the public
  # stream instead of reaching a template as a map with no keys. Never return a
  # placeholder: the caller would render an entry with no title and no body.
  defp public_entry(entry, revisions) do
    case Map.get(revisions, entry.id) do
      %Revision{} = revision ->
        metadata =
          case FrontMatter.parse_public(revision.markdown) do
            {:ok, metadata} -> metadata
            {:error, _reason} -> %{}
          end

        summary = Map.get(entry, :summary) || metadata[:summary]
        area = Map.get(entry, :area) || metadata[:area]
        version = Map.get(entry, :version) || metadata[:version]
        media_url = Map.get(entry, :media_url) || metadata[:media_url]
        media_alt = Map.get(entry, :media_alt) || metadata[:media_alt]
        media_caption = Map.get(entry, :media_caption) || metadata[:media_caption]

        [
          %{
            public_slug: entry.public_slug,
            title: entry.title,
            published_at: entry.published_at,
            html: Markdown.render(revision.markdown),
            summary: summary,
            area: area,
            version: version,
            media_url: media_url,
            media_alt: media_alt,
            media_caption: media_caption
          }
        ]

      nil ->
        Logger.warning(
          "changelog entry #{entry.id} is published but has no revision; omitting it " <>
            "from public output"
        )

        []
    end
  end

  defp current_revisions([], _actor), do: {:ok, %{}}

  defp current_revisions(entries, actor) do
    entry_ids = Enum.map(entries, & &1.id)

    Revision
    |> Ash.Query.for_read(:public_for_entries, %{entry_ids: entry_ids}, actor: actor)
    |> Ash.Query.distinct(:entry_id)
    |> Ash.Query.sort(revision_number: :desc)
    |> Ash.read()
    |> case do
      {:ok, revisions} ->
        {:ok,
         Enum.reduce(revisions, %{}, fn revision, acc ->
           Map.put_new(acc, revision.entry_id, revision)
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp adjacent_entries(changelog_id, %Entry{published_at: published_at}, actor)
       when not is_nil(published_at) do
    previous =
      Entry
      |> Ash.Query.for_read(:public_for_changelog, %{changelog_id: changelog_id}, actor: actor)
      |> Ash.Query.filter(published_at < ^published_at)
      |> Ash.Query.sort(published_at: :desc, id: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read()
      |> first_result()

    following =
      Entry
      |> Ash.Query.for_read(:public_for_changelog, %{changelog_id: changelog_id}, actor: actor)
      |> Ash.Query.filter(published_at > ^published_at)
      |> Ash.Query.sort(published_at: :asc, id: :asc)
      |> Ash.Query.limit(1)
      |> Ash.read()
      |> first_result()

    adjacent = Enum.reject([previous, following], &is_nil/1)

    with {:ok, revisions} <- current_revisions(adjacent, actor) do
      {:ok,
       %{
         previous_entry: adjacent_public_entry(previous, revisions),
         next_entry: adjacent_public_entry(following, revisions)
       }}
    end
  end

  defp adjacent_entries(_changelog_id, _entry, _actor),
    do: {:ok, %{previous_entry: nil, next_entry: nil}}

  defp adjacent_public_entry(nil, _revisions), do: nil

  defp adjacent_public_entry(entry, revisions) do
    case public_entry(entry, revisions) do
      [public] -> public
      [] -> nil
    end
  end

  defp tombstone_for_vendor(slug) do
    with {:ok, %{changelog: changelog, actor: actor}} <- resolve_vendor() do
      tombstone(changelog.id, slug, actor)
    else
      _ -> {:error, :not_found}
    end
  end

  defp public_options(opts) do
    %{
      page: bounded_page(Keyword.get(opts, :page)),
      page_size: bounded_page_size(Keyword.get(opts, :limit)),
      area: normalize_area(Keyword.get(opts, :area)),
      version: normalize_version(Keyword.get(opts, :version)),
      year: normalize_year(Keyword.get(opts, :year))
    }
  end

  defp bounded_page(page) when is_integer(page), do: page |> max(1) |> min(@max_public_page)

  defp bounded_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {page, ""} -> bounded_page(page)
      _ -> 1
    end
  end

  defp bounded_page(_), do: 1

  defp bounded_page_size(size) when is_integer(size), do: size |> max(1) |> min(@public_page_size)
  defp bounded_page_size(_), do: @public_page_size

  defp normalize_area(area) when is_binary(area) do
    area = String.downcase(String.trim(area))
    if area in @public_areas, do: area, else: nil
  end

  defp normalize_area(_), do: nil

  defp normalize_version(version) when is_binary(version) do
    version = String.trim(version)
    if version != "" and byte_size(version) <= 80, do: version, else: nil
  end

  defp normalize_version(_), do: nil

  defp normalize_year(year) when is_integer(year), do: normalize_year_value(year)

  defp normalize_year(year) when is_binary(year) do
    case Integer.parse(year) do
      {year, ""} -> normalize_year_value(year)
      _ -> nil
    end
  end

  defp normalize_year(_), do: nil

  defp normalize_year_value(year) when year in 1970..2200, do: year
  defp normalize_year_value(_), do: nil

  defp one_result({:ok, [item]}), do: {:ok, item}
  defp one_result({:ok, []}), do: {:error, :not_found}
  defp one_result({:ok, _}), do: {:error, :not_found}
  defp one_result(_), do: {:error, :not_found}

  defp first_result({:ok, [item | _]}), do: item
  defp first_result(_), do: nil
end
