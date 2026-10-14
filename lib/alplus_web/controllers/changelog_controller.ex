defmodule AlplusWeb.ChangelogController do
  @moduledoc """
  Serves the published project Changelog in HTML, RSS, and JSON.

  The canonical project-page identity is the only public slug used by the new
  routes. Legacy HTML addresses redirect permanently. Legacy feeds keep their
  old response shape so existing clients can continue polling them.
  """

  use AlplusWeb, :controller

  alias Alplus.Changelog.Public
  alias Alplus.Status.RateLimiter
  alias AlplusWeb.ChangelogHTML
  alias AlplusWeb.Marketing.Seo

  @cache_control "public, max-age=30, stale-while-revalidate=60, stale-if-error=86400"

  @doc "Renders the canonical project Changelog page."
  def project(conn, %{"status_slug" => slug} = params) do
    case Public.load_for_public_slug(slug, public_options(params)) do
      {:ok, public} ->
        with_public_rate_limit(conn, public, fn conn ->
          canonical_or(conn, public, slug, "/changelog", fn conn ->
            render_project(conn, public, slug, params)
          end)
        end)

      {:error, :not_found} ->
        raise AlplusWeb.NotFoundError
    end
  end

  @doc "Renders one published entry at its immutable canonical slug."
  def project_entry(conn, %{"status_slug" => slug, "entry_slug" => entry_slug}) do
    with {:ok, public} <- Public.load_for_public_slug(slug),
         :ok <- rate_limit_public(public),
         {:ok, entry} <- Public.entry_for_public_slug(slug, entry_slug) do
      canonical_or(conn, public, slug, "/changelog/#{entry_slug}", fn conn ->
        render_entry(conn, public, entry, slug)
      end)
    else
      {:error, :gone} ->
        gone(conn)

      {:error, :not_found} ->
        raise AlplusWeb.NotFoundError

      {:error, :unavailable} ->
        send_resp(conn, :service_unavailable, "Changelog temporarily unavailable")

      {:error, retry_after} when is_integer(retry_after) ->
        rate_limited(conn, retry_after)
    end
  end

  @doc "Serves the canonical project Changelog RSS feed."
  def project_rss(conn, %{"status_slug" => slug} = params) do
    case Public.load_for_public_slug(slug, public_options(params)) do
      {:ok, public} ->
        with_public_rate_limit(conn, public, fn conn ->
          canonical_or(conn, public, slug, "/changelog.rss", fn conn ->
            conn
            |> feed_headers()
            |> put_resp_content_type("application/rss+xml", nil)
            |> send_resp(:ok, ChangelogHTML.rss_xml(public, :canonical))
          end)
        end)

      {:error, :not_found} ->
        raise AlplusWeb.NotFoundError
    end
  end

  @doc "Serves the canonical project Changelog JSON feed."
  def project_json(conn, %{"status_slug" => slug} = params) do
    case Public.load_for_public_slug(slug, public_options(params)) do
      {:ok, public} ->
        with_public_rate_limit(conn, public, fn conn ->
          canonical_or(conn, public, slug, "/changelog.json", fn conn ->
            conn
            |> feed_headers()
            |> json(json_payload(public, :canonical))
          end)
        end)

      {:error, :not_found} ->
        raise AlplusWeb.NotFoundError
    end
  end

  @doc "Redirects one legacy Changelog HTML page to the project-page identity."
  def show(conn, %{"slug" => slug}) do
    case legacy_public(slug) do
      {:ok, public} ->
        with_public_rate_limit(conn, public, fn conn ->
          redirect_to_canonical(conn, public, "/changelog")
        end)

      {:error, :not_found} ->
        raise AlplusWeb.NotFoundError
    end
  end

  @doc "Dispatches one legacy one-segment address, including feed suffixes."
  def legacy_segment(conn, %{"segment" => segment}) do
    cond do
      String.ends_with?(segment, ".rss") ->
        rss(conn, %{"slug" => String.trim_trailing(segment, ".rss")})

      String.ends_with?(segment, ".json") ->
        json_feed(conn, %{"slug" => String.trim_trailing(segment, ".json")})

      true ->
        case Public.load_for_legacy_slug(segment) do
          {:ok, _public} ->
            show(conn, %{"slug" => segment})

          {:error, :not_found} ->
            marketing_entry(conn, %{"entry_slug" => segment})
        end
    end
  end

  @doc "Redirects one legacy entry URL after verifying that the entry is public."
  def entry(conn, %{"slug" => slug, "entry_slug" => entry_slug}) do
    with {:ok, public} <- legacy_public(slug),
         :ok <- rate_limit_public(public),
         {:ok, _entry} <- legacy_entry(public, slug, entry_slug) do
      redirect_to_entry_canonical(conn, public, entry_slug)
    else
      {:error, :gone} -> gone(conn)
      {:error, :not_found} -> raise AlplusWeb.NotFoundError
      {:error, retry_after} when is_integer(retry_after) -> rate_limited(conn, retry_after)
    end
  end

  @doc "Keeps the legacy RSS feed response compatible while the HTML URL moves."
  def rss(conn, %{"slug" => slug}) do
    case legacy_public(slug) do
      {:ok, public} ->
        with_public_rate_limit(conn, public, fn conn ->
          public = legacy_feed_public(public, slug)

          conn
          |> feed_headers()
          |> put_resp_content_type("application/rss+xml", nil)
          |> send_resp(:ok, ChangelogHTML.rss_xml(public, :legacy))
        end)

      {:error, :not_found} ->
        raise AlplusWeb.NotFoundError
    end
  end

  @doc "Keeps the legacy JSON feed fields and entry ordering compatible."
  def json_feed(conn, %{"slug" => slug}) do
    case legacy_public(slug) do
      {:ok, public} ->
        with_public_rate_limit(conn, public, fn conn ->
          public = legacy_feed_public(public, slug)

          conn
          |> feed_headers()
          |> json(json_payload(public, :legacy))
        end)

      {:error, :not_found} ->
        raise AlplusWeb.NotFoundError
    end
  end

  @doc "Renders PostDeploy's own marketing Changelog page."
  def marketing(conn, params) do
    conn =
      conn
      |> Seo.assign_seo(
        title: "PostDeploy Changelog",
        description: "Product updates and release notes from PostDeploy.",
        path: "/changelog",
        noindex: filtered_request?(params)
      )
      |> cache_headers()

    case Public.load_vendor(public_options(params)) do
      {:ok, public} ->
        with_public_rate_limit(conn, public, fn conn ->
          render_loaded_public(conn, public, "/changelog", first_party?: true)
        end)

      {:error, :not_found} ->
        public = empty_vendor_public()

        with_public_rate_limit(conn, public, fn conn ->
          render_loaded_public(conn, public, "/changelog", first_party?: true)
        end)
    end
  end

  @doc "Serves PostDeploy's own Changelog RSS feed."
  def marketing_rss(conn, params) do
    case Public.load_vendor(public_options(params)) do
      {:ok, public} ->
        with_public_rate_limit(conn, public, fn conn ->
          conn
          |> feed_headers()
          |> put_resp_content_type("application/rss+xml", nil)
          |> send_resp(:ok, ChangelogHTML.rss_xml(public, :marketing))
        end)

      {:error, :not_found} ->
        public = empty_vendor_public()

        with_public_rate_limit(conn, public, fn conn ->
          conn
          |> feed_headers()
          |> put_resp_content_type("application/rss+xml", nil)
          |> send_resp(:ok, ChangelogHTML.rss_xml(public, :marketing))
        end)
    end
  end

  @doc "Serves PostDeploy's own Changelog JSON feed."
  def marketing_json(conn, params) do
    case Public.load_vendor(public_options(params)) do
      {:ok, public} ->
        with_public_rate_limit(conn, public, fn conn ->
          conn
          |> feed_headers()
          |> json(json_payload(public, :marketing))
        end)

      {:error, :not_found} ->
        public = empty_vendor_public()

        with_public_rate_limit(conn, public, fn conn ->
          conn
          |> feed_headers()
          |> json(json_payload(public, :marketing))
        end)
    end
  end

  @doc "Renders one PostDeploy Changelog entry at its frozen slug."
  def marketing_entry(conn, %{"entry_slug" => entry_slug}) do
    with {:ok, public} <- Public.load_vendor(),
         :ok <- rate_limit_public(public),
         {:ok, entry} <- Public.vendor_entry(entry_slug) do
      render_entry(conn, public, entry, nil, first_party?: true)
    else
      {:error, :gone} ->
        gone(conn)

      {:error, :not_found} ->
        raise AlplusWeb.NotFoundError

      {:error, :unavailable} ->
        send_resp(conn, :service_unavailable, "Changelog temporarily unavailable")

      {:error, retry_after} when is_integer(retry_after) ->
        rate_limited(conn, retry_after)
    end
  end

  defp render_project(conn, public, slug, params) do
    path = "/status/#{slug}/changelog"

    conn
    |> Seo.assign_seo(
      title: public.public_page.title,
      description: "The latest updates from #{public.public_page.title}.",
      path: path,
      noindex: filtered_request?(params),
      measure_self_tracking: false
    )
    |> cache_headers()
    |> render_loaded_public(public, path,
      changelog_path: path,
      status_path: "/status/#{public.public_page.public_slug}",
      rss_path: "#{path}.rss",
      json_path: "#{path}.json",
      query_path: path_with_filters(path, params),
      first_party?: false,
      noindex?: filtered_request?(params)
    )
  end

  # `first_party?` chooses the route's page layout: the marketing `/changelog`
  # wears the site topbar and footer, a hosted `/status/:slug/changelog` wears
  # the public-page masthead. `postdeploy_owned?` is a separate question about
  # who owns the brand on that page, so PostDeploy's own hosted changelog keeps
  # the local reading chrome while still wearing PostDeploy's lockup.
  defp render_entry(conn, public, entry, slug, opts \\ []) do
    first_party? = Keyword.get(opts, :first_party?, false)

    {path, changelog_path, status_path} =
      if first_party? do
        {
          "/changelog/#{entry.public_slug}",
          "/changelog",
          nil
        }
      else
        {
          "/status/#{slug}/changelog/#{entry.public_slug}",
          "/status/#{public.public_page.public_slug}/changelog",
          "/status/#{public.public_page.public_slug}"
        }
      end

    conn
    |> Seo.assign_seo(
      title: entry.title,
      description: "#{entry.title} from #{public.public_page.title}.",
      path: path,
      measure_self_tracking: first_party?
    )
    |> cache_headers()
    |> render(:entry,
      changelog: public.changelog,
      public_page: public.public_page,
      entry: entry,
      public_slug: public.public_page.public_slug,
      changelog_path: changelog_path,
      status_path: status_path,
      rss_path: if(first_party?, do: "/changelog.rss", else: "#{changelog_path}.rss"),
      json_path: if(first_party?, do: "/changelog.json", else: "#{changelog_path}.json"),
      first_party?: first_party?,
      postdeploy_owned?: public.public_page[:vendor?] == true
    )
  end

  defp render_loaded_public(conn, public, path, opts) do
    changelog_path =
      Keyword.get(
        opts,
        :changelog_path,
        if(public.public_page[:vendor?],
          do: "/changelog",
          else: "/changelog/#{public.changelog.public_slug}"
        )
      )

    first_party? = Keyword.get(opts, :first_party?, public.public_page[:vendor?] == true)

    conn
    |> render(
      :show,
      changelog: public.changelog,
      public_page: public.public_page,
      entries: public.entries,
      pagination: public.pagination,
      filters: public.filters,
      available_areas: public.available_areas,
      public_slug: public.public_page.public_slug,
      changelog_path: changelog_path,
      status_path: Keyword.get(opts, :status_path, public_status_path(public.public_page)),
      rss_path: Keyword.get(opts, :rss_path, "#{changelog_path}.rss"),
      json_path: Keyword.get(opts, :json_path, "#{changelog_path}.json"),
      query_path: Keyword.get(opts, :query_path, path),
      canonical_path: path,
      first_party?: first_party?,
      postdeploy_owned?: public.public_page[:vendor?] == true
    )
  end

  defp legacy_public(slug) do
    Public.load_for_legacy_slug(slug)
  end

  defp legacy_entry(public, slug, entry_slug) do
    case Public.entry(slug, entry_slug) do
      {:ok, _entry} = result ->
        result

      {:error, :gone} = error ->
        error

      {:error, :not_found} ->
        Public.entry_for_public_slug(public.public_page.public_slug, entry_slug)
    end
  end

  defp legacy_feed_public(public, slug) do
    put_in(public, [:changelog, :public_slug], slug)
  end

  defp canonical_or(conn, public, requested_slug, suffix, render_fun) do
    if public.public_page.public_slug != requested_slug do
      redirect_to_canonical(conn, public, suffix)
    else
      render_fun.(conn)
    end
  end

  defp redirect_to_canonical(conn, public, suffix) do
    path =
      if public.public_page[:vendor?] == true,
        do: "/changelog",
        else: "/status/#{public.public_page.public_slug}#{suffix}"

    conn
    |> put_status(:moved_permanently)
    |> redirect(to: path)
  end

  defp redirect_to_entry_canonical(conn, public, entry_slug) do
    path =
      if public.public_page[:vendor?] == true,
        do: "/changelog/#{entry_slug}",
        else: "/status/#{public.public_page.public_slug}/changelog/#{entry_slug}"

    conn
    |> put_status(:moved_permanently)
    |> redirect(to: path)
  end

  defp public_status_path(%{status_slug: status_slug}) when is_binary(status_slug),
    do: "/status/#{status_slug}"

  defp public_status_path(_public_page), do: nil

  defp json_payload(%{public_page: public_page, entries: entries}, :canonical) do
    %{
      title: public_page.title,
      slug: public_page.public_slug,
      entries: json_entries(entries)
    }
  end

  defp json_payload(%{changelog: changelog, entries: entries}, :legacy) do
    %{
      title: changelog.public_title,
      slug: changelog.public_slug,
      entries: json_entries(entries)
    }
  end

  defp json_payload(%{public_page: public_page, entries: entries}, :marketing) do
    %{
      title: public_page.title,
      slug: public_page.public_slug,
      entries: json_entries(entries)
    }
  end

  defp json_entries(entries) do
    Enum.map(entries, fn entry ->
      %{
        slug: entry.public_slug,
        title: entry.title,
        published_at: DateTime.to_iso8601(entry.published_at),
        html: entry.html
      }
      |> maybe_put_json(:summary, entry.summary)
      |> maybe_put_json(:area, entry.area)
      |> maybe_put_json(:version, entry.version)
      |> maybe_put_json(:media_url, entry.media_url)
      |> maybe_put_json(:media_alt, entry.media_alt)
      |> maybe_put_json(:media_caption, entry.media_caption)
    end)
  end

  defp maybe_put_json(map, _key, nil), do: map
  defp maybe_put_json(map, key, value), do: Map.put(map, key, value)

  defp empty_vendor_public do
    %{
      changelog: %{public_title: "PostDeploy Changelog", public_slug: "postdeploy", logo_url: nil},
      public_page: %{
        public_slug: "postdeploy",
        title: "PostDeploy Changelog",
        logo_url: nil,
        status_slug: nil,
        changelog_slug: "postdeploy",
        vendor?: true
      },
      entries: [],
      pagination: %{page: 1, page_size: 24, has_next: false},
      filters: %{area: nil, version: nil, year: nil},
      available_areas: ~w(monitor observe measure platform)
    }
  end

  defp public_options(params) do
    [
      page: Map.get(params, "page"),
      area: Map.get(params, "area"),
      version: Map.get(params, "version"),
      year: Map.get(params, "year")
    ]
  end

  defp filtered_request?(params) do
    Map.get(params, "page") not in [nil, "", "1"] or
      Map.get(params, "area") not in [nil, ""] or
      Map.get(params, "version") not in [nil, ""] or
      Map.get(params, "year") not in [nil, ""]
  end

  defp path_with_filters(path, params) do
    params =
      params
      |> Map.take(["page", "area", "version", "year"])
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

    case URI.encode_query(params) do
      "" -> path
      query -> path <> "?" <> query
    end
  end

  defp with_public_rate_limit(conn, public, render_fun) do
    case rate_limit_public(public) do
      :ok -> render_fun.(conn)
      {:error, retry_after} -> rate_limited(conn, retry_after)
    end
  end

  defp rate_limit_public(%{public_page: %{id: page_id}}) when is_binary(page_id) do
    RateLimiter.check(page_id)
  end

  defp rate_limit_public(%{public_page: %{public_slug: slug}}) when is_binary(slug) do
    RateLimiter.check("changelog:" <> slug)
  end

  defp rate_limit_public(_public), do: RateLimiter.check("changelog:unknown")

  defp gone(conn) do
    conn
    |> put_status(:gone)
    |> put_resp_content_type("text/plain", nil)
    |> send_resp(:gone, "Gone")
  end

  defp rate_limited(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(429, "Too Many Requests")
  end

  defp cache_headers(conn), do: put_resp_header(conn, "cache-control", @cache_control)

  defp feed_headers(conn) do
    conn
    |> cache_headers()
    |> put_resp_header("x-robots-tag", "noindex")
  end
end
