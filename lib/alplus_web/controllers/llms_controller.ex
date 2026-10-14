defmodule AlplusWeb.LlmsController do
  @moduledoc """
  `GET /llms.txt` (ARCHITECTURE.md §9, BUILD.md Phase 4). Package numbers
  come from `Alplus.Billing.Package`, the enforced entitlements, so this file
  cannot drift from the product. AI crawlers are allowed by `robots.txt`;
  this is the machine-readable summary they are allowed to read.

  The layout follows llmstxt.org: an H1, a blockquote summary, detail
  paragraphs, then H2 link lists with the secondary pages under `Optional`.
  Content pages come from `Alplus.Content`, so the file lists the same URLs as
  `/sitemap.xml`.
  """

  use AlplusWeb, :controller

  alias Alplus.Billing.Package
  alias Alplus.Content
  alias AlplusWeb.Blog
  alias AlplusWeb.Marketing.PackagePresenter
  alias AlplusWeb.Marketing.Seo

  @site_suffix ~r/\s\|\sPostDeploy(\sDocs)?$/

  @optional_paths ~w(/about /privacy /terms)
  @lead_paths ["/", "/pricing"]

  @tool_entries [
    {"Website health check", "/tools/website-health-check",
     "Check whether a public URL responds, redirects, or has a certificate near expiry."},
    {"Changelog", "/changelog", "Product updates and release notes."},
    {"Product facts (JSON)", "/product-facts.json",
     "The package, limits, check types, alert channels and privacy model as JSON."}
  ]

  def index(conn, _params) do
    {:ok, pages} = Content.list_pages()
    {:ok, guides} = Content.list_guides()
    {:ok, comparisons} = Content.list_comparisons()
    {:ok, articles} = Blog.list()

    content = Enum.map(pages ++ guides ++ comparisons, &content_entry/1)

    blog =
      [
        {"Blog", "/blog",
         "Practical guidance for uptime, cron jobs, errors, analytics, and observability."}
      ] ++
        Enum.map(articles, &{&1.title, "/blog/#{&1.slug}", &1.description})

    link_lists =
      [
        {"Product", Enum.filter(content, &(section(&1) == :product))},
        {"Docs", Enum.filter(content, &(section(&1) == :docs))},
        {"Guides", Enum.filter(content, &(section(&1) == :guides))},
        {"Alternatives", Enum.filter(content, &(section(&1) == :alternatives))},
        {"Blog", blog},
        {"Tools and data", @tool_entries},
        {"Optional", Enum.filter(content, &(section(&1) == :optional))}
      ]
      |> Enum.map_join("\n\n", fn {heading, entries} -> "## #{heading}\n\n#{links(entries)}" end)

    body = """
    # PostDeploy

    > PostDeploy is a project-based reliability toolkit for small software teams. It
    > combines uptime and API checks, cron-job heartbeats, error tracking, and
    > privacy-first web analytics in one organisation, for one flat monthly price.
    > Every new organisation starts a #{Package.trial_days()}-day free trial with no card.
    >
    > Monitor (uptime + heartbeats), Observe (error tracking) and Measure
    > (analytics) are all live.

    Setup: a coding agent connected over MCP creates the monitors, heartbeats,
    error sources and analytics keys, and you review them in the dashboard. You
    create the organisation in the dashboard. Projects come from you or from
    your agent. The free website health check starts a continuous URL check
    without an agent. After setup, no agent runs in production: your code calls
    a heartbeat URL, a Sentry client or a script tag.

    Pricing: PostDeploy sells one package. Every new organisation starts a
    #{Package.trial_days()}-day free trial with no card and every PostDeploy
    limit. When the trial ends, the organisation becomes read-only until it
    subscribes.

    #{package_line()}

    The package covers all three pillars for one organisation. Projects,
    members and monitors stop at their limit. Monthly events warn at 80%,
    continue to #{PackagePresenter.event_ceiling_percent()}, then drop until the
    month resets. Nothing is ever added to the invoice.

    Not included: #{Enum.join(PackagePresenter.not_included(), ", ")}.

    Monitor checks: HTTP, keyword, TCP, DNS, and heartbeats, plus SSL and
    domain expiry warnings. Alerts go to email, Slack, Discord, webhook and
    Telegram, during the trial and after it. Each project can publish a status
    page and a changelog.

    Not offered: ICMP ping checks, UDP checks, browser or
    transaction checks, multi-region checking (checks run from one region),
    and on-call rotation or escalation policies.

    Heartbeats: ping `https://ingest.postdeploy.dev/h/{token}` with GET or POST
    from a cron job, systemd timer, CI workflow or scheduled handler. Add
    `?state=start` and `?state=finish` to also measure job duration, or report a
    shell exit status directly with
    `https://ingest.postdeploy.dev/h/{token}/$?`, where `0` is a success and any
    other value opens an incident immediately. A job that never runs sends
    nothing, so no incident opens and no alert is sent; an interval-scheduled
    monitor shows Late on the Monitor screen.

    Error tracking: create an Observe key, then set the DSN of a Sentry client
    in server code to `https://<obs_key>@ingest.postdeploy.dev/1`. Errors arrive
    grouped into issues, with the release, environment and user you attach.

    Analytics: Measure stores no cookies, no raw IP addresses and no persistent
    visitor identifiers; visitors are counted with a salted HMAC whose salt
    rotates daily.

    #{link_lists}
    """

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end

  defp content_entry(item) do
    {String.replace(item.title, @site_suffix, ""), item.path, item.summary}
  end

  defp section({_name, path, _summary}) do
    cond do
      path in @optional_paths -> :optional
      under?(path, "/docs") -> :docs
      under?(path, "/guides") -> :guides
      under?(path, "/alternatives") -> :alternatives
      true -> :product
    end
  end

  defp under?(path, prefix), do: path == prefix or String.starts_with?(path, prefix <> "/")

  defp links(entries) do
    entries
    |> Enum.sort_by(fn {_name, path, _summary} -> {lead_rank(path), path} end)
    |> Enum.map_join("\n", fn {name, path, summary} ->
      "- [#{name}](#{Seo.origin()}#{path}): #{summary}"
    end)
  end

  defp lead_rank(path), do: Enum.find_index(@lead_paths, &(&1 == path)) || length(@lead_paths)

  # The package, read from enforced entitlements at request time.
  defp package_line do
    package = Package.get()
    limits = package.limits

    "- #{package.name}: #{PackagePresenter.price()}/month, billed monthly. " <>
      "#{limits.projects} projects, #{limits.members} members, " <>
      "#{limits.uptime_monitors} uptime monitors, #{limits.cron_jobs} cron jobs, " <>
      "#{PackagePresenter.interval_label(limits.min_check_interval_seconds)} check interval, " <>
      "#{limits.detailed_uptime_retention_days} days of detailed uptime samples, " <>
      "#{PackagePresenter.thousands(limits.analytics_events_per_month)} analytics events and " <>
      "#{PackagePresenter.thousands(limits.error_events_per_month)} error events per month."
  end
end
