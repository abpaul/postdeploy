defmodule Alplus.Seo.Audit do
  @moduledoc """
  Inspects the rendered HTML of every public route and reports SEO defects.

  This is the shared engine behind `mix alplus.seo.audit` and the test suite,
  so CI and a developer's terminal apply exactly one standard.

  It deliberately audits *rendered output* rather than the content rows
  behind it. A correct title in the database that never reaches `<head>`
  is still a broken page, and only rendering catches that.

  Findings carry a severity:

  * `:error` — breaks indexing or misrepresents the page. Fails CI.
  * `:warning` — worth fixing, does not fail CI.

  Add a check by writing a function that takes the parsed page list and
  returns findings, then listing it in `@checks`.
  """

  alias Alplus.Content
  alias Alplus.Content.PublishGate
  alias Alplus.Seo.Inventory
  alias AlplusWeb.Marketing.Seo

  @type finding :: %{
          severity: :error | :warning,
          path: String.t(),
          check: atom(),
          message: String.t()
        }

  @type page :: %{path: String.t(), status: pos_integer(), html: term()}

  # Google truncates well before these; they are outer bounds that catch
  # copy-paste accidents, not a style guide.
  @title_max_length 65
  @description_min_length 50
  @description_max_length 165
  @schema_context "https://schema.org"

  @checks [
    :titles_present_and_sized,
    :descriptions_present_and_sized,
    :titles_unique,
    :descriptions_unique,
    :canonical_present_and_absolute,
    :canonical_self_referencing,
    :canonical_unique,
    :single_h1,
    :robots_directives,
    :structured_data_valid,
    :internal_links_resolve,
    :no_orphan_pages,
    :images_have_alt_text,
    :has_main_landmark,
    :heading_order_is_sequential,
    :links_have_discernible_text,
    :html_declares_a_language,
    :multiple_navs_are_labelled,
    :no_query_cannibalisation,
    :social_preview_metadata_present,
    :urls_are_canonical,
    :guide_publish_gate
  ]
  @doc """
  Fetches and audits every public route.

  `fetch` is a one-argument function from path to `%{status: ..., body:
  ...}`, which lets the mix task use a real HTTP client and the test suite
  use `Phoenix.ConnTest` without a running server.
  """
  @spec run((String.t() -> %{status: pos_integer(), body: String.t()})) :: [finding()]
  def run(fetch) do
    paths = public_paths()

    pages =
      Enum.map(paths, fn path ->
        %{status: status, body: body} = fetch.(path)
        %{path: path, status: status, html: parse(body)}
      end)

    sitemap_response = fetch.("/sitemap.xml")
    status_findings = Enum.flat_map(pages, &check_status/1)

    # Only audit the content of pages that actually rendered; a 500 has
    # nothing meaningful to say about its title. Sitemap coverage still uses
    # every audited route, so a broken route cannot hide from discovery checks.
    ok_pages = Enum.filter(pages, &(&1.status == 200))

    Enum.reduce(@checks, status_findings, fn check, acc ->
      acc ++ apply(__MODULE__, check, [ok_pages])
    end) ++ sitemap_covers_public_routes(pages, sitemap_response)
  end

  @doc """
  Every public, indexable path PostDeploy serves, read from the content tables.

  The first-party changelog is not a content row, but its stable index is a
  public marketing page and belongs in the canonical audit.
  """
  @spec public_paths() :: [String.t()]
  def public_paths do
    {:ok, pages} = Content.list_pages()
    {:ok, guides} = Content.list_guides()
    {:ok, comparisons} = Content.list_comparisons()
    {:ok, articles} = Content.list_articles()

    (Enum.map(pages, & &1.path) ++
       Enum.map(guides, & &1.path) ++
       Enum.map(comparisons, & &1.path) ++
       Enum.map(articles, &"/blog/#{&1.slug}") ++
       ["/blog", "/changelog", "/tools/website-health-check"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp check_status(%{status: 200}), do: []

  defp check_status(%{path: path, status: status}) do
    [
      finding(
        :error,
        path,
        :page_responds,
        "expected HTTP 200 for a public route, got #{status}"
      )
    ]
  end

  # -- checks -----------------------------------------------------------

  @doc false
  def titles_present_and_sized(pages) do
    Enum.flat_map(pages, fn page ->
      case text_of(page, "title") do
        nil ->
          [finding(:error, page.path, :missing_title, "no <title>")]

        "" ->
          [finding(:error, page.path, :missing_title, "empty <title>")]

        title when byte_size(title) > @title_max_length ->
          [
            finding(
              :warning,
              page.path,
              :long_title,
              "title is #{byte_size(title)} chars, over #{@title_max_length}: #{title}"
            )
          ]

        _ ->
          []
      end
    end)
  end

  @doc false
  def descriptions_present_and_sized(pages) do
    Enum.flat_map(pages, fn page ->
      case attr_of(page, ~s(meta[name="description"]), "content") do
        nil ->
          [finding(:error, page.path, :missing_description, "no meta description")]

        description ->
          length = byte_size(description)

          cond do
            length < @description_min_length ->
              [
                finding(
                  :warning,
                  page.path,
                  :short_description,
                  "meta description is #{length} chars, under #{@description_min_length}"
                )
              ]

            length > @description_max_length ->
              [
                finding(
                  :warning,
                  page.path,
                  :long_description,
                  "meta description is #{length} chars, over #{@description_max_length}"
                )
              ]

            true ->
              []
          end
      end
    end)
  end

  @doc false
  def titles_unique(pages),
    do: duplicates(pages, &text_of(&1, "title"), :duplicate_title, "title")

  @doc false
  def descriptions_unique(pages) do
    duplicates(
      pages,
      &attr_of(&1, ~s(meta[name="description"]), "content"),
      :duplicate_description,
      "meta description"
    )
  end

  @doc false
  def canonical_present_and_absolute(pages) do
    Enum.flat_map(pages, fn page ->
      case canonical(page) do
        nil ->
          [finding(:error, page.path, :missing_canonical, "no rel=canonical")]

        url ->
          if String.starts_with?(url, Seo.origin() <> "/") or url == Seo.origin() do
            []
          else
            [
              finding(
                :error,
                page.path,
                :malformed_canonical,
                "canonical is not an absolute #{Seo.origin()} URL: #{url}"
              )
            ]
          end
      end
    end)
  end

  @doc false
  def canonical_self_referencing(pages) do
    Enum.flat_map(pages, fn page ->
      expected = Seo.origin() <> page.path

      case canonical(page) do
        nil ->
          []

        ^expected ->
          []

        other ->
          [
            finding(
              :error,
              page.path,
              :cross_canonical,
              "canonical points at #{other}, not its own URL #{expected}"
            )
          ]
      end
    end)
  end

  @doc false
  def canonical_unique(pages) do
    duplicates(pages, &canonical/1, :duplicate_canonical, "canonical URL")
  end

  @doc false
  def single_h1(pages) do
    Enum.flat_map(pages, fn page ->
      case count_of(page, "h1") do
        1 -> []
        0 -> [finding(:error, page.path, :missing_h1, "no <h1>")]
        n -> [finding(:error, page.path, :multiple_h1, "#{n} <h1> elements, expected 1")]
      end
    end)
  end

  @doc false
  def robots_directives(pages) do
    Enum.flat_map(pages, fn page ->
      directives =
        page.html
        |> LazyHTML.query("meta")
        |> Enum.filter(fn meta ->
          String.downcase(first_attribute(meta, "name") || "") in ["robots", "googlebot"]
        end)
        |> Enum.flat_map(fn meta ->
          (first_attribute(meta, "content") || "")
          |> String.downcase()
          |> String.split(~r/[\s,]+/, trim: true)
        end)

      if Enum.any?(directives, &(&1 in ["noindex", "none"])) do
        [
          finding(
            :error,
            page.path,
            :noindex_public_page,
            "stable public page has a noindex or none robots directive"
          )
        ]
      else
        []
      end
    end)
  end

  @doc false
  def structured_data_valid(pages) do
    {findings, entities} =
      Enum.reduce(pages, {[], []}, fn page, {findings, entities} ->
        {structural_findings, graphs, page_entities} =
          page
          |> all_text(~s(script[type="application/ld+json"]))
          |> Enum.reduce({[], [], []}, fn raw, {raw_findings, graphs, entities} ->
            case Jason.decode(String.trim(raw)) do
              {:ok, graph} ->
                {raw_findings ++ validate_graph(page.path, graph), [graph | graphs],
                 entities ++ entity_nodes(page.path, graph)}

              {:error, _} ->
                {raw_findings ++
                   [finding(:error, page.path, :invalid_json_ld, "JSON-LD is not valid JSON")],
                 graphs, entities}
            end
          end)

        page_findings =
          structural_findings ++ semantic_findings(page, Enum.reverse(graphs))

        {findings ++ page_findings, entities ++ page_entities}
      end)

    findings ++ conflicting_entity_findings(entities)
  end

  # Every graph needs the exact schema.org context. Nested @graph entries
  # inherit the outer context, but a context declared on a node must also be
  # exact. This is intentionally a small emitted-data check, not a validator.
  defp validate_graph(path, %{"@graph" => graphs} = graph) when is_list(graphs) do
    context_findings = validate_context(path, graph)

    if graphs == [] do
      context_findings ++
        [finding(:error, path, :invalid_json_ld, "@graph has no nodes")]
    else
      context_findings ++ Enum.flat_map(graphs, &validate_node(path, &1))
    end
  end

  defp validate_graph(path, %{"@graph" => _} = graph) do
    validate_context(path, graph) ++
      [finding(:error, path, :invalid_json_ld, "@graph is not a list of nodes")]
  end

  defp validate_graph(path, graph) when is_map(graph) do
    validate_context(path, graph) ++
      if Map.has_key?(graph, "@context") do
        validate_node(path, graph)
      else
        [finding(:error, path, :invalid_json_ld, "JSON-LD node without @context")]
      end
  end

  defp validate_graph(path, _) do
    [finding(:error, path, :invalid_json_ld, "JSON-LD is not an object")]
  end

  defp validate_context(_path, %{"@context" => context}) when context == @schema_context, do: []

  defp validate_context(path, %{"@context" => context}) do
    [
      finding(
        :error,
        path,
        :invalid_json_ld,
        "JSON-LD context must be #{@schema_context}, got #{inspect(context)}"
      )
    ]
  end

  defp validate_context(path, _),
    do: [finding(:error, path, :invalid_json_ld, "JSON-LD without @context")]

  defp validate_node(path, node) when is_map(node) do
    context_findings =
      if Map.has_key?(node, "@context"), do: validate_context(path, node), else: []

    type = Map.get(node, "@type")

    cond do
      map_size(node) == 0 ->
        context_findings ++ [finding(:error, path, :invalid_json_ld, "JSON-LD node is empty")]

      empty_schema_value?(type) ->
        context_findings ++ [finding(:error, path, :invalid_json_ld, "JSON-LD node has no type")]

      true ->
        context_findings
    end
  end

  defp validate_node(path, _) do
    [finding(:error, path, :invalid_json_ld, "JSON-LD node is not an object")]
  end

  defp empty_schema_value?(nil), do: true
  defp empty_schema_value?(""), do: true
  defp empty_schema_value?(value) when is_binary(value), do: String.trim(value) == ""

  defp empty_schema_value?(value) when is_list(value),
    do: value == [] or Enum.all?(value, &empty_schema_value?/1)

  defp empty_schema_value?(_), do: false

  defp semantic_findings(page, graph) do
    nodes = schema_nodes(graph)

    faq_findings(page, nodes) ++
      breadcrumb_findings(page, nodes) ++
      offer_findings(page, nodes) ++ article_findings(page, nodes)
  end

  defp schema_nodes(%{"@graph" => graphs}) when is_list(graphs),
    do: Enum.flat_map(graphs, &node_tree/1)

  defp schema_nodes(graph) when is_map(graph), do: node_tree(graph)
  defp schema_nodes(graphs) when is_list(graphs), do: Enum.flat_map(graphs, &schema_nodes/1)
  defp schema_nodes(_), do: []

  defp node_tree(node) when is_map(node) do
    [node | Enum.flat_map(Map.values(node), &node_tree/1)]
  end

  defp node_tree(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &node_tree/1)
  defp node_tree(_), do: []

  defp entity_nodes(path, graph) do
    graph
    |> schema_nodes()
    |> Enum.filter(fn node ->
      is_binary(Map.get(node, "@id")) and Map.get(node, "@id") != "" and
        not empty_schema_value?(Map.get(node, "@type"))
    end)
    |> Enum.map(&{path, &1})
  end

  defp conflicting_entity_findings(entities) do
    entities
    |> Enum.group_by(fn {_path, node} -> node["@id"] end)
    |> Enum.flat_map(fn {id, entries} ->
      properties =
        entries
        |> Enum.map(fn {_path, node} -> Map.drop(node, ["@id", "@context", "offers"]) end)
        |> Enum.uniq_by(&:erlang.term_to_binary/1)

      if length(properties) > 1 do
        Enum.map(entries, fn {path, _node} ->
          finding(
            :error,
            path,
            :conflicting_entity_properties,
            "JSON-LD entity #{id} has conflicting properties across audited pages"
          )
        end)
      else
        []
      end
    end)
  end

  defp faq_findings(page, nodes) do
    schema_faqs =
      nodes
      |> Enum.filter(&has_type?(&1, "FAQPage"))
      |> Enum.flat_map(fn node ->
        case Map.get(node, "mainEntity") do
          questions when is_list(questions) -> questions
          _ -> []
        end
      end)
      |> Enum.flat_map(fn question ->
        if is_map(question) do
          [
            {
              normalize_text(Map.get(question, "name")),
              normalize_text(get_in(question, ["acceptedAnswer", "text"]))
            }
          ]
        else
          []
        end
      end)

    visible_faqs = visible_faqs(page)

    cond do
      schema_faqs == [] ->
        []

      visible_faqs == [] ->
        [
          semantic_finding(
            page.path,
            :invisible_faq_schema,
            "FAQPage schema has no visible FAQ content"
          )
        ]

      schema_faqs == visible_faqs ->
        []

      true ->
        [
          semantic_finding(
            page.path,
            :faq_schema_not_visible,
            "FAQPage questions and answers do not match visible FAQ content"
          )
        ]
    end
  end

  defp breadcrumb_findings(page, nodes) do
    schema_items =
      nodes
      |> Enum.filter(&has_type?(&1, "BreadcrumbList"))
      |> Enum.flat_map(fn node ->
        case Map.get(node, "itemListElement") do
          items when is_list(items) -> items
          _ -> []
        end
      end)
      |> Enum.flat_map(fn item ->
        if is_map(item) do
          [{normalize_text(Map.get(item, "name")), normalize_url_path(Map.get(item, "item"))}]
        else
          []
        end
      end)

    visible_items = visible_breadcrumbs(page)

    cond do
      schema_items == [] ->
        []

      visible_items == [] ->
        [
          semantic_finding(
            page.path,
            :invisible_breadcrumb_schema,
            "BreadcrumbList schema has no visible breadcrumbs"
          )
        ]

      schema_items == visible_items ->
        []

      true ->
        [
          semantic_finding(
            page.path,
            :breadcrumb_schema_not_visible,
            "BreadcrumbList items do not match visible breadcrumbs"
          )
        ]
    end
  end

  defp offer_findings(page, nodes) do
    offers = Enum.filter(nodes, &has_type?(&1, "Offer"))
    cards = visible_offer_cards(page)

    cond do
      offers == [] and cards == [] ->
        []

      offers == [] ->
        [
          semantic_finding(
            page.path,
            :missing_offer_schema,
            "the visible package offer has no Offer schema"
          )
        ]

      true ->
        Enum.flat_map(offers, fn offer ->
          name = normalize_text(Map.get(offer, "name"))
          price = normalize_text(Map.get(offer, "price"))

          case Enum.find(cards, fn card ->
                 card_name = Regex.replace(~r/\s+(monthly|annual)$/i, name, "")
                 Regex.match?(~r/(?:^|\s)#{Regex.escape(card_name)}(?:\s|$)/i, card)
               end) do
            nil ->
              [
                semantic_finding(
                  page.path,
                  :offer_schema_not_visible,
                  "Offer #{if(name == "", do: "(unnamed)", else: name)} is not visible on the page"
                )
              ]

            card ->
              if name == "" or price == "" or not visible_price?(card, price) do
                [
                  semantic_finding(
                    page.path,
                    :offer_schema_not_visible,
                    "Offer #{if(name == "", do: "(unnamed)", else: name)} does not expose its price visibly"
                  )
                ]
              else
                []
              end
          end
        end)
    end
  end

  defp article_findings(page, nodes) do
    nodes
    |> Enum.filter(
      &(has_type?(&1, "Article") or has_type?(&1, "TechArticle") or has_type?(&1, "BlogPosting"))
    )
    |> Enum.flat_map(fn article ->
      visible = visible_document(page)
      author = get_in(article, ["author", "name"]) || Map.get(article, "author")
      dates = visible |> LazyHTML.query("time") |> Enum.map(&first_attribute(&1, "datetime"))

      []
      |> then_if(
        is_binary(author) and normalize_text(author) != "" and
          not String.contains?(normalize_text(LazyHTML.text(visible)), normalize_text(author)),
        semantic_finding(page.path, :article_schema_not_visible, "article author is not visible")
      )
      |> then_if(
        is_binary(Map.get(article, "datePublished")) and
          Map.get(article, "datePublished") not in dates,
        semantic_finding(
          page.path,
          :article_schema_not_visible,
          "article publication date is not visible"
        )
      )
      |> then_if(
        is_binary(Map.get(article, "dateModified")) and
          Map.get(article, "dateModified") not in dates,
        semantic_finding(
          page.path,
          :article_schema_not_visible,
          "article modified date is not visible"
        )
      )
    end)
  end

  defp then_if(findings, true, finding), do: findings ++ [finding]
  defp then_if(findings, false, _finding), do: findings

  defp semantic_finding(path, check, message), do: finding(:error, path, check, message)

  defp has_type?(node, type) do
    case Map.get(node, "@type") do
      ^type -> true
      types when is_list(types) -> type in types
      _ -> false
    end
  end

  defp visible_faqs(page) do
    page
    |> visible_document()
    |> LazyHTML.query("[id]")
    |> Enum.filter(fn element ->
      id = String.downcase(first_attribute(element, "id") || "")
      String.contains?(id, "faq")
    end)
    |> Enum.flat_map(fn section ->
      questions = section |> LazyHTML.query("h3") |> Enum.map(&normalize_text(LazyHTML.text(&1)))
      answers = section |> LazyHTML.query("p") |> Enum.map(&normalize_text(LazyHTML.text(&1)))
      Enum.zip(questions, answers)
    end)
  end

  defp visible_breadcrumbs(page) do
    page
    |> visible_document()
    |> LazyHTML.query("nav")
    |> Enum.filter(fn nav ->
      String.downcase(first_attribute(nav, "aria-label") || "") == "breadcrumb"
    end)
    |> Enum.flat_map(fn nav ->
      links =
        nav
        |> LazyHTML.query("a")
        |> Enum.map(fn link ->
          {normalize_text(LazyHTML.text(link)), normalize_url_path(first_attribute(link, "href"))}
        end)

      current =
        nav
        |> LazyHTML.query(~s([aria-current="page"]))
        |> Enum.map(fn element ->
          {normalize_text(LazyHTML.text(element)), page.path}
        end)

      links ++ current
    end)
  end

  defp visible_offer_cards(page) do
    page
    |> visible_document()
    |> LazyHTML.query("[id]")
    |> Enum.filter(fn element ->
      first_attribute(element, "id") == "package-offer"
    end)
    |> Enum.map(&normalize_text(LazyHTML.text(&1)))
  end

  defp visible_price?(card, price) do
    normalized = String.replace(price, ",", "")
    Regex.match?(~r/\$\s*#{Regex.escape(normalized)}(?:\.0+)?(?:\D|$)/, card)
  end

  defp visible_document(page) do
    page.html
    |> LazyHTML.to_html()
    |> then(&Regex.replace(~r/<script\b[^>]*>.*?<\/script>/is, &1, ""))
    |> then(&Regex.replace(~r/<style\b[^>]*>.*?<\/style>/is, &1, ""))
    |> LazyHTML.from_document()
  end

  defp normalize_text(nil), do: ""

  defp normalize_text(value),
    do: value |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp normalize_url_path(nil), do: nil

  defp normalize_url_path(url) do
    case URI.parse(to_string(url)) do
      %URI{scheme: scheme, host: host, port: port, path: path}
      when is_binary(scheme) and is_binary(host) ->
        origin_uri = URI.parse(Seo.origin())

        if scheme == origin_uri.scheme and host == origin_uri.host and port == origin_uri.port do
          canonical_path(path)
        else
          nil
        end

      %URI{path: path} ->
        canonical_path(path)
    end
  end

  defp canonical_path(nil), do: "/"
  defp canonical_path("/"), do: "/"
  defp canonical_path(path), do: String.trim_trailing(path, "/")

  @doc false
  def internal_links_resolve(pages) do
    known = MapSet.new(public_paths() ++ non_content_paths())

    Enum.flat_map(pages, fn page ->
      page
      |> internal_hrefs()
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.uniq()
      |> Enum.map(fn href ->
        finding(:error, page.path, :broken_internal_link, "links to unknown path #{href}")
      end)
    end)
  end

  @doc false
  def no_orphan_pages(pages) do
    linked =
      pages
      |> Enum.flat_map(&internal_hrefs/1)
      |> MapSet.new()

    pages
    |> Enum.map(& &1.path)
    # The homepage is reachable by definition and needs no inbound link.
    |> Enum.reject(&(&1 == "/" or MapSet.member?(linked, &1)))
    |> Enum.map(fn path ->
      finding(:error, path, :orphan_page, "no other public page links to it")
    end)
  end

  @doc false
  def sitemap_covers_public_routes(pages, sitemap_response \\ nil)

  def sitemap_covers_public_routes(_pages, nil) do
    [
      finding(
        :error,
        "/sitemap.xml",
        :sitemap_unavailable,
        "the SEO audit did not receive the real sitemap.xml response"
      )
    ]
  end

  def sitemap_covers_public_routes(_pages, %{status: status}) when status != 200 do
    [
      finding(
        :error,
        "/sitemap.xml",
        :sitemap_unavailable,
        "expected HTTP 200 for sitemap.xml, got #{status}"
      )
    ]
  end

  def sitemap_covers_public_routes(pages, %{status: 200, body: body}) do
    expected = pages |> Enum.map(& &1.path) |> MapSet.new()
    locs = sitemap_locs(body)

    {same_origin, wrong_origin} =
      Enum.split_with(locs, fn loc ->
        match?({:ok, _path, _canonical?}, normalize_sitemap_loc(loc))
      end)

    wrong_origin_findings =
      Enum.map(wrong_origin, fn loc ->
        finding(
          :error,
          "/sitemap.xml",
          :wrong_origin_sitemap_url,
          "sitemap loc is not on #{Seo.origin()}: #{loc}"
        )
      end)

    normalized =
      same_origin
      |> Enum.map(&normalize_sitemap_loc/1)
      |> Enum.map(fn {:ok, path, canonical?} -> {path, canonical?} end)

    noncanonical_findings =
      normalized
      |> Enum.reject(fn {_path, canonical?} -> canonical? end)
      |> Enum.map(fn {path, _} ->
        finding(:error, path, :non_canonical_sitemap_url, "sitemap loc is not a canonical URL")
      end)

    sitemap_paths = MapSet.new(normalized, fn {path, _} -> path end)

    missing_findings =
      expected
      |> MapSet.difference(sitemap_paths)
      |> Enum.map(fn path ->
        finding(:error, path, :missing_from_sitemap, "public page is not in sitemap.xml")
      end)

    extra_findings =
      sitemap_paths
      |> MapSet.difference(expected)
      |> Enum.reject(&dynamic_sitemap_path?/1)
      |> Enum.map(fn path ->
        finding(
          :error,
          path,
          :extra_sitemap_url,
          "sitemap.xml lists a URL outside the audited public routes"
        )
      end)

    wrong_origin_findings ++ noncanonical_findings ++ missing_findings ++ extra_findings
  end

  # Published first-party changelog entries are data-backed routes rather than
  # stable inventory rows. SitemapController enumerates them from the same
  # published-entry query used by their public controller.
  defp dynamic_sitemap_path?("/changelog/" <> slug),
    do: slug != "" and not String.contains?(slug, "/")

  defp dynamic_sitemap_path?(_path), do: false

  defp sitemap_locs(body) when is_binary(body) do
    Regex.scan(~r/<loc\b[^>]*>(.*?)<\/loc>/is, body, capture: :all_but_first)
    |> Enum.map(fn [loc] -> loc |> xml_unescape() |> String.trim() end)
    |> Enum.reject(&(&1 == ""))
  end

  defp sitemap_locs(_), do: []

  defp normalize_sitemap_loc(loc) do
    case URI.parse(loc) do
      %URI{scheme: scheme, host: host, port: port, path: path, query: query, fragment: fragment}
      when is_binary(scheme) and is_binary(host) ->
        origin_uri = URI.parse(Seo.origin())

        if scheme == origin_uri.scheme and host == origin_uri.host and port == origin_uri.port do
          canonical = canonical_path(path)

          {:ok, canonical,
           (is_nil(path) or path == canonical) and is_nil(query) and is_nil(fragment)}
        else
          {:wrong_origin, loc}
        end

      _ ->
        {:wrong_origin, loc}
    end
  end

  defp xml_unescape(value) do
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
  end

  @doc false
  def images_have_alt_text(pages) do
    Enum.flat_map(pages, fn page ->
      page
      |> attrs_of("img", "alt")
      |> Enum.count(&is_nil/1)
      |> case do
        0 ->
          []

        n ->
          [finding(:error, page.path, :missing_alt_text, "#{n} <img> without an alt attribute")]
      end
    end)
  end

  @doc false
  def social_preview_metadata_present(pages) do
    # A shared page with no image renders as a bare text card, which is the
    # difference between a link someone clicks and one they scroll past.
    # Every tag here must be an absolute URL: social crawlers do not resolve
    # relative paths.
    required = [
      {~s(meta[property="og:title"]), "content", :missing_og_title},
      {~s(meta[property="og:image"]), "content", :missing_og_image},
      {~s(meta[name="twitter:card"]), "content", :missing_twitter_card}
    ]

    Enum.flat_map(pages, fn page ->
      missing =
        Enum.flat_map(required, fn {selector, attribute, check} ->
          case attr_of(page, selector, attribute) do
            nil -> [finding(:error, page.path, check, "no #{selector}")]
            "" -> [finding(:error, page.path, check, "empty #{selector}")]
            _ -> []
          end
        end)

      image = attr_of(page, ~s(meta[property="og:image"]), "content")

      absolute =
        if is_binary(image) and not String.starts_with?(image, "http") do
          [
            finding(
              :error,
              page.path,
              :relative_og_image,
              "og:image is #{image}, which social crawlers will not resolve; use an absolute URL"
            )
          ]
        else
          []
        end

      missing ++ absolute
    end)
  end

  @doc false
  def urls_are_canonical(pages) do
    # Every published path must already be its own canonical form, and every
    # internal link must point at one. A link to a variant costs a redirect
    # hop on the way to the page it meant.
    page_findings =
      pages
      |> Enum.map(& &1.path)
      |> Enum.reject(&(AlplusWeb.Plugs.CanonicalPath.canonical_path(&1) == &1))
      |> Enum.map(fn path ->
        finding(
          :error,
          path,
          :non_canonical_path,
          "published at a non-canonical URL; it should be #{AlplusWeb.Plugs.CanonicalPath.canonical_path(path)}"
        )
      end)

    link_findings =
      pages
      # A page whose body could not be parsed has no links to inspect.
      |> Enum.reject(&is_nil(&1.html))
      |> Enum.flat_map(fn page ->
        page
        |> raw_internal_hrefs()
        |> Enum.filter(&(&1 != "/" and String.ends_with?(&1, "/")))
        |> Enum.uniq()
        |> Enum.map(fn href ->
          finding(
            :warning,
            page.path,
            :link_to_url_variant,
            "links to #{href}, which redirects; link to the canonical URL directly"
          )
        end)
      end)

    page_findings ++ link_findings
  end

  # -- content inventory and intent (PRD §39, §40) ----------------------
  #
  # `pages_are_in_the_inventory` and `inventory_has_no_dead_entries` used to
  # live here. Both are now tautological: `Alplus.Seo.Inventory` reads
  # `cluster`/`intent`/`primary_query` straight off each content row instead
  # of a separate literal, and those attributes are `allow_nil? false`, so a
  # row cannot exist without them and the inventory cannot list a row that
  # does not exist. The one check with a real failure mode,
  # `no_query_cannibalisation`, stays.

  @doc false
  def no_query_cannibalisation(_pages) do
    Enum.flat_map(Inventory.cannibalised_queries(), fn {query, paths} ->
      Enum.map(paths, fn path ->
        others = paths |> List.delete(path) |> Enum.join(", ")

        finding(
          :error,
          path,
          :query_cannibalisation,
          "claims the same primary query as #{others} (#{query}); merge them or re-point one"
        )
      end)
    end)
  end

  # SITE-ARCHITECTURE.md §8 publish gate for reserved programmatic sets
  # (`/guides/{platform}-heartbeat`). `PublishGate.report/1` needs the
  # `Guide` rows themselves, not the rendered `pages` this function ignores:
  # `not_offered`, `docs_host` and `code_verified_on` are data the template
  # renders selectively, not something safe to reparse out of HTML.
  @doc false
  def guide_publish_gate(_pages) do
    {:ok, guides} = Content.list_guides(authorize?: false)
    PublishGate.report(guides)
  end

  # -- accessibility checks ---------------------------------------------
  #
  # These are the WCAG 2.2 A/AA failures that are reliably detectable from
  # static HTML. They do not replace a manual pass: contrast, focus order
  # and screen-reader behaviour need a real browser and a person. They do
  # catch the regressions that silently ship in a template edit.

  @doc false
  def has_main_landmark(pages) do
    Enum.flat_map(pages, fn page ->
      case count_of(page, "main") do
        1 ->
          []

        0 ->
          [
            finding(
              :error,
              page.path,
              :missing_main_landmark,
              "no <main> element, so skipping to content is impossible"
            )
          ]

        n ->
          [
            finding(
              :error,
              page.path,
              :multiple_main_landmarks,
              "#{n} <main> elements, expected 1"
            )
          ]
      end
    end)
  end

  @doc false
  def heading_order_is_sequential(pages) do
    Enum.flat_map(pages, fn page ->
      levels = heading_levels(page)

      levels
      |> Enum.zip(Enum.drop(levels, 1))
      |> Enum.filter(fn {previous, next} -> next - previous > 1 end)
      |> Enum.map(fn {previous, next} ->
        finding(
          :warning,
          page.path,
          :skipped_heading_level,
          "heading jumps from h#{previous} to h#{next}, which breaks document outline navigation"
        )
      end)
    end)
  end

  @doc false
  def links_have_discernible_text(pages) do
    Enum.flat_map(pages, fn page ->
      page.html
      |> LazyHTML.query("a")
      |> Enum.filter(&link_without_text?/1)
      |> Enum.count()
      |> case do
        0 ->
          []

        n ->
          [
            finding(
              :error,
              page.path,
              :link_without_text,
              "#{n} link(s) with no text, aria-label or titled image"
            )
          ]
      end
    end)
  end

  @doc false
  def html_declares_a_language(pages) do
    Enum.flat_map(pages, fn page ->
      case attr_of(page, "html", "lang") do
        nil ->
          [
            finding(
              :error,
              page.path,
              :missing_lang,
              "<html> has no lang attribute, so screen readers guess pronunciation"
            )
          ]

        _ ->
          []
      end
    end)
  end

  @doc false
  def multiple_navs_are_labelled(pages) do
    Enum.flat_map(pages, fn page ->
      # `aria-hidden` navs are removed from the accessibility tree entirely,
      # so they never appear in a landmark list and need no label. The
      # decorative console mockup on the homepage is one of these.
      navs =
        page.html
        |> LazyHTML.query("nav")
        |> Enum.reject(&(first_attribute(&1, "aria-hidden") == "true"))

      # One nav needs no label. Two or more are ambiguous in a landmark
      # list unless each says what it is.
      if Enum.count(navs) > 1 do
        unlabelled =
          Enum.count(navs, fn nav ->
            is_nil(first_attribute(nav, "aria-label")) and
              is_nil(first_attribute(nav, "aria-labelledby"))
          end)

        if unlabelled > 0 do
          [
            finding(
              :error,
              page.path,
              :unlabelled_nav,
              "#{unlabelled} of #{Enum.count(navs)} <nav> elements have no aria-label"
            )
          ]
        else
          []
        end
      else
        []
      end
    end)
  end

  # Every heading level on the page, in document order.
  #
  # LazyHTML has no "any heading" selector, and querying h1..h6 separately
  # would return them grouped by level, in which case a skip could never be
  # detected. So the levels are recovered from the serialized HTML, which
  # preserves document order.
  defp heading_levels(page) do
    ~r/<h([1-6])[\s>]/
    |> Regex.scan(LazyHTML.to_html(page.html))
    |> Enum.map(fn [_, level] -> String.to_integer(level) end)
  end

  # A link is discernible when it has text, an aria-label, or an image with
  # alt text. An icon-only link with none of those announces as "link".
  defp link_without_text?(link) do
    text = link |> LazyHTML.text() |> String.trim()

    image_alt =
      link
      |> LazyHTML.query("img")
      |> Enum.map(&first_attribute(&1, "alt"))
      |> Enum.reject(&(is_nil(&1) or &1 == ""))

    text == "" and
      is_nil(first_attribute(link, "aria-label")) and
      is_nil(first_attribute(link, "title")) and
      image_alt == []
  end

  defp first_attribute(element, attribute) do
    element |> LazyHTML.attribute(attribute) |> List.first()
  end

  # Public routes that are not content rows, so an internal link to one is
  # legitimate rather than broken. `/dashboard` is the authenticated console
  # entry point: marketing CTAs link to it, and it redirects to sign-in when
  # signed out, so it resolves for a visitor even though it never indexes.
  defp non_content_paths do
    [
      "/",
      "/dashboard",
      "/register",
      "/sign-in",
      "/reset",
      "/sitemap.xml",
      "/llms.txt",
      "/robots.txt",
      "/product-facts.json",
      "/pricing.md",
      "/blog/feed.xml",
      "/blog/posts.json",
      # Changelog feeds are link targets rather than standalone content pages.
      # The stable `/changelog` index has a declared inventory entry.
      "/changelog.rss",
      "/changelog.json"
      # Dynamic /share/:token, /invitations/:token and /status/:slug routes
      # stay out of public_paths/0: the audit cannot invent tenant tokens or
      # choose a representative tenant slug. Their SEO contracts are covered
      # by controller and LiveView tests.
    ]
  end

  # -- HTML helpers -----------------------------------------------------

  # Reports every page that shares a non-nil value with another page. Two
  # pages with the same title compete for the same query, and two pages with
  # the same canonical means one of them is telling Google it does not exist.
  defp duplicates(pages, extractor, check, label) do
    pages
    |> Enum.map(&{&1.path, extractor.(&1)})
    |> Enum.reject(fn {_path, value} -> is_nil(value) end)
    |> Enum.group_by(fn {_path, value} -> value end, fn {path, _value} -> path end)
    |> Enum.filter(fn {_value, paths} -> length(paths) > 1 end)
    |> Enum.flat_map(fn {value, paths} ->
      Enum.map(paths, fn path ->
        others = paths |> List.delete(path) |> Enum.join(", ")

        finding(
          :error,
          path,
          check,
          "shares its #{label} with #{others}: #{value}"
        )
      end)
    end)
  end

  defp parse(body), do: LazyHTML.from_document(body)

  defp text_of(page, selector) do
    case page.html |> LazyHTML.query(selector) |> LazyHTML.text() do
      "" -> nil
      text -> String.trim(text)
    end
  end

  defp all_text(page, selector) do
    page.html
    |> LazyHTML.query(selector)
    |> Enum.map(&LazyHTML.text/1)
  end

  defp attr_of(page, selector, attribute) do
    page
    |> attrs_of(selector, attribute)
    |> List.first()
  end

  # One entry per matching element, `nil` when that element lacks the
  # attribute, so callers can distinguish "no such element" (empty list)
  # from "element without the attribute" (a nil entry). `missing_alt_text`
  # depends on that difference.
  defp attrs_of(page, selector, attribute) do
    page.html
    |> LazyHTML.query(selector)
    |> Enum.map(fn element ->
      element |> LazyHTML.attribute(attribute) |> List.first()
    end)
  end

  defp count_of(page, selector) do
    page.html |> LazyHTML.query(selector) |> Enum.count()
  end

  defp canonical(page), do: attr_of(page, ~s(link[rel="canonical"]), "href")

  # Site-internal hrefs only, normalized to a bare path: absolute URLs on our
  # own origin count as internal, and fragments/queries are stripped so a
  # link to "/pricing#plans" resolves to "/pricing".
  defp internal_hrefs(page) do
    page
    |> raw_internal_hrefs()
    |> Enum.map(fn
      "/" -> "/"
      href -> String.trim_trailing(href, "/")
    end)
    |> Enum.reject(&(&1 == ""))
  end

  # The same links with their trailing slash intact, so `urls_are_canonical`
  # can see a link to a URL variant that `internal_hrefs/1` would normalize
  # away.
  defp raw_internal_hrefs(page) do
    page
    |> attrs_of("a", "href")
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.replace_prefix(&1, Seo.origin(), ""))
    |> Enum.filter(&String.starts_with?(&1, "/"))
    |> Enum.map(fn href ->
      href |> String.split(["#", "?"]) |> hd()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp finding(severity, path, check, message) do
    %{severity: severity, path: path, check: check, message: message}
  end

  @doc "Formats findings for a terminal, grouped by path."
  @spec format([finding()]) :: String.t()
  def format([]), do: "No SEO findings. #{length(public_paths())} public routes audited.\n"

  def format(findings) do
    errors = Enum.count(findings, &(&1.severity == :error))
    warnings = length(findings) - errors

    body =
      findings
      |> Enum.group_by(& &1.path)
      |> Enum.sort_by(fn {path, _} -> path end)
      |> Enum.map_join("\n", fn {path, page_findings} ->
        lines =
          Enum.map_join(page_findings, "\n", fn f ->
            "  #{severity_label(f.severity)} #{f.check}: #{f.message}"
          end)

        "#{path}\n#{lines}"
      end)

    "#{body}\n\n#{errors} error(s), #{warnings} warning(s) across #{length(public_paths())} public routes.\n"
  end

  defp severity_label(:error), do: "ERROR  "
  defp severity_label(:warning), do: "WARNING"
end
