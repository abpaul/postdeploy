defmodule Alplus.Changelog.MarkdownTest do
  use ExUnit.Case, async: true

  alias Alplus.Changelog.Markdown

  test "renders markdown while sanitizing unsafe HTML and links" do
    html =
      Markdown.render("""
      # Update

      <script>alert('x')</script>
      <a href="javascript:alert('x')" onclick="alert('x')">unsafe</a>
      """)

    document = LazyHTML.from_fragment(html)
    link = LazyHTML.query(document, "a")

    assert document |> LazyHTML.query("h1") |> LazyHTML.text() == "Update"
    assert LazyHTML.text(link) == "unsafe"
    assert document |> LazyHTML.query("script") |> LazyHTML.to_html() == ""
    refute {"onclick", "alert('x')"} in List.flatten(LazyHTML.attributes(link))

    refute Enum.any?(List.flatten(LazyHTML.attributes(link)), fn
             {"href", "javascript:" <> _rest} -> true
             _attribute -> false
           end)
  end

  test "keeps inline and fenced code" do
    html = Markdown.render("Use `mix test`.\n\n```elixir\nIO.puts(\"ok\")\n```")

    document = LazyHTML.from_fragment(html)

    assert document |> LazyHTML.query("p code") |> LazyHTML.text() == "mix test"

    fenced_code = LazyHTML.query(document, "pre code.language-elixir")
    assert LazyHTML.text(fenced_code) =~ "IO.puts(\"ok\")"
  end

  test "gives colliding heading slugs unique stable ids" do
    html = Markdown.render("## Foo\n\n## Foo\n\n## Foo 2")
    headings = html |> LazyHTML.from_fragment() |> LazyHTML.query("h2")

    assert LazyHTML.attribute(headings, "id") == [
             "section-foo",
             "section-foo-2",
             "section-foo-2-2"
           ]
  end
end
