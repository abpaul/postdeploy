defmodule AlplusWeb.Marketing.Seo do
  @moduledoc """
  Assigns the meta/OG/canonical/JSON-LD conn assigns that
  `AlplusWeb.Layouts.root/1` renders (ARCHITECTURE.md §9). One call site
  per marketing controller action keeps `<head>` plumbing out of every
  template.

  `json_ld` graphs are always PostDeploy-authored content (seeded/admin content,
  never end-user input), so `root.html.heex` is allowed to embed them with
  `raw/1` — see the iron law on `raw/1` in AGENTS.md, which is about
  untrusted content specifically.
  """

  import Plug.Conn

  @origin "https://postdeploy.dev"

  @product_description "Uptime checks, cron heartbeats, error tracking and cookieless analytics " <>
                         "in one project, for solo developers and small teams who run their own " <>
                         "production software."

  # One static social preview for every page. Per-page generated images need
  # a rendering service and a cache, which is heavy infrastructure for a link
  # preview, and a wrong-but-specific image is worse than a correct generic
  # one. Source and build script: `priv/static/images/og-default.svg` and
  # `scripts/build-og-image.sh`.
  @og_image "/images/og-default.png"

  @doc "The canonical site origin, no trailing slash."
  def origin, do: @origin

  @doc "The absolute URL of the default social preview image."
  def og_image_url, do: @origin <> @og_image

  @doc """
  Sets every SEO assign used by the root layout.

  * `:path` — canonical path, no trailing slash (`"/"` for the homepage).
  * `:og_title` / `:og_description` — default to `title` / `description`.
  * `:noindex` — emits `<meta name="robots" content="noindex">`.
  * `:json_ld` — a list of structured-data graphs, each JSON-encoded into
    its own `<script type="application/ld+json">`.
  """
  def assign_seo(conn, opts) do
    opts
    # Every page routed through here is a server-rendered marketing page with
    # no phx-* bindings, so the root layout skips the LiveView bundle. Set
    # here rather than per-controller: a new marketing page gets the benefit
    # by construction instead of by someone remembering.
    |> seo_assigns()
    |> Map.put(:static_page, true)
    |> Enum.reduce(conn, fn {key, value}, conn -> assign(conn, key, value) end)
  end

  @doc """
  The same SEO assigns as a plain map, for a caller that has no `conn`.

  `AlplusWeb.HomeLive` assigns this map to its socket. LiveView merges the
  socket assigns into the root layout's assigns on the first, socketless
  render, so `<head>` comes out identical to a controller page's.

  `:static_page` is deliberately not in here. It is the root layout's
  "skip the LiveView bundle" marker, and the homepage needs the bundle.
  `:marketing_page` identifies the SEO surface. `:measure_self_tracking`
  independently controls PostDeploy's first-party tracker.
  """
  def seo_assigns(opts) do
    title = Keyword.fetch!(opts, :title)
    description = Keyword.fetch!(opts, :description)
    path = Keyword.fetch!(opts, :path)

    %{
      page_title: title,
      meta_description: description,
      canonical_url: @origin <> path,
      og_title: Keyword.get(opts, :og_title, title),
      og_description: Keyword.get(opts, :og_description, description),
      og_type: Keyword.get(opts, :og_type, "website"),
      article_published_time: Keyword.get(opts, :article_published_time),
      robots: if(Keyword.get(opts, :noindex, false), do: "noindex"),
      json_ld: Keyword.get(opts, :json_ld, []),
      marketing_page: true,
      measure_self_tracking: Keyword.get(opts, :measure_self_tracking, true)
    }
  end

  def blog_posting_schema(article) do
    %{
      "@context" => "https://schema.org",
      "@type" => "BlogPosting",
      "headline" => article.title,
      "description" => article.description,
      "url" => @origin <> "/blog/" <> article.slug,
      "mainEntityOfPage" => %{"@type" => "WebPage", "@id" => @origin <> "/blog/" <> article.slug},
      "publisher" => organization_schema(),
      "author" => organization_schema(),
      "keywords" => Enum.join(article.keywords, ", "),
      "datePublished" => DateTime.to_iso8601(article.published_at),
      "image" => og_image_url()
    }
  end

  @doc """
  A `TechArticle` graph for an authored guide.

  Emitted only when the guide has an author, because `Article` types require
  authorship and inventing one to satisfy a schema is exactly the deceptive
  markup Google's structured-data policies prohibit.

  Every field mirrors something visible on the page (the byline, the dates,
  the heading), which is Google's stated requirement for structured data.
  """
  def tech_article_schema(path, guide) do
    %{
      "@context" => "https://schema.org",
      "@type" => "TechArticle",
      "headline" => guide.hero_heading || guide.title,
      "description" => guide.meta_description,
      "url" => @origin <> path,
      "mainEntityOfPage" => %{"@type" => "WebPage", "@id" => @origin <> path},
      "author" => %{"@type" => "Person", "name" => guide.author_name},
      "publisher" => %{"@id" => "#{@origin}/#organization"},
      "image" => og_image_url()
    }
    |> maybe_put("datePublished", guide.published_on)
    |> maybe_put("dateModified", guide.last_verified_on || guide.lastmod)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, %Date{} = date), do: Map.put(map, key, Date.to_iso8601(date))

  @doc "Encodes a JSON-LD graph safely for inline `<script>` embedding (escapes `</`)."
  def encode_json_ld!(graph) do
    graph |> Jason.encode!() |> String.replace("</", "<\\/")
  end

  @doc "A `BreadcrumbList` graph from `[{name, path_or_nil}]`; the last entry is the current page."
  def breadcrumb_schema(items) do
    %{
      "@context" => "https://schema.org",
      "@type" => "BreadcrumbList",
      "itemListElement" =>
        items
        |> Enum.with_index(1)
        |> Enum.map(fn {{name, path}, position} ->
          %{
            "@type" => "ListItem",
            "position" => position,
            "name" => name,
            "item" => @origin <> path
          }
        end)
    }
  end

  @doc "A `FAQPage` graph from a list of `%{\"q\" => ..., \"a\" => ...}` maps."
  def faq_schema(faqs) do
    %{
      "@context" => "https://schema.org",
      "@type" => "FAQPage",
      "mainEntity" =>
        Enum.map(faqs, fn f ->
          %{
            "@type" => "Question",
            "name" => Map.fetch!(f, "q"),
            "acceptedAnswer" => %{
              "@type" => "Answer",
              "text" => plain_inline_text(Map.fetch!(f, "a"))
            }
          }
        end)
    }
  end

  # FAQ copy supports backticks for visible inline code. Structured data needs
  # the same words as plain text rather than Markdown delimiters.
  defp plain_inline_text(text), do: String.replace(text, "`", "")

  @doc """
  The site-wide `Organization` node, reused on every page that emits a graph.

  A node, not a document: it has no `@context`, so it is valid nested inside a
  `@graph` that supplies one. The organization has no social profile claim:
  PostDeploy does not maintain a company profile that can corroborate it.
  """
  def organization_schema do
    %{
      "@type" => "Organization",
      "@id" => "#{@origin}/#organization",
      "name" => "PostDeploy",
      "url" => "#{@origin}/",
      "description" => @product_description
    }
  end

  @doc """
  The site-wide `WebSite` node for the homepage graph.

  A node, not a document: its graph supplies the schema.org `@context`. Its
  publisher points to the canonical `Organization` node.
  """
  def website_schema do
    %{
      "@type" => "WebSite",
      "@id" => "#{@origin}/#website",
      "name" => "PostDeploy",
      "url" => "#{@origin}/",
      "publisher" => %{"@id" => "#{@origin}/#organization"}
    }
  end

  @doc """
  A `SoftwareApplication` node for the PostDeploy product.

  The product URL is always the canonical site root. Pass offers only for the
  pricing graph, where the visible package card provides the matching user-facing
  evidence; omit them from every other page.
  """
  def software_application_schema(offers \\ nil) do
    %{
      "@type" => "SoftwareApplication",
      "@id" => "#{@origin}/#software",
      "name" => "PostDeploy",
      "description" => @product_description,
      "applicationCategory" => "DeveloperApplication",
      "operatingSystem" => "Web",
      "url" => "#{@origin}/"
    }
    |> maybe_put_present("offers", offers)
  end

  defp maybe_put_present(map, _key, nil), do: map
  defp maybe_put_present(map, key, value), do: Map.put(map, key, value)
end
