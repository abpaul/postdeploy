defmodule AlplusWeb.DocsTest do
  @moduledoc """
  The Help Center at `/docs` (issue #168). `Alplus.Seo.AuditTest` already
  applies the shared SEO standard (canonical, sitemap coverage, orphan
  pages, one h1) to every docs row, because docs are `Content.Guide` rows.
  These tests cover what is specific to the docs family: the hub is read
  from the content store, a topic sits under its section in the trail, and
  an unpublished section never produces a dead link.
  """

  use AlplusWeb.ConnCase, async: true

  alias Alplus.Content

  setup do
    :ok = Content.Seeds.run()
    :ok
  end

  defp published_docs do
    {:ok, guides} = Content.list_guides()
    Enum.filter(guides, &String.starts_with?(&1.path, "/docs/"))
  end

  test "the hub links every published docs page", %{conn: conn} do
    document = conn |> get(~p"/docs") |> html_response(200) |> LazyHTML.from_document()

    hrefs =
      document
      |> LazyHTML.query("#docs-article a")
      |> Enum.flat_map(&LazyHTML.attribute(&1, "href"))
      |> MapSet.new()

    docs = published_docs()
    assert length(docs) >= 11

    for doc <- docs do
      assert MapSet.member?(hrefs, doc.path), "#{doc.path} is not linked from /docs"
    end
  end

  test "a new docs row appears on the hub with no template change", %{conn: conn} do
    {:ok, _} =
      Content.create_guide(
        %{
          slug: "docs-observe-test-runtime",
          path: "/docs/observe/test-runtime",
          title: "Capture errors from Test Runtime | PostDeploy Docs",
          meta_description: "Install and verify the Test Runtime integration for PostDeploy.",
          nav_label: "Test Runtime",
          summary: "Test Runtime setup.",
          hero_heading: "Capture errors from Test Runtime",
          hero_description: "Install the package and send one error.",
          lastmod: ~D[2026-09-15],
          cluster: "docs",
          intent: "informational",
          primary_query: "test runtime error tracking setup"
        },
        authorize?: false
      )

    html = conn |> get(~p"/docs") |> html_response(200)

    assert html =~ ~s(href="/docs/observe/test-runtime")
    assert html =~ "Test Runtime"
  end

  test "a topic trail runs Home, Docs, its section, then the page", %{conn: conn} do
    {:ok, section} = Content.get_guide_by_path("/docs/observe")
    {:ok, topic} = Content.get_guide_by_path("/docs/observe/javascript")

    document =
      conn
      |> get(~p"/docs/observe/javascript")
      |> html_response(200)
      |> LazyHTML.from_document()

    trail = LazyHTML.query(document, "#doc-breadcrumbs")

    assert trail
           |> LazyHTML.query("a")
           |> Enum.map(&{String.trim(LazyHTML.text(&1)), hd(LazyHTML.attribute(&1, "href"))}) ==
             [{"Home", "/"}, {"Docs", "/docs"}, {section.nav_label, "/docs/observe"}]

    assert trail |> LazyHTML.query("[aria-current='page']") |> LazyHTML.text() ==
             topic.nav_label

    breadcrumb_graph =
      document
      |> LazyHTML.query("script[type='application/ld+json']")
      |> Enum.map(&(&1 |> LazyHTML.text() |> Jason.decode!()))
      |> Enum.find(&(&1["@type"] == "BreadcrumbList"))

    assert Enum.map(breadcrumb_graph["itemListElement"], & &1["item"]) == [
             "https://postdeploy.dev/",
             "https://postdeploy.dev/docs",
             "https://postdeploy.dev/docs/observe",
             "https://postdeploy.dev/docs/observe/javascript"
           ]
  end

  test "every section heading is reachable from the inline contents", %{conn: conn} do
    {:ok, doc} = Content.get_guide_by_path("/docs/monitoring/heartbeats")

    document =
      conn
      |> get(~p"/docs/monitoring/heartbeats")
      |> html_response(200)
      |> LazyHTML.from_document()

    targets =
      document
      |> LazyHTML.query(~s(#doc-article nav[aria-label="On this page"] a))
      |> Enum.map(&(&1 |> LazyHTML.attribute("href") |> hd() |> String.trim_leading("#")))

    assert length(targets) >= length(doc.body_sections)

    for target <- targets do
      assert document |> LazyHTML.query("##{target}") |> Enum.count() == 1,
             "contents link ##{target} has no matching section"
    end
  end

  test "an unknown docs path is a 404", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, "/docs/observe/cobol") end
    assert_error_sent 404, fn -> get(conn, "/docs/nothing-here") end
  end

  test "a category whose own page is unpublished is left off the hub" do
    docs = [
      %{path: "/docs/observe", nav_label: "Observe"},
      %{path: "/docs/observe/javascript", nav_label: "JavaScript"},
      %{path: "/docs/mcp/changelog", nav_label: "Changelog through MCP"}
    ]

    categories = AlplusWeb.PageHTML.docs_categories(docs)

    assert Enum.map(categories, & &1.key) == ["observe"]
    assert [%{topics: [%{path: "/docs/observe/javascript"}]}] = categories
  end

  test "the primary Help link opens the docs and stays current inside them", %{conn: conn} do
    assert {"Help", "/docs"} in AlplusWeb.MarketingComponents.header_links()

    document =
      conn
      |> get(~p"/docs/observe/ruby")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert document
           |> LazyHTML.query("#marketing-nav a[aria-current='page']")
           |> Enum.flat_map(&LazyHTML.attribute(&1, "href")) == ["/docs"]
  end

  describe "inline links in content" do
    import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
    import Phoenix.Component, only: [sigil_H: 2]

    test "site paths become links and anything else stays text" do
      assigns = %{
        text:
          "Read [heartbeats](/docs/monitoring/heartbeats), not [this](https://evil.example), [here](//134744072) or [that](javascript:alert(1))."
      }

      html =
        rendered_to_string(~H"""
        <AlplusWeb.MarketingComponents.rich_text text={@text} />
        """)

      document = LazyHTML.from_fragment(html)
      links = LazyHTML.query(document, "a")

      assert Enum.flat_map(links, &LazyHTML.attribute(&1, "href")) == [
               "/docs/monitoring/heartbeats"
             ]

      assert LazyHTML.text(document) =~ "[this](https://evil.example)"
    end
  end
end
