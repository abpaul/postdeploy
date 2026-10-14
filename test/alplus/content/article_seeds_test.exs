defmodule Alplus.Content.ArticleSeedsTest do
  use ExUnit.Case, async: true

  alias Alplus.Content.ArticleSeeds

  test "rejects missing and timezone-free publication timestamps" do
    assert_raise ArgumentError, ~r/missing published_at/, fn ->
      ArticleSeeds.parse_file(write_source("title: x\ndescription: y\nslug: x\n"))
    end

    assert_raise ArgumentError, ~r/UTC timezone/, fn ->
      ArticleSeeds.parse_file(
        write_source(
          "title: x\ndescription: y\nslug: x\npublished_at: \"2026-10-12T09:00:00\"\nkeywords: [x]\ncluster: uptime\nintent: informational\ninternal_links: []\nsources: [https://example.com]\n"
        )
      )
    end
  end

  test "rejects invalid slug and unknown cluster" do
    source =
      "title: x\ndescription: y\nslug: Not Safe\npublished_at: \"2026-10-12T09:00:00Z\"\nkeywords: [x]\ncluster: uptime\nintent: informational\ninternal_links: []\nsources: [https://example.com]\n"

    assert_raise ArgumentError, ~r/invalid slug/, fn ->
      ArticleSeeds.parse_file(write_source(source))
    end
  end

  test "sanitizes unsafe Markdown HTML" do
    source =
      "title: x\ndescription: y\nslug: x\npublished_at: \"2026-10-12T09:00:00Z\"\nkeywords: [x]\ncluster: uptime\nintent: informational\ninternal_links: []\nsources: [https://example.com]\n"

    article = ArticleSeeds.parse_file(write_source(source, "[bad](javascript:alert(1))"))
    refute article.body_html =~ "javascript:"
  end

  test "rejects an empty backlog and duplicate slugs before importing" do
    assert_raise ArgumentError, ~r/no Markdown sources/, fn -> ArticleSeeds.load_files([]) end
    yaml = valid_yaml()
    first = write_source(yaml)
    second = write_source(yaml)

    assert_raise ArgumentError, ~r/duplicate article slug/, fn ->
      ArticleSeeds.load_files([first, second])
    end
  end

  test "rejects missing citations, empty keywords and unsafe internal URLs" do
    for {from, to} <- [
          {"sources: [https://example.com]", "sources: []"},
          {"keywords: [x]", "keywords: []"},
          {"internal_links: []", "internal_links: [//example.com/path]"}
        ] do
      assert_raise ArgumentError, fn ->
        valid_yaml() |> String.replace(from, to) |> write_source() |> ArticleSeeds.parse_file()
      end
    end
  end

  test "renders Markdown tables and preserves useful code" do
    body = "| Status | Meaning |\n| --- | --- |\n| 503 | Unavailable |\n\n~~~sh\nprintf ok\n~~~"
    article = ArticleSeeds.parse_file(write_source(valid_yaml(), body))
    doc = LazyHTML.from_fragment(article.body_html)
    assert doc |> LazyHTML.query("table td") |> LazyHTML.text() == "503Unavailable"
    assert doc |> LazyHTML.query("pre code") |> LazyHTML.text() == "printf ok\n"
  end

  test "rejects blank bodies and metadata exceeding resource limits" do
    for body <- ["", " \n\t", "<!-- empty -->"] do
      assert_raise ArgumentError, ~r/empty Markdown body/, fn ->
        ArticleSeeds.parse_file(write_source(valid_yaml(), body))
      end
    end

    for {field, limit} <- [{"title", 300}, {"description", 500}, {"slug", 120}] do
      yaml =
        String.replace(
          valid_yaml(),
          "#{field}: #{if field == "description", do: "y", else: "x"}",
          "#{field}: #{String.duplicate("x", limit + 1)}"
        )

      assert_raise ArgumentError, fn -> ArticleSeeds.parse_file(write_source(yaml)) end
    end
  end

  defp valid_yaml do
    "title: x\ndescription: y\nslug: x\npublished_at: \"2099-10-12T09:00:00Z\"\nkeywords: [x]\ncluster: uptime\nintent: informational\ninternal_links: []\nsources: [https://example.com]\n"
  end

  defp write_source(yaml, body \\ "Body") do
    path = Path.join(System.tmp_dir!(), "article-#{System.unique_integer([:positive])}.md")
    on_exit(fn -> File.rm(path) end)
    File.write!(path, "---\n#{yaml}---\n#{body}")
    path
  end
end
