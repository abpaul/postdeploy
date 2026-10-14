defmodule Alplus.Changelog.Markdown do
  @moduledoc """
  Render stored Markdown as sanitized HTML.

  Every `h2` in the rendered body carries a stable `id`, so a reader can link
  to a section of an update and land on it (DESIGN.md, changelog entry
  recipe). The id is derived from the heading's own words, which keeps the
  same heading at the same address across re-renders, and is applied here
  rather than in the template: the sanitizer has already run at this point, so
  the tag being rewritten is known to carry no author attributes and the id
  value is built from a closed character set.
  """

  # Sanitized `h2` open tags, with their content. Sanitization keeps no
  # author-supplied `id` on a heading, so a heading either has no attributes
  # or carries `lang`/`title`, both of which are preserved untouched.
  @heading ~r{<h2(?<attributes>[^>]*)>(?<content>.*?)</h2>}s
  @entity ~r{&[a-zA-Z][a-zA-Z0-9]*;|&#[0-9]+;|&#x[0-9a-fA-F]+;}
  @tag ~r{<[^>]*>}
  @separator ~r/[^\p{L}\p{N}]+/u

  @spec render(String.t()) :: String.t()
  def render(markdown) when is_binary(markdown) do
    source =
      case Alplus.Changelog.FrontMatter.parse_public(markdown) do
        {:ok, %{body: body}} -> body
        {:error, _reason} -> markdown
      end

    MDEx.to_html!(source,
      render: [unsafe: true],
      sanitize: MDEx.Document.default_sanitize_options()
    )
    |> anchor_headings()
  end

  defp anchor_headings(html) do
    @heading
    |> Regex.split(html, include_captures: true)
    |> Enum.map_reduce(MapSet.new(), &anchor_heading/2)
    |> elem(0)
    |> IO.iodata_to_binary()
  end

  defp anchor_heading(part, taken) do
    case Regex.run(@heading, part, capture: :all_but_first) do
      [attributes, content] ->
        {id, taken} = unique_id(heading_slug(content), taken)
        {["<h2 id=\"", id, "\"", attributes, ">", content, "</h2>"], taken}

      nil ->
        {part, taken}
    end
  end

  # Two headings can legitimately resolve to the same id. Track every emitted
  # id, not only each base slug, so "Foo", "Foo", "Foo 2" remains unique.
  defp unique_id(slug, taken) do
    id = if MapSet.member?(taken, slug), do: available_id(slug, 2, taken), else: slug
    {id, MapSet.put(taken, id)}
  end

  defp available_id(slug, ordinal, taken) do
    candidate = "#{slug}-#{ordinal}"

    if MapSet.member?(taken, candidate),
      do: available_id(slug, ordinal + 1, taken),
      else: candidate
  end

  # The `section-` prefix keeps a heading's id out of the page's own id
  # namespace, so authored content can never clobber an element the template
  # owns.
  defp heading_slug(content) do
    slug =
      content
      |> String.replace(@tag, " ")
      |> String.replace(@entity, " ")
      |> String.downcase()
      |> String.replace(@separator, "-")
      |> String.trim("-")

    if slug == "", do: "section", else: "section-" <> slug
  end
end
