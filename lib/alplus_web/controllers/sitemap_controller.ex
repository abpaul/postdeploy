defmodule AlplusWeb.SitemapController do
  @moduledoc """
  `GET /sitemap.xml` (ARCHITECTURE.md §9, BUILD.md Phase 4). Lists every
  published `Alplus.Content` page, guide and comparison. Never lists a
  `/dashboard/` URL — there is nothing to exclude explicitly, since none of
  those resources describe a dashboard route in the first place.

  Ported from `workers/www/site/pages/sitemap.xml.ts`.
  """

  use AlplusWeb, :controller

  alias Alplus.Changelog.Public, as: PublicChangelog
  alias Alplus.Content
  alias AlplusWeb.Blog
  alias AlplusWeb.Marketing.Seo

  def index(conn, _params) do
    {:ok, pages} = Content.list_pages()
    {:ok, guides} = Content.list_guides()
    {:ok, comparisons} = Content.list_comparisons()
    {:ok, articles} = Blog.list()

    # Only `Page` carries its own `priority` (home/pricing get "1.0", the
    # rest "0.8"); `Guide` and `Comparison` have no such attribute, so both
    # default to "0.8" — the same value the old site (`lib/pages.ts) gave
    # every guide and comparison page.
    page_entries = Enum.map(pages, &{&1.path, &1.lastmod, &1.priority})
    guide_entries = Enum.map(guides, &{&1.path, &1.lastmod, "0.8"})
    comparison_entries = Enum.map(comparisons, &{&1.path, &1.lastmod, "0.8"})
    article_entries = Enum.map(articles, &{"/blog/#{&1.slug}", &1.published_at, "0.8"})

    urls =
      ([
         {"/changelog", nil, "0.8"},
         {"/blog", nil, "0.8"},
         {"/tools/website-health-check", nil, "0.8"}
       ] ++
         changelog_entries() ++
         page_entries ++ guide_entries ++ comparison_entries ++ article_entries)
      |> Enum.map_join("\n", &sitemap_url/1)

    body =
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" <>
        "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n" <>
        urls <> "\n</urlset>\n"

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  defp changelog_entries do
    case PublicChangelog.all_vendor_entries() do
      {:ok, entries} ->
        Enum.map(entries, fn entry ->
          {"/changelog/#{entry.public_slug}", entry.published_at, "0.8"}
        end)

      _ ->
        []
    end
  end

  defp sitemap_url({path, lastmod, priority}) do
    lastmod =
      case lastmod do
        nil -> ""
        %Date{} = date -> "<lastmod>#{xml_escape(date)}</lastmod>"
        %DateTime{} = datetime -> "<lastmod>#{xml_escape(datetime)}</lastmod>"
        value -> "<lastmod>#{xml_escape(value)}</lastmod>"
      end

    "  <url><loc>#{xml_escape(Seo.origin() <> path)}</loc>#{lastmod}<priority>#{xml_escape(priority)}</priority></url>"
  end

  defp xml_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
