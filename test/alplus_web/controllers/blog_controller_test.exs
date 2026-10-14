defmodule AlplusWeb.BlogControllerTest do
  use AlplusWeb.ConnCase, async: true

  alias Alplus.Content

  setup do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, published} = create_article("published", DateTime.add(now, -3600, :second))
    {:ok, future} = create_article("future", DateTime.add(now, 3600, :second))

    %{published: published, future: future}
  end

  test "future articles return no-store 404 for HTML and JSON", %{conn: conn} do
    conn = get(conn, ~p"/blog/future")
    assert response(conn, 404) == "Not found"
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    conn = get(build_conn(), "/blog/posts/future.json")
    assert response(conn, 404) == "Not found"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "Ash list, slug, and id reads exclude future articles", %{future: future} do
    {:ok, articles} = Content.list_articles()
    refute Enum.any?(articles, &(&1.id == future.id))
    assert {:error, _} = Content.get_article_by_slug(future.slug)
    assert {:error, _} = Content.get_article_by_id(future.id)
  end

  test "future articles stay out of listing and RSS", %{conn: conn, published: published} do
    assert html_response(get(conn, ~p"/blog"), 200) =~ published.title
    refute html_response(get(build_conn(), ~p"/blog"), 200) =~ "future"

    rss = conn |> get(~p"/blog/feed.xml") |> response(200)
    assert rss =~ published.slug
    refute rss =~ "future"
  end

  test "published article emits canonical metadata and BlogPosting schema", %{
    conn: conn,
    published: article
  } do
    html = conn |> get(~p"/blog/#{article.slug}") |> html_response(200)
    doc = LazyHTML.from_document(html)

    assert doc |> LazyHTML.query(~s(link[rel="canonical"])) |> LazyHTML.attribute("href") == [
             "https://postdeploy.dev/blog/published"
           ]

    assert doc |> LazyHTML.query(~s(meta[property="og:type"])) |> LazyHTML.attribute("content") ==
             ["article"]

    assert html =~ ~s("@type":"BlogPosting")

    assert doc |> LazyHTML.query("time") |> LazyHTML.attribute("datetime") == [
             DateTime.to_iso8601(article.published_at)
           ]
  end

  defp create_article(slug, published_at) do
    Content.create_article(
      %{
        slug: slug,
        title: "Article #{slug}",
        description: "Description #{slug}",
        published_at: published_at,
        keywords: ["keyword"],
        cluster: "uptime",
        intent: "informational",
        internal_links: [],
        sources: ["https://example.com/source"],
        body_html: ~s(<p>Body <a href="/blog/future">future</a></p>)
      },
      authorize?: false
    )
  end
end
