defmodule AlplusWeb.PageController do
  @moduledoc """
  The public marketing site (ARCHITECTURE.md §9, BUILD.md Phase 4):
  server-rendered controllers and templates. The homepage is the one
  exception and lives in `AlplusWeb.HomeLive`, so its overview switches
  change one frame in place; every page here stays a controller page. Every
  page reads content through `Alplus.Content`'s code interface, never
  `Alplus.Repo` directly, and pricing numbers come from
  `Alplus.Billing.Package`, never a literal in a template.

  A missing slug (`/alternatives/:slug`) raises `AlplusWeb.NotFoundError`,
  which renders a plain 404 rather than a 403 or a 500 — content is public,
  so there is no tenant to leak, but the same "unknown id looks like a
  missing id" shape (ARCHITECTURE.md §4) keeps this controller consistent
  with the rest of the app.

  Every `Content.get_*` call here is total, never a hard `{:ok, _} =`
  match: a fresh database migrated without `priv/repo/seeds.exs`
  (`Alplus.Content.Seeds.run/0`) must never 500 a visitor. `AlplusWeb.HomeLive`
  goes one step further and prefers a minimal built-in fallback over a 404 —
  the front page should render something on a freshly set-up instance, not
  send every first visitor to a not-found page.
  """

  use AlplusWeb, :controller

  alias Alplus.Content
  alias AlplusWeb.Marketing.{PackagePresenter, Seo}

  def pricing(conn, _params) do
    case Content.get_page_by_path("/pricing") do
      {:ok, page} -> render_pricing(conn, page)
      {:error, _} -> raise AlplusWeb.NotFoundError
    end
  end

  defp render_pricing(conn, page) do
    # These are graph nodes rather than standalone documents. Keep one stable
    # site and product identity across the homepage and pricing page; pricing
    # adds offers because their prices are visible here.
    offer_schema = %{
      "@context" => "https://schema.org",
      "@graph" => [
        Seo.organization_schema(),
        Seo.website_schema(),
        Seo.software_application_schema(PackagePresenter.offers())
      ]
    }

    conn
    |> Seo.assign_seo(
      title: page.title,
      description: page.meta_description,
      path: "/pricing",
      og_title: page.og_title,
      og_description: page.og_description,
      json_ld: [
        offer_schema,
        Seo.faq_schema(page.faqs),
        Seo.breadcrumb_schema([{"Home", "/"}, {"Pricing", "/pricing"}])
      ]
    )
    |> assign(:page, page)
    |> render(:pricing)
  end

  def free_uptime_monitoring(conn, _params), do: render_guide(conn, "/free-uptime-monitoring")
  def free_cron_job_monitoring(conn, _params), do: render_guide(conn, "/free-cron-job-monitoring")

  def monitoring_hub(conn, _params), do: render_guide(conn, "/monitoring")

  def error_tracking_hub(conn, _params), do: render_guide(conn, "/error-tracking")

  def analytics_hub(conn, _params), do: render_guide(conn, "/analytics")

  def privacy(conn, _params), do: render_guide(conn, "/privacy")
  def about(conn, _params), do: render_guide(conn, "/about")
  def terms(conn, _params), do: render_guide(conn, "/terms")

  # `/monitoring/:slug` and `/guides/:slug` render `Content.Guide` rows by
  # path. An unknown slug raises `NotFoundError` through `render_guide/2`,
  # so a typo 404s rather than rendering an empty shell.
  def monitoring_page(conn, %{"slug" => slug}), do: render_guide(conn, "/monitoring/#{slug}")

  def guide(conn, %{"slug" => slug}), do: render_guide(conn, "/guides/#{slug}")

  defp render_guide(conn, path) do
    case Content.get_guide_by_path(path) do
      {:ok, guide} -> render_guide(conn, path, guide)
      {:error, _} -> raise AlplusWeb.NotFoundError
    end
  end

  defp render_guide(conn, path, guide) do
    breadcrumbs = guide_breadcrumbs(path, guide)

    conn
    |> Seo.assign_seo(
      title: guide.title,
      description: guide.meta_description,
      path: path,
      json_ld:
        [
          Seo.faq_schema(guide.faqs),
          Seo.breadcrumb_schema(breadcrumbs)
        ] ++ article_schema(path, guide)
    )
    |> assign(:guide, guide)
    |> assign(:breadcrumbs, breadcrumbs)
    |> render_guide_template(path)
  end

  defp render_guide_template(conn, "/guides/" <> _) do
    {docs, guides} = search_navigation()

    conn
    |> assign(:docs, docs)
    |> assign(:guides, guides)
    |> render(:resource_guide)
  end

  defp render_guide_template(conn, _path), do: render(conn, :guide)

  # Only authored editorial content gets an Article type. A commercial page
  # has no byline, and inventing one to satisfy a schema is the deceptive
  # markup Google's structured-data policies prohibit.
  defp article_schema(path, %{author_name: author} = guide) when is_binary(author) do
    [Seo.tech_article_schema(path, guide)]
  end

  defp article_schema(_path, _guide), do: []

  # Breadcrumbs mirror the URL hierarchy, so a page inside a cluster shows
  # its parent. Structured data has to match what a reader can see and
  # click, and every intermediate path here is a real, rendered page.
  defp guide_breadcrumbs("/monitoring/" <> _ = path, guide) do
    [{"Home", "/"}, {"Monitoring", "/monitoring"}, {guide.nav_label, path}]
  end

  defp guide_breadcrumbs("/guides/" <> _ = path, guide) do
    [{"Home", "/"}, {"Guides", "/guides"}, {guide.nav_label, path}]
  end

  defp guide_breadcrumbs(path, guide), do: [{"Home", "/"}, {guide.nav_label, path}]

  def guides_index(conn, _params) do
    case Content.get_page_by_path("/guides") do
      {:ok, page} -> render_guides_index(conn, page)
      {:error, _} -> raise AlplusWeb.NotFoundError
    end
  end

  defp render_guides_index(conn, page) do
    {:ok, guides} = Content.list_guides()

    guides =
      guides
      |> Enum.filter(&String.starts_with?(&1.path, "/guides/"))
      |> Enum.sort_by(& &1.path)

    displayed_guides =
      guides
      |> AlplusWeb.PageHTML.guide_groups()
      |> Enum.flat_map(& &1.guides)

    list_schema = %{
      "@context" => "https://schema.org",
      "@type" => "ItemList",
      "itemListElement" =>
        displayed_guides
        |> Enum.with_index(1)
        |> Enum.map(fn {g, i} ->
          %{
            "@type" => "ListItem",
            "position" => i,
            "name" => g.hero_heading,
            "url" => Seo.origin() <> g.path
          }
        end)
    }

    conn
    |> Seo.assign_seo(
      title: page.title,
      description: page.meta_description,
      path: "/guides",
      json_ld: [
        Seo.breadcrumb_schema([{"Home", "/"}, {"Guides", "/guides"}]),
        list_schema
      ]
    )
    |> assign(:page, page)
    |> assign(:docs, list_docs())
    |> assign(:guides, guides)
    |> render(:guides_index)
  end

  # -- Help Center (`/docs`) ----------------------------------------------
  #
  # The hub is a `Content.Page`; every leaf is a `Content.Guide` row whose
  # path starts with `/docs/`. Grouping and ordering are presentation, so
  # they live in `AlplusWeb.PageHTML.docs_categories/1`.

  def docs_index(conn, _params) do
    case Content.get_page_by_path("/docs") do
      {:ok, page} -> render_docs_index(conn, page)
      {:error, _} -> raise AlplusWeb.NotFoundError
    end
  end

  defp render_docs_index(conn, page) do
    docs = list_docs()

    conn
    |> Seo.assign_seo(
      title: page.title,
      description: page.meta_description,
      path: "/docs",
      json_ld: [Seo.breadcrumb_schema([{"Home", "/"}, {"Docs", "/docs"}])]
    )
    |> assign(:page, page)
    |> assign(:docs, docs)
    |> assign(:guides, list_guides())
    |> render(:docs_index)
  end

  def search(conn, %{"q" => query}) do
    query = normalize_search_query(query)
    {docs, guides} = search_navigation()

    conn
    |> Seo.assign_seo(
      title: "Search PostDeploy Docs",
      description: "Search PostDeploy documentation and guides.",
      path: "/docs/search",
      noindex: true
    )
    |> assign(:query, query)
    |> assign(:results, search_results(query, docs ++ guides))
    |> assign(:docs, docs)
    |> assign(:guides, guides)
    |> render(:search)
  end

  def search(conn, _params), do: search(conn, %{"q" => ""})

  def doc(conn, params) do
    path = Enum.join(["/docs", params["section"] | List.wrap(params["topic"])], "/")

    case Content.get_guide_by_path(path) do
      {:ok, doc} -> render_doc(conn, path, doc)
      {:error, _} -> raise AlplusWeb.NotFoundError
    end
  end

  defp render_doc(conn, path, doc) do
    docs = list_docs()
    breadcrumbs = doc_breadcrumbs(path, doc, docs)

    conn
    |> Seo.assign_seo(
      title: doc.title,
      description: doc.meta_description,
      path: path,
      json_ld: [Seo.breadcrumb_schema(breadcrumbs)] ++ article_schema(path, doc)
    )
    |> assign(:guide, doc)
    |> assign(:docs, docs)
    |> assign(:guides, list_guides())
    |> assign(:breadcrumbs, breadcrumbs)
    |> render(:doc)
  end

  defp list_docs do
    {:ok, guides} = Content.list_guides()
    Enum.filter(guides, &String.starts_with?(&1.path, "/docs/"))
  end

  defp list_guides do
    {:ok, guides} = Content.list_guides()
    Enum.filter(guides, &String.starts_with?(&1.path, "/guides/"))
  end

  defp search_navigation, do: {list_docs(), list_guides()}

  @search_query_limit 120
  @search_result_limit 50

  defp normalize_search_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.slice(0, @search_query_limit)
  end

  defp normalize_search_query(_query), do: ""

  defp search_results("", _guides), do: []

  defp search_results(query, guides) do
    terms = String.split(String.downcase(query), ~r/\s+/, trim: true)

    guides
    |> Enum.map(&rank_search_result(&1, terms))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn result -> {-result.score, result.path} end)
    |> Enum.take(@search_result_limit)
  end

  defp rank_search_result(guide, terms) do
    fields = %{
      title:
        [guide.title, guide.hero_heading, guide.nav_label]
        |> Enum.map_join(" ", &(&1 || ""))
        |> String.downcase(),
      summary: String.downcase(guide.summary || ""),
      body: String.downcase(search_body_text(guide.body_sections))
    }

    if Enum.all?(terms, fn term ->
         Enum.any?(fields, fn {_field, value} -> String.contains?(value, term) end)
       end) do
      score =
        Enum.reduce(terms, 0, fn term, total ->
          total + field_score(fields.title, term, 100) +
            field_score(fields.summary, term, 40) + field_score(fields.body, term, 10)
        end)

      %{
        title: guide.hero_heading,
        summary: guide.summary,
        path: guide.path,
        kind: if(String.starts_with?(guide.path, "/docs/"), do: :docs, else: :guides),
        score: score
      }
    end
  end

  defp field_score(value, term, weight) do
    if String.contains?(value, term), do: weight, else: 0
  end

  defp search_body_text(value) when is_list(value),
    do: Enum.map_join(value, " ", &search_body_text/1)

  defp search_body_text(value) when is_map(value),
    do: Map.values(value) |> Enum.map_join(" ", &search_body_text/1)

  defp search_body_text(value) when is_binary(value), do: value
  defp search_body_text(_value), do: ""

  # Home, Docs, the section page when this is a topic inside one, then the
  # page. The section entry appears only when that page is published, so
  # every crumb a reader sees resolves.
  defp doc_breadcrumbs(path, doc, docs) do
    section =
      case String.split(path, "/", trim: true) do
        ["docs", section, _topic] -> Enum.find(docs, &(&1.path == "/docs/#{section}"))
        _ -> nil
      end

    [{"Home", "/"}, {"Docs", "/docs"}] ++
      if(section, do: [{section.nav_label, section.path}], else: []) ++
      [{doc.nav_label, path}]
  end

  def alternatives_index(conn, _params) do
    case Content.get_page_by_path("/alternatives") do
      {:ok, page} -> render_alternatives_index(conn, page)
      {:error, _} -> raise AlplusWeb.NotFoundError
    end
  end

  defp render_alternatives_index(conn, page) do
    {:ok, comparisons} = Content.list_comparisons()

    list_schema = %{
      "@context" => "https://schema.org",
      "@type" => "ItemList",
      "itemListElement" =>
        comparisons
        |> Enum.sort_by(& &1.competitor_name)
        |> Enum.with_index(1)
        |> Enum.map(fn {c, i} ->
          %{
            "@type" => "ListItem",
            "position" => i,
            "name" => "PostDeploy as a #{c.competitor_name} alternative",
            "url" => Seo.origin() <> c.path
          }
        end)
    }

    conn
    |> Seo.assign_seo(
      title: page.title,
      description: page.meta_description,
      path: "/alternatives",
      json_ld: [
        Seo.breadcrumb_schema([{"Home", "/"}, {"Alternatives", "/alternatives"}]),
        Seo.faq_schema(page.faqs),
        list_schema
      ]
    )
    |> assign(:page, page)
    |> assign(:comparisons, Enum.sort_by(comparisons, & &1.competitor_name))
    |> render(:alternatives_index)
  end

  def alternatives_show(conn, %{"slug" => slug}) do
    case Content.get_comparison_by_slug(slug) do
      {:ok, comparison} ->
        {:ok, others} = Content.list_comparisons()

        others =
          others
          |> Enum.reject(&(&1.slug == comparison.slug))
          |> Enum.sort_by(& &1.competitor_name)

        conn
        |> Seo.assign_seo(
          title: comparison.title,
          description: comparison.meta_description,
          path: comparison.path,
          json_ld: [
            Seo.faq_schema(comparison.faqs),
            Seo.breadcrumb_schema([
              {"Home", "/"},
              {"Alternatives", "/alternatives"},
              {comparison.nav_label || comparison.competitor_name, comparison.path}
            ])
          ]
        )
        |> assign(:comparison, comparison)
        |> assign(:others, others)
        |> render(:alternatives_show)

      {:error, _} ->
        raise AlplusWeb.NotFoundError
    end
  end
end
