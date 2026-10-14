defmodule AlplusWeb.PageHTML do
  @moduledoc """
  Templates for the public marketing site (`AlplusWeb.PageController`).

  See the `page_html` directory for all templates available.
  """
  use AlplusWeb, :html

  import AlplusWeb.MarketingComponents

  embed_templates "page_html/*"

  # A product page carries one example agent session in its body sections.
  # It opens the page beside the title; every other section reads in order
  # below it.
  defp split_transcript(sections) do
    case Enum.split_while(sections, &(!&1["transcript"])) do
      {before, [transcript | rest]} -> {transcript["transcript"], before ++ rest}
      {all, []} -> {nil, all}
    end
  end

  # Comparison categories are registered once. The index groups only
  # categories with content, counts the rows it actually receives, and keeps
  # an unknown registered category visible instead of silently dropping it.
  @comparison_categories [
    %{
      key: "monitor",
      pillar: "Monitor",
      heading: "Uptime and cron tools",
      blurb_template:
        "Each of these tools watches one part of your project and bills for it separately. PostDeploy covers uptime and cron, then adds error tracking and analytics in the same package.",
      slugs: ~w(cronitor uptimerobot healthchecks-io better-stack)
    },
    %{
      key: "measure",
      pillar: "Measure",
      heading: "Analytics tools",
      blurb_template:
        "These tools count visitors and stop there. PostDeploy counts them without cookies and also tells you when the site is down or throwing errors.",
      slugs: ~w(plausible fathom google-analytics)
    }
  ]

  @doc "Returns the registered pillar label for a comparison path or record."
  def comparison_pillar(%{category: category}) when is_binary(category),
    do: category_spec(category).pillar

  def comparison_pillar(%{path: path}), do: comparison_pillar(path)

  def comparison_pillar(path) when is_binary(path) do
    path
    |> comparison_category()
    |> category_spec()
    |> Map.fetch!(:pillar)
  end

  # The alternatives index is data-driven: new rows are grouped by their
  # registered category, and unregistered categories remain visible with a
  # truthful row count until a richer category description is added.
  def comparison_families(comparisons) do
    comparisons
    |> Enum.group_by(&comparison_category/1)
    |> Enum.map(fn {category, items} ->
      spec = category_spec(category)
      count = length(items)

      %{
        category: category,
        pillar: spec.pillar,
        heading: spec.heading,
        blurb: family_blurb(spec.blurb_template, count),
        items: items
      }
    end)
    |> Enum.sort_by(&category_order(&1.category))
  end

  @doc """
  Other comparisons ordered for a reader already on one: same category
  first (a Cronitor evaluator is shopping for cron monitoring, not
  analytics), then the rest, alphabetical within each group.
  """
  def related_comparisons(comparison, others) do
    category = comparison_category(comparison)

    Enum.sort_by(others, fn other ->
      {if(comparison_category(other) == category, do: 0, else: 1), other.competitor_name}
    end)
  end

  defp comparison_category(%{category: category}) when is_binary(category),
    do: normalize_category(category)

  defp comparison_category(%{slug: slug}) when is_binary(slug),
    do: comparison_category_for_slug(slug)

  defp comparison_category(%{path: path}) when is_binary(path),
    do: comparison_category(path)

  defp comparison_category(path) when is_binary(path), do: comparison_category_for_path(path)

  defp comparison_category_for_slug(slug) do
    Enum.find_value(@comparison_categories, "monitor", fn category ->
      if slug in category.slugs, do: category.key
    end)
  end

  defp comparison_category_for_path("/alternatives/" <> slug),
    do: comparison_category_for_slug(slug)

  defp comparison_category_for_path(_path), do: "monitor"

  defp category_spec(category) do
    normalized = normalize_category(category)

    Enum.find(@comparison_categories, &(&1.key == normalized)) ||
      %{
        key: normalized,
        pillar: category_title(normalized),
        heading: "#{category_title(normalized)} comparisons",
        blurb_template:
          "%{count} %{label} are registered in this category and compared against the PostDeploy package.",
        slugs: []
      }
  end

  defp family_blurb(template, count) do
    template
    |> String.replace("%{count}", Integer.to_string(count))
    |> String.replace("%{label}", if(count == 1, do: "comparison", else: "comparisons"))
  end

  defp category_order(category) do
    Enum.find_index(@comparison_categories, &(&1.key == category)) ||
      length(@comparison_categories)
  end

  defp normalize_category(category) do
    category
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "other"
      value -> value
    end
  end

  defp category_title(category) do
    category
    |> String.split("-", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # Help Center categories, in the order a new project needs them. Each
  # category owns one root page; its topics are the published docs below
  # that path. A category with no published root page is not shown, so the
  # hub never links to a missing page.
  @docs_categories [
    %{
      key: "get-started",
      title: "Get started",
      root: "/docs/get-started",
      outcome: "Create a project and receive its first real signal."
    },
    %{
      key: "monitor",
      title: "Monitor",
      root: "/docs/monitoring",
      outcome: "Check what you serve and hear from the jobs you schedule."
    },
    %{
      key: "observe",
      title: "Observe",
      root: "/docs/observe",
      outcome: "Capture production errors from your Sentry client."
    },
    %{
      key: "measure",
      title: "Measure",
      root: "/docs/analytics",
      outcome: "Count pageviews and events without cookies."
    },
    %{
      key: "product-analytics",
      title: "Product analytics",
      root: "/docs/product-analytics",
      outcome: "Send behavioural events, then read funnels, activation and retention."
    },
    %{
      key: "mcp",
      title: "MCP",
      root: "/docs/mcp",
      outcome: "Connect your agent and approve what it can do."
    },
    %{
      key: "projects",
      title: "Projects and keys",
      root: "/docs/projects-and-keys",
      outcome: "Scope data to a project and keep ingest keys on the server."
    }
  ]

  @doc "The `{label, anchor}` jump links for an article's body sections."
  def doc_contents(sections) do
    sections
    |> Enum.with_index()
    |> Enum.map(fn {section, index} ->
      {section["heading"] || "Details", doc_anchor(section["heading"], index)}
    end)
  end

  @doc "Content `related_paths` entries as `related_links/1` links with stable ids."
  def related_links(related_paths, id_prefix) do
    Enum.map(related_paths, fn related ->
      slug = related["path"] |> String.trim_leading("/") |> String.replace("/", "-")
      %{id: "#{id_prefix}-#{slug}", label: related["label"], path: related["path"]}
    end)
  end

  @doc """
  Groups published docs under their category: `%{key, title, outcome, root,
  topics}`, where `root` is the category's own page and `topics` are the
  pages below it, sorted by path.
  """
  def docs_categories(docs) do
    Enum.flat_map(@docs_categories, fn category ->
      case Enum.find(docs, &(&1.path == category.root)) do
        nil ->
          []

        root ->
          topics =
            docs
            |> Enum.filter(&String.starts_with?(&1.path, category.root <> "/"))
            |> Enum.sort_by(& &1.path)

          [%{category | root: root} |> Map.put(:topics, topics)]
      end
    end)
  end

  @doc "The category that contains a docs path, with its pages, or `nil`."
  def docs_category_for(path, docs) do
    Enum.find(docs_categories(docs), fn category ->
      path == category.root.path or String.starts_with?(path, category.root.path <> "/")
    end)
  end

  @guide_groups [
    %{key: "scheduled-jobs", title: "Scheduled jobs", cluster: "cron"},
    %{key: "errors", title: "Errors and releases", cluster: "observe"},
    %{key: "analytics", title: "Analytics", cluster: "measure"},
    %{key: "website", title: "Website operations", cluster: "uptime"}
  ]

  def guide_groups(guides) do
    known_clusters = @guide_groups |> Enum.map(& &1.cluster) |> MapSet.new()

    groups =
      Enum.flat_map(@guide_groups, fn group ->
        items = guides |> Enum.filter(&(&1.cluster == group.cluster)) |> Enum.sort_by(& &1.path)
        if items == [], do: [], else: [%{key: group.key, title: group.title, guides: items}]
      end)

    other =
      guides
      |> Enum.reject(&MapSet.member?(known_clusters, &1.cluster))
      |> Enum.sort_by(& &1.path)

    if other == [],
      do: groups,
      else: groups ++ [%{key: "other", title: "More guides", guides: other}]
  end

  # The real product screenshot for a public page, or `nil`. Shots are
  # captured from the seeded demo workspace (`mix alplus.demo_seed`) and
  # live in `priv/static/images/product/`. Analytics comparisons show
  # Measure; error tracking shows Observe; everything else shows Monitor.
  def product_shot("/monitoring" <> _), do: shot("monitor")
  def product_shot("/free-uptime-monitoring"), do: shot("monitor")
  def product_shot("/free-cron-job-monitoring"), do: shot("monitor")
  def product_shot("/error-tracking"), do: shot("observe")
  def product_shot("/analytics"), do: shot("measure")
  def product_shot("/pricing"), do: shot("monitor")
  def product_shot("/alternatives"), do: shot("monitor")

  def product_shot("/alternatives/" <> slug) do
    case comparison_category_for_slug(slug) do
      "measure" -> shot("measure")
      _ -> shot("monitor")
    end
  end

  def product_shot(_path), do: nil

  defp shot("monitor") do
    %{
      src: "/images/product/monitor.webp",
      alt:
        "The PostDeploy Monitor console: fleet health with every monitor operational, a heartbeat monitor's daily pings and availability, and a TCP monitor's response-time chart."
    }
  end

  defp shot("observe") do
    %{
      src: "/images/product/observe.webp",
      alt:
        "The PostDeploy Observe console: an error overview chart with a deploy spike, and the open issue grouped from those events."
    }
  end

  defp shot("measure") do
    %{
      src: "/images/product/measure.webp",
      alt:
        "The PostDeploy Measure console: a traffic overview with pageviews and visitors trending up across two weeks, with no cookies involved."
    }
  end
end
