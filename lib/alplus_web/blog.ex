defmodule AlplusWeb.Blog do
  @moduledoc "Shared public Article projections for HTML, feeds, and discovery."

  alias Alplus.Content
  alias AlplusWeb.Marketing.Seo

  def list(now \\ DateTime.utc_now()) do
    with {:ok, articles} <- Content.list_articles() do
      articles =
        articles
        |> Enum.filter(&(DateTime.compare(&1.published_at, now) != :gt))
        |> Enum.sort_by(&{DateTime.to_unix(&1.published_at, :microsecond), &1.slug}, :desc)

      {:ok, articles}
    end
  end

  def get_by_slug(slug, now \\ DateTime.utc_now()) do
    with {:ok, article} <- Content.get_article_by_slug(slug),
         true <- DateTime.compare(article.published_at, now) != :gt do
      {:ok, article}
    else
      false -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  def project(article, articles) do
    published = MapSet.new(articles, &"/blog/#{&1.slug}")

    html =
      Regex.replace(~r{<a\b([^>]*)>(.*?)</a>}s, article.body_html, fn whole, attrs, label ->
        case Regex.run(~r{\bhref="([^"]*)"}, attrs, capture: :all_but_first) do
          [href] -> if public_link?(href, published, article.slug), do: whole, else: label
          _ -> whole
        end
      end)

    %{
      article
      | body_html: html,
        internal_links:
          Enum.filter(article.internal_links, &public_link?(&1, published, article.slug))
    }
  end

  defp public_link?(href, published, slug) do
    uri = URI.merge(Seo.origin() <> "/blog/" <> slug, href)
    origin = URI.parse(Seo.origin())

    if uri.host in [nil, origin.host] do
      path = (uri.path || "/") |> URI.decode() |> String.trim_trailing("/")

      case path do
        "/blog/" <> _ ->
          path in ["/blog/feed.xml", "/blog/posts.json"] or MapSet.member?(published, path)

        _ ->
          true
      end
    else
      true
    end
  end
end
