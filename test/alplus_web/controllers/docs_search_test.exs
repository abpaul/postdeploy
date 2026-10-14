defmodule AlplusWeb.DocsSearchTest do
  use AlplusWeb.ConnCase, async: true

  alias Alplus.Content

  setup do
    :ok = Content.Seeds.run()

    {:ok, _guide} =
      Content.create_guide(
        %{
          slug: "docs-search-body-test",
          path: "/docs/search-body-test",
          title: "Search body fixture",
          meta_description: "Search body fixture.",
          nav_label: "Search body fixture",
          summary: "A fixture for search ranking.",
          hero_heading: "Search body fixture",
          hero_description: "A fixture for search ranking.",
          body_sections: [%{"body" => ["Unique body phrase for search"]}],
          lastmod: ~D[2026-09-15],
          cluster: "docs",
          intent: "informational",
          primary_query: "search body fixture"
        },
        authorize?: false
      )

    {:ok, _draft} =
      Content.create_guide(
        %{
          slug: "docs-search-draft-test",
          path: "/docs/search-draft-test",
          title: "Unique unpublished search fixture",
          meta_description: "Unique unpublished search fixture.",
          summary: "Unique unpublished search fixture.",
          hero_heading: "Unique unpublished search fixture",
          hero_description: "Unique unpublished search fixture.",
          lastmod: ~D[2026-09-15],
          status: "draft",
          cluster: "docs",
          intent: "informational",
          primary_query: "unpublished search fixture"
        },
        authorize?: false
      )

    :ok
  end

  test "searches published docs and guides by body text", %{conn: conn} do
    html = conn |> get("/docs/search?q=unique+body+phrase") |> html_response(200)

    assert html =~ ~s(href="/docs/search-body-test")
    refute html =~ ~s(href="/docs/search-draft-test")
  end

  test "returns both docs and guides for a shared topic", %{conn: conn} do
    html = conn |> get("/docs/search?q=heartbeat") |> html_response(200)

    assert html =~ ~s(href="/docs/monitoring/heartbeats")
    assert html =~ ~s(href="/guides/airflow-heartbeat")
  end

  test "a published section without a heading still renders its body", %{conn: conn} do
    html = conn |> get("/docs/search-body-test") |> html_response(200)

    assert html =~ "Unique body phrase for search"
    assert html =~ ~s(id="section-1")
  end

  test "search query is bounded before rendering", %{conn: conn} do
    query = String.duplicate("x", 200)

    document =
      conn
      |> get("/docs/search?q=#{query}")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert document
           |> LazyHTML.query("#resource-search-query")
           |> LazyHTML.attribute("value") == [String.duplicate("x", 120)]
  end
end
