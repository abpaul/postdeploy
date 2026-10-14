defmodule AlplusWeb.BlogPublicationTest do
  use AlplusWeb.ConnCase, async: true

  alias Alplus.Content
  alias Alplus.Seo.{Audit, Inventory}
  alias AlplusWeb.Blog

  setup do
    now = DateTime.utc_now()
    {:ok, visible} = create("visible", DateTime.add(now, -3600, :second))
    {:ok, future} = create("scheduled", DateTime.add(now, 86_400, :second))
    %{visible: visible, future: future}
  end

  test "all public collections exclude future data and reject caching" do
    for {path, accept} <- [
          {"/blog", "text/html"},
          {"/blog/feed.xml", "application/rss+xml"},
          {"/blog/posts.json", "application/json"},
          {"/sitemap.xml", "*/*"},
          {"/llms.txt", "*/*"}
        ] do
      conn = build_conn() |> put_req_header("accept", accept) |> get(path)
      body = response(conn, 200)
      assert body =~ "visible"
      refute body =~ "/blog/scheduled"
      refute body =~ "Title scheduled"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    assert get(build_conn(), "/blog/posts.json") |> json_response(200) |> Enum.map(& &1["slug"]) ==
             ["visible"]
  end

  test "future and unknown HTML and JSON URLs return no-store 404" do
    for path <- [
          "/blog/scheduled",
          "/blog/missing",
          "/blog/posts/scheduled.json",
          "/blog/posts/missing.json"
        ] do
      conn = get(build_conn(), path)
      assert response(conn, 404) == "Not found"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  test "direct Ash reads cannot retrieve scheduled records", %{future: future} do
    assert {:error, _} = Ash.get(Content.Article, future.id)
    assert {:error, _} = Content.get_article_by_id(future.id)
    assert {:error, _} = Content.get_article_by_slug("scheduled")
    {:ok, rows} = Content.list_articles()
    assert Enum.map(rows, & &1.slug) == ["visible"]
  end

  test "the UTC boundary includes equality and excludes one microsecond later" do
    at = DateTime.add(DateTime.utc_now(), -60, :second)
    {:ok, _} = create("at-boundary", at)
    {:ok, _} = create("after-boundary", DateTime.add(at, 1, :microsecond))
    {:ok, rows} = Blog.list(at)
    assert "at-boundary" in Enum.map(rows, & &1.slug)
    refute "after-boundary" in Enum.map(rows, & &1.slug)
    assert {:ok, %{slug: "at-boundary"}} = Blog.get_by_slug("at-boundary", at)
    assert {:error, :not_found} = Blog.get_by_slug("after-boundary", at)
  end

  test "a future clock cannot bypass the resource policy" do
    at = DateTime.add(DateTime.utc_now(), 172_800, :second)
    {:ok, rows} = Blog.list(at)
    assert Enum.map(rows, & &1.slug) == ["visible"]
    assert {:error, _} = Blog.get_by_slug("scheduled", at)
  end

  test "publication and rescheduling update every surface on the next request", %{future: future} do
    {:ok, published} =
      Content.update_article(
        future,
        %{published_at: DateTime.add(DateTime.utc_now(), -60, :second)},
        authorize?: false
      )

    for path <- [
          "/blog/scheduled",
          "/blog",
          "/blog/feed.xml",
          "/blog/posts.json",
          "/sitemap.xml",
          "/llms.txt"
        ] do
      assert response(get(build_conn(), path), 200) =~ "scheduled"
    end

    assert get(build_conn(), "/blog/posts/scheduled.json")
           |> json_response(200)
           |> Map.get("slug") == "scheduled"

    {:ok, _} =
      Content.update_article(
        published,
        %{published_at: DateTime.add(DateTime.utc_now(), 86_400, :second)},
        authorize?: false
      )

    assert response(get(build_conn(), "/blog/scheduled"), 404) == "Not found"
    assert response(get(build_conn(), "/blog/posts/scheduled.json"), 404) == "Not found"

    for path <- ["/blog", "/blog/feed.xml", "/blog/posts.json", "/sitemap.xml", "/llms.txt"] do
      refute response(get(build_conn(), path), 200) =~ "/blog/scheduled"
    end
  end

  test "HTML and JSON remove unavailable relative, absolute, encoded and fragment links" do
    html = get(build_conn(), "/blog/visible") |> html_response(200)
    doc = LazyHTML.from_document(html)
    hrefs = doc |> LazyHTML.query("#blog-article a") |> LazyHTML.attribute("href")
    refute Enum.any?(hrefs, &String.contains?(&1, "scheduled"))
    refute "/blog/%73cheduled" in hrefs
    assert "/monitoring/uptime" in hrefs

    json = get(build_conn(), "/blog/posts/visible.json") |> json_response(200)
    assert json["internal_links"] == ["/monitoring/uptime"]
    assert json["url"] == "https://postdeploy.dev/blog/visible"
    refute json["body_html"] =~ ~s(href="/blog/scheduled)
    refute json["body_html"] =~ ~s(href="scheduled)
  end

  test "structured data matches the visible author, date and canonical identity", %{
    visible: visible
  } do
    doc = get(build_conn(), "/blog/visible") |> html_response(200) |> LazyHTML.from_document()
    assert doc |> LazyHTML.query("h1") |> LazyHTML.text() == "Title visible"
    assert doc |> LazyHTML.query("h1") |> Enum.count() == 1

    assert doc |> LazyHTML.query(~s(link[rel="canonical"])) |> LazyHTML.attribute("href") ==
             ["https://postdeploy.dev/blog/visible"]

    assert doc |> LazyHTML.query(~s(meta[property="og:type"])) |> LazyHTML.attribute("content") ==
             ["article"]

    schema =
      doc
      |> LazyHTML.query(~s(script[type="application/ld+json"]))
      |> LazyHTML.text()
      |> Jason.decode!()

    assert schema["@type"] == "BlogPosting"
    assert schema["author"]["@type"] == "Organization"
    assert schema["author"]["name"] == "PostDeploy"
    assert schema["mainEntityOfPage"]["@id"] == "https://postdeploy.dev/blog/visible"
    assert schema["datePublished"] == DateTime.to_iso8601(visible.published_at)

    assert schema["datePublished"] in (doc
                                       |> LazyHTML.query("time")
                                       |> LazyHTML.attribute("datetime"))
  end

  test "SEO inventory, audit and acquisition exclude future articles" do
    assert Inventory.entry("/blog/visible").primary_query == "fixture HTTP contract"
    assert Inventory.entry("/blog/scheduled") == nil
    assert "/blog/visible" in Audit.public_paths()
    refute "/blog/scheduled" in Audit.public_paths()
    assert Alplus.Growth.content_cluster("/blog/visible") == "uptime"
    assert Alplus.Growth.content_cluster("/blog/scheduled") == "other"
  end

  test "RSS escapes XML values", %{visible: visible} do
    {:ok, _} =
      Content.update_article(
        visible,
        %{title: "A & B < C", description: "D & E < F"},
        authorize?: false
      )

    rss = response(get(build_conn(), "/blog/feed.xml"), 200)
    assert rss =~ "<title>A &amp; B &lt; C</title>"
    assert rss =~ "<description>D &amp; E &lt; F</description>"
    assert rss =~ "<guid>https://postdeploy.dev/blog/visible</guid>"
  end

  test "raw Markdown is not a public asset" do
    assert response(get(build_conn(), "/priv/blog/http-health-check-contract.md"), 404)
    assert response(get(build_conn(), "/blog/http-health-check-contract.md"), 404) == "Not found"
  end

  defp create(slug, at) do
    Content.create_article(
      %{
        slug: slug,
        title: "Title #{slug}",
        description: "Description #{slug}",
        published_at: at,
        keywords: ["fixture HTTP contract"],
        cluster: "uptime",
        intent: "informational",
        internal_links: ["/blog/scheduled", "/monitoring/uptime"],
        sources: ["https://example.com/source"],
        body_html: ~s(<p>Body <a href="/blog/scheduled#details">relative</a>
        <a href="https://postdeploy.dev/blog/scheduled?x=1">absolute</a>
        <a href="scheduled">sibling</a><a href="/blog/%73cheduled">encoded</a>
        <a href="/monitoring/uptime">Uptime</a></p>)
      },
      authorize?: false
    )
  end
end
