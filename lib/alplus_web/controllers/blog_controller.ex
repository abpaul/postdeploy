defmodule AlplusWeb.BlogController do
  use AlplusWeb, :controller

  alias AlplusWeb.{Blog, Marketing.Seo}

  @no_store "no-store"

  def index(conn, _params) do
    {:ok, articles} = Blog.list()

    conn
    |> put_no_store()
    |> Seo.assign_seo(
      title: "PostDeploy blog",
      description:
        "Practical guidance for uptime, cron jobs, errors, analytics, and observability.",
      path: "/blog"
    )
    |> assign(:articles, articles)
    |> render(:index)
  end

  def show(conn, %{"slug" => slug}) do
    with {:ok, article} <- Blog.get_by_slug(slug),
         {:ok, articles} <- Blog.list() do
      article = Blog.project(article, articles)

      conn
      |> put_no_store()
      |> Seo.assign_seo(
        title: article.title,
        description: article.description,
        path: "/blog/#{article.slug}",
        og_title: article.title,
        og_description: article.description,
        og_type: "article",
        article_published_time: DateTime.to_iso8601(article.published_at),
        json_ld: [Seo.blog_posting_schema(article)]
      )
      |> assign(:article, article)
      |> render(:show)
    else
      _ -> conn |> put_no_store() |> send_resp(404, "Not found")
    end
  end

  def posts_json(conn, _params) do
    {:ok, articles} = Blog.list()
    conn |> put_no_store() |> json(Enum.map(articles, &json_article(Blog.project(&1, articles))))
  end

  def post_json(conn, %{"slug" => slug}) do
    slug = String.replace(slug, ~r/\.json\z/, "")

    with {:ok, article} <- Blog.get_by_slug(slug),
         {:ok, articles} <- Blog.list() do
      conn |> put_no_store() |> json(json_article(Blog.project(article, articles)))
    else
      _ -> conn |> put_no_store() |> send_resp(404, "Not found")
    end
  end

  def feed(conn, _params) do
    {:ok, articles} = Blog.list()

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel><title>PostDeploy blog</title><link>#{Seo.origin()}/blog</link><description>PostDeploy blog</description>#{Enum.map_join(articles, &rss_item/1)}</channel></rss>
    """

    conn
    |> put_no_store()
    |> put_resp_content_type("application/rss+xml", nil)
    |> send_resp(200, xml)
  end

  defp json_article(article) do
    %{
      title: article.title,
      description: article.description,
      slug: article.slug,
      published_at: DateTime.to_iso8601(article.published_at),
      keywords: article.keywords,
      cluster: article.cluster,
      intent: article.intent,
      internal_links: article.internal_links,
      sources: article.sources,
      body_html: article.body_html,
      url: Seo.origin() <> "/blog/#{article.slug}"
    }
  end

  defp rss_item(article) do
    "<item><title>#{xml_escape(article.title)}</title><link>#{Seo.origin()}/blog/#{xml_escape(article.slug)}</link><guid>#{Seo.origin()}/blog/#{xml_escape(article.slug)}</guid><pubDate>#{Calendar.strftime(article.published_at, "%a, %d %b %Y %H:%M:%S GMT")}</pubDate><description>#{xml_escape(article.description)}</description></item>"
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

  defp put_no_store(conn), do: put_resp_header(conn, "cache-control", @no_store)
end
