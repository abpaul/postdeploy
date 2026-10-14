defmodule AlplusWeb.PageControllerTest do
  @moduledoc """
  The public marketing site (ARCHITECTURE.md §9, BUILD.md Phase 4). Content
  comes from `Alplus.Content`, seeded fresh per test since the sandbox rolls
  back between tests.
  """

  use AlplusWeb.ConnCase, async: false

  alias Alplus.Billing.Package
  alias Alplus.Content
  alias Alplus.Content.Seeds
  alias Alplus.Measure.PublicCache
  alias AlplusWeb.Marketing.HomepageData
  alias AlplusWeb.Marketing.PackagePresenter

  setup do
    :ok = Seeds.run()
    PublicCache.clear()
    :ok
  end

  describe "marketing routes" do
    test "GET / returns 200 with real content and no Phoenix scaffold header", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)
      assert html =~ "<h1"
      refute html =~ "v#{Application.spec(:phoenix, :vsn)}"
      assert html =~ ~s(aria-label="PostDeploy home")
      assert html =~ ~s(href="/favicon.svg")
      assert html =~ ~s(href="/favicon.ico")
      assert html =~ ~s(href="/apple-touch-icon.png")
      assert html =~ ~s(id="console-preview")
      assert html =~ ~s(data-state="empty")
      refute html =~ "Acme Dev Co"
      refute html =~ "99.98%"
      refute html =~ "186ms"
      refute html =~ "phoenixframework.org"
    end

    test "the marketing call to action targets the registration path, not the console",
         %{conn: conn} do
      # The primary CTA used to point at `/dashboard`, which bounces an
      # anonymous visitor to sign-in and asks a stranger for a password.
      # This must fail again if that regresses.
      for path <- ["/", "/pricing", "/alternatives", "/alternatives/cronitor"] do
        html = html_response(get(conn, path), 200)

        assert html =~ ~s(href="/register")
        refute html =~ ~s(href="/dashboard")
      end
    end

    test "the marketing call to action targets the console for a signed-in visitor",
         %{conn: conn} do
      # A signed-in operator following the trial CTA used to land
      # on /register, whose `live_no_user` mount bounced them back to the
      # homepage: a dead end. Every CTA on the page must aim at /dashboard
      # instead.
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> AshAuthentication.Plug.Helpers.store_in_session(Alplus.OrgsFixtures.user_fixture())

      html = html_response(get(conn, ~p"/"), 200)

      assert html =~ ~s(href="/dashboard")
      refute html =~ ~s(href="/register")
    end

    test "GET /pricing returns 200", %{conn: conn} do
      conn = get(conn, ~p"/pricing")
      assert html_response(conn, 200) =~ "<h1"
    end

    test "GET /free-uptime-monitoring returns 200", %{conn: conn} do
      conn = get(conn, ~p"/free-uptime-monitoring")
      assert html_response(conn, 200) =~ "<h1"
    end

    test "GET /free-cron-job-monitoring returns 200", %{conn: conn} do
      conn = get(conn, ~p"/free-cron-job-monitoring")
      assert html_response(conn, 200) =~ "<h1"
    end

    test "GET /alternatives returns 200 and lists every comparison", %{conn: conn} do
      conn = get(conn, ~p"/alternatives")
      html = html_response(conn, 200)
      assert html =~ "Cronitor"
      assert html =~ "UptimeRobot"
      assert html =~ "Plausible"
      assert html =~ "Fathom Analytics"
      assert html =~ "Google Analytics"
    end

    test "GET /alternatives/:slug returns 200 for each analytics competitor", %{conn: _conn} do
      for {slug, name} <- [
            {"plausible", "Plausible"},
            {"fathom", "Fathom Analytics"},
            {"google-analytics", "Google Analytics"}
          ] do
        html = html_response(get(build_conn(), ~p"/alternatives/#{slug}"), 200)
        assert html =~ "PostDeploy as a #{name} alternative"
      end
    end

    test "GET /alternatives/:slug returns 200 for a real competitor", %{conn: conn} do
      conn = get(conn, ~p"/alternatives/cronitor")
      html = html_response(conn, 200)
      assert html =~ "PostDeploy as a Cronitor alternative"
      refute html =~ "Alplus.Billing.Package.trial_days()"
    end

    test "every comparison renders vendor sources and the date each fact set was checked", %{
      conn: _conn
    } do
      for slug <-
            ~w(cronitor uptimerobot healthchecks-io better-stack plausible fathom google-analytics) do
        {:ok, comparison} = Content.get_comparison_by_slug(slug)
        html = html_response(get(build_conn(), ~p"/alternatives/#{slug}"), 200)
        document = LazyHTML.from_document(html)
        sources = LazyHTML.query(document, "#alternative-sources")
        source_html = LazyHTML.to_html(sources)
        source_text = LazyHTML.text(sources)

        assert Enum.count(sources) == 1
        assert source_text =~ "Sources"

        assert comparison.sources != []

        for source <- comparison.sources do
          assert source_html =~ ~s(href="#{source["url"]}")
          assert source_text =~ source["label"]
          assert source_text =~ "Checked #{source["retrieved"]}"
          assert source_html =~ ~s(datetime="#{source["retrieved"]}")
        end
      end
    end

    test "the Plausible FAQ does not attach trial card terms to the paid plan", %{
      conn: conn
    } do
      document =
        conn
        |> get(~p"/alternatives/plausible")
        |> html_response(200)
        |> LazyHTML.from_document()

      faq = document |> LazyHTML.query("#alternative-faq") |> LazyHTML.text()

      assert faq =~ "How many analytics events does PostDeploy include?"

      assert faq =~
               "#{PackagePresenter.thousands(Package.limit(:analytics_events_per_month))} a month"

      refute faq =~ "no credit card"
    end

    test "legacy free monitoring guides render their established byline and review dates", %{
      conn: _conn
    } do
      for path <- ["/free-uptime-monitoring", "/free-cron-job-monitoring"] do
        document = build_conn() |> get(path) |> html_response(200) |> LazyHTML.from_document()
        article = LazyHTML.query(document, "#guide-article")
        article_text = article |> LazyHTML.text() |> String.replace(~r/\s+/, " ")

        assert article_text =~ "By Paul"
        assert article_text =~ "published 2026-08-03"
        assert article_text =~ "last verified 2026-08-03"
        assert article |> LazyHTML.query("time[datetime='2026-08-03']") |> Enum.count() == 2
      end
    end

    test "public page breadcrumbs visibly mirror their assigned schema trails", %{conn: _conn} do
      for {path, id, current, parent_paths} <- [
            {"/pricing", "pricing-breadcrumbs", "Pricing", ["/"]},
            {"/guides", "guides-breadcrumbs", "Guides", ["/"]},
            {"/alternatives", "alternatives-breadcrumbs", "Alternatives", ["/"]},
            {"/alternatives/cronitor", "alternative-breadcrumbs", "Cronitor alternative",
             ["/", "/alternatives"]}
          ] do
        document = build_conn() |> get(path) |> html_response(200) |> LazyHTML.from_document()
        breadcrumbs = LazyHTML.query(document, "##{id}")

        assert Enum.count(breadcrumbs) == 1

        assert breadcrumbs |> LazyHTML.query("[aria-current='page']") |> LazyHTML.text() =~
                 current

        assert breadcrumbs |> LazyHTML.query("a[aria-current='page']") |> Enum.empty?()

        for parent_path <- parent_paths do
          assert breadcrumbs
                 |> LazyHTML.query("a[href='#{parent_path}']")
                 |> Enum.count() == 1
        end
      end
    end

    test "comparison families count registered rows and retain a novel category" do
      families =
        AlplusWeb.PageHTML.comparison_families([
          %{slug: "new-observer", path: "/alternatives/new-observer", category: "observe"}
        ])

      assert [%{pillar: "Observe", heading: "Observe comparisons", items: [comparison]}] =
               families

      assert comparison.slug == "new-observer"
      assert hd(families).blurb =~ "1 comparison"
    end

    test "every comparison renders the competitor's pricing walk", %{conn: _conn} do
      # A comparison page that only ships a feature table leaves the
      # evaluator's first question unanswered: what does each tier cost at
      # my size.
      for slug <-
            ~w(cronitor uptimerobot healthchecks-io better-stack plausible fathom google-analytics) do
        {:ok, comparison} = Content.get_comparison_by_slug(slug)
        document = build_conn() |> get(~p"/alternatives/#{slug}") |> html_response(200)
        document = LazyHTML.from_document(document)

        detail = document |> LazyHTML.query("#alternative-detail") |> LazyHTML.text()

        assert comparison.body_sections != [], "#{slug} has no prose comparison"
        assert detail =~ "Pricing, tier by tier"

        for section <- comparison.body_sections, paragraph <- section["body"] do
          assert detail =~ String.slice(paragraph, 0, 40)
        end
      end
    end

    test "marketing code samples point at routes that exist" do
      {:ok, comparisons} = Content.list_comparisons()

      urls =
        for comparison <- comparisons,
            section <- comparison.body_sections,
            code = section["code"],
            [url] <- Regex.scan(~r{https://ingest\.postdeploy\.dev/[^\s"'<>]+}, code),
            do: {comparison.slug, url}

      assert urls != []

      for {slug, url} <- urls do
        path = url |> URI.parse() |> Map.fetch!(:path)

        assert Phoenix.Router.route_info(AlplusWeb.Router, "GET", path, "ingest.postdeploy.dev") !=
                 :error,
               "#{slug} sample points at #{url}, which no route serves"
      end
    end

    test "example sessions run only actions the MCP server publishes" do
      {:ok, guides} = Content.list_guides()
      published = MapSet.new(Alplus.Mcp.Dispatch.tools(), & &1.name)

      actions =
        for guide <- guides,
            section <- guide.body_sections,
            %{"actions" => actions} <- [section["transcript"]],
            [action, _target] <- actions,
            do: action

      assert actions != []

      for action <- actions do
        assert MapSet.member?(published, action), "#{action} is not a published MCP action"
      end
    end

    test "the alternatives index emits its switching FAQs as FAQ schema", %{conn: conn} do
      # The index answers the four questions a switcher asks before reading
      # any single comparison. Without the graph they are invisible to
      # search, exactly like the per-comparison FAQs that already ship one.
      {:ok, page} = Content.get_page_by_path("/alternatives")

      graphs =
        conn
        |> get(~p"/alternatives")
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("script[type='application/ld+json']")
        |> Enum.map(&LazyHTML.text/1)
        |> Enum.map(&Jason.decode!/1)

      faq_graph = Enum.find(graphs, &(&1["@type"] == "FAQPage"))
      assert faq_graph

      assert Enum.map(faq_graph["mainEntity"], & &1["name"]) == Enum.map(page.faqs, & &1["q"])
    end

    test "a comparison lists its own category's comparisons before the others" do
      current = %{slug: "cronitor", path: "/alternatives/cronitor"}

      others = [
        %{slug: "plausible", path: "/alternatives/plausible", competitor_name: "Plausible"},
        %{slug: "uptimerobot", path: "/alternatives/uptimerobot", competitor_name: "UptimeRobot"},
        %{slug: "fathom", path: "/alternatives/fathom", competitor_name: "Fathom Analytics"},
        %{
          slug: "better-stack",
          path: "/alternatives/better-stack",
          competitor_name: "Better Stack"
        }
      ]

      assert AlplusWeb.PageHTML.related_comparisons(current, others) |> Enum.map(& &1.slug) ==
               ~w(better-stack uptimerobot fathom plausible)
    end

    test "named interior routes keep one heading and a static content shell", %{conn: _conn} do
      paths = [
        "/monitoring",
        "/monitoring/uptime",
        "/monitoring/cron-jobs",
        "/monitoring/api",
        "/error-tracking",
        "/analytics",
        "/pricing",
        "/alternatives",
        "/alternatives/cronitor",
        "/guides",
        "/guides/github-actions-heartbeat",
        "/docs",
        "/docs/observe/javascript",
        "/about",
        "/privacy",
        "/terms"
      ]

      for path <- paths do
        html = html_response(get(build_conn(), path), 200)
        [main] = Regex.run(~r{<main[^>]*>(.*)</main>}s, html, capture: :all_but_first)

        assert Regex.scan(~r{<h1\b}, main) |> length() == 1,
               "expected one H1 on #{path}"

        if String.starts_with?(path, "/docs") or String.starts_with?(path, "/guides") do
          assert main =~ ~s(id="resource-desktop-nav"),
                 "missing resource navigation on #{path}"
        else
          assert main =~ ~r{id="[^"]+-leadspace"},
                 "missing shared leadspace on #{path}"

          assert main =~ ~r{<article[^>]*id="[^"]+-article"},
                 "missing shared article shell on #{path}"
        end

        refute main =~ ~r/phx-(click|submit|change|keyup|keydown|hook)=/,
               "marketing route contains a LiveView binding: #{path}"

        refute main =~
                 ~r/(?:^|[\s"])(block-press|shadow-block|bg-accent|bg-surface-2|bg-ink-band|border-rule|divide-border)(?:[\s"]|$)/,
               "legacy marketing utility leaked into #{path}"
      end
    end

    test "pricing and alternative comparisons expose accessible desktop and mobile stacks", %{
      conn: conn
    } do
      pricing = html_response(get(conn, ~p"/pricing"), 200)
      comparison = html_response(get(build_conn(), ~p"/alternatives/cronitor"), 200)

      assert pricing =~ ~s(id="package-included")

      allowance_labels =
        pricing
        |> LazyHTML.from_document()
        |> LazyHTML.query("#package-included dt")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))

      for label <- ["Projects", "Members", "Fastest uptime interval", "Alert channels"] do
        assert Enum.any?(allowance_labels, &String.starts_with?(&1, label)),
               "missing allowance row #{label}"
      end

      refute pricing =~ ~s(role="tablist")
      refute pricing =~ "noted for comparison"

      assert pricing =~ ~s(id="package-price")

      assert comparison =~ ~s(id="comparison-matrix")

      assert comparison =~ ~s(<caption class="sr-only">)
      assert comparison =~ "Cronitor and PostDeploy comparison"

      assert comparison =~ ~s(class="hidden overflow-x-auto md:block")
      assert comparison =~ ~s(class="divide-y divide-border-default md:hidden")
      assert comparison =~ ~s(<dt class="text-heading-02 text-text-primary">)

      assert comparison =~
               ~s(<dt class="text-label font-semibold text-text-secondary">Cronitor</dt>)

      assert comparison =~
               ~s(<dt class="text-label font-semibold text-text-secondary">PostDeploy</dt>)
    end

    test "every public page ends with the single site-wide CTA", %{conn: _conn} do
      home = html_response(get(build_conn(), ~p"/"), 200)
      assert home =~ ~s(id="home-final-cta")

      for path <- [
            "/pricing",
            "/alternatives",
            "/alternatives/cronitor",
            "/guides",
            "/about"
          ] do
        html = html_response(get(build_conn(), path), 200)
        assert html =~ ~s(href="/register")
        refute html =~ ~r/>\s*Join the waitlist\s*</
      end
    end

    test "GET /alternatives/does-not-exist returns 404", %{conn: conn} do
      # `PageController.alternatives_show/2` raises `AlplusWeb.NotFoundError`
      # for an unknown slug; `Phoenix.Endpoint` renders the error page and
      # then re-raises (by design, so a real deploy still logs/crashes the
      # request process) — `assert_error_sent/2` is the documented way to
      # assert on the response that was sent before that re-raise.
      assert_error_sent 404, fn -> get(conn, ~p"/alternatives/does-not-exist") end
    end
  end

  describe "homepage structure" do
    test "the homepage shell exposes accessible navigation and real vendor state", %{conn: conn} do
      html = html_response(get(conn, ~p"/"), 200)

      assert html =~ ~s(id="marketing-header")
      assert html =~ ~r/id="marketing-header"[^>]*\bsticky\b[^>]*\bz-40\b/
      assert html =~ ~s(id="marketing-nav")
      assert html =~ ~s(id="marketing-mobile-menu-toggle")
      assert html =~ ~s(class="hidden sm:block")
      assert html =~ ~s(aria-expanded="false")
      assert html =~ ~s(aria-controls="marketing-mobile-sheet")
      assert html =~ ~s(aria-label="Mobile primary")
      assert html =~ ~s(id="marketing-mobile-sheet")

      assert [noscript] =
               Regex.run(~r{<noscript>(.*?)</noscript>}s, html, capture: :all_but_first)

      assert noscript =~ ~s(id="marketing-mobile-noscript")
      assert noscript =~ ~s(aria-label="Mobile primary without JavaScript")

      for {_label, path} <- AlplusWeb.MarketingComponents.header_links() do
        assert noscript =~ ~s(href="#{path}")
      end

      assert noscript =~ "Start free trial"
      assert html =~ ~s(id="landing-footer-brand")
      assert html =~ ~s(href="https://badarau.net")
      assert html =~ "Paul Bădărău"
      assert html =~ ~r{min-h-target-min[^>]*id="landing-footer-brand"}

      built_with = html |> LazyHTML.from_document() |> LazyHTML.query("#built-with")
      vendor_links = LazyHTML.query(built_with, "a")

      assert Enum.map(vendor_links, &LazyHTML.attribute(&1, "href")) == [
               ["https://elixir-lang.org"],
               ["https://ash-hq.org"],
               ["https://www.cloudflare.com"],
               ["https://www.ovhcloud.com"]
             ]

      assert Enum.map(LazyHTML.query(built_with, "img"), &LazyHTML.attribute(&1, "alt")) == [
               ["Elixir"],
               ["Ash"],
               ["Cloudflare"],
               ["OVHcloud"]
             ]

      for footer_path <- [
            "/monitoring",
            "/analytics",
            "/pricing",
            "/alternatives",
            "/changelog",
            "/about",
            "/privacy",
            "/terms",
            "/guides",
            "/error-tracking"
          ] do
        assert html =~ ~r{<a href="#{Regex.escape(footer_path)}"[^>]*min-h-target-min}
      end

      assert html =~ ~s(id="leadspace")
      assert html =~ ~r/<section[^>]*id="console-preview"[^>]*data-state="empty"/
      assert html =~ ~s(aria-label="Live PostDeploy project evidence")
      assert html =~ ~s(id="monitor")
      assert html =~ ~s(id="measure")
      assert html =~ ~s(id="mcp")
      assert html =~ ~s(id="home-metrics")
      assert html =~ "No monitors published yet"
      assert html =~ "No data"
      refute html =~ "Unavailable"
      assert html =~ "mountMarketingDisclosure"
      assert html =~ "event.key === \"Escape\""
      assert html =~ "mountMarketingTabs"
      assert html =~ ~s(id="home-setup-code")
      assert html =~ ~s(id="home-measure-ranges")
      assert html =~ ~s(id="home-final-cta")
      assert html =~ ~r/<a(?=[^>]*\bid="home-hero-cta")(?=[^>]*\bhref="\/register")[^>]*>/

      assert html =~
               ~r/<a(?=[^>]*\bid="home-hero-guide")(?=[^>]*\bhref="\/docs\/get-started")[^>]*>/

      assert Regex.match?(
               ~r/<section[^>]*id="home-final-cta"[^>]*>.*?<a[^>]*href="\/register"/s,
               html
             )

      refute html =~ "AL+"
      # The preview switches are the only live controls on the page, and they
      # are click-only. Nothing here submits, changes or key-handles, so a
      # visitor never meets a form or a keyboard trap on the marketing page.
      refute html =~ ~r/phx-(submit|change|keyup|keydown)=/
    end

    test "the preview surface carries exactly one understated label", %{conn: conn} do
      # The old template repeated "Illustrative preview" on every card, metric
      # and caption. One label on the containing frame says the same thing once.
      set_preview_flag(true)

      html = html_response(get(conn, ~p"/"), 200)

      assert html =~ ~r/<section[^>]*id="console-preview"[^>]*data-state="preview"/
      assert html =~ ~s(aria-label="Example project evidence")
      assert html =~ ~r/id="home-metrics"(?s:.*?)data-state="preview"/
      assert html =~ ~r/id="console-preview-panel-monitor"(?s:.*?)data-state="preview"/
      # `2eadff3a` isolated publication examples: the changelog panel is a
      # published example rather than projected preview data, and says so.
      assert html =~ ~r/id="console-preview-panel-changelog"(?s:.*?)data-state="example"/
      assert length(Regex.scan(~r/Preview data/, html)) == 1
      refute html =~ "Illustrative"
      assert Regex.scan(~r/style="height: [^"]+%"/, html) != []

      for private_text <- ["Acme Dev Co", "Acme customer", "private project", "PRIVATE"] do
        refute html =~ private_text
      end
    end

    test "no preview label appears when the preview is disabled", %{conn: conn} do
      set_preview_flag(false)

      html = html_response(get(conn, ~p"/"), 200)

      refute html =~ "Preview data"
      refute html =~ "Illustrative"
    end

    test "homepage previews use passive ranges and honest empty real data", %{conn: conn} do
      [main] =
        Regex.run(~r{<main[^>]*>(.*)</main>}s, html_response(get(conn, ~p"/"), 200),
          capture: :all_but_first
        )

      assert main =~ ~r/<section[^>]*id="console-preview"[^>]*data-state="empty"/
      assert main =~ ~s(id="console-preview-ranges")
      assert main =~ ~s(aria-pressed="true")
      assert main =~ ~s(id="console-preview-panel-monitor")
      # Each tile states what its own section holds, read from the projection.
      for tile <- HomepageData.load(%{}).overview.tiles do
        assert main =~ tile.sub
      end

      # The chart caption and axis are whatever the selected range projects.
      chart = HomepageData.load(%{}).overview.chart
      assert main =~ chart.caption
      assert main =~ chart.axis_start
      # 24h is the default range, so it is the pill the frame marks as current.
      assert main =~ ~r/id="console-preview-ranges"(?s:.*?)aria-pressed="true"(?s:.*?)24h/
      refute main =~ ~s(role="img")
      refute main =~ "Unavailable%"
      # `aria-controls` pointing at the element that carries it is invalid ARIA.
      refute main =~ ~s(aria-controls="homepage-measure-row-0")
      # No em dash, en dash or middot may reach a reader.
      refute main =~ ~r/[\x{2014}\x{2013}\x{00B7}]/u
      # Raw hex utilities bypass the token contract.
      refute main =~ ~r/\b(?:bg|text|border)-\[#/
      refute main =~ "99.98%"
      refute main =~ "186ms"
      refute main =~ "2,410"
      refute main =~ "Acme Dev Co"
      refute main =~ ~r/<[^>]+\srole="tab(?:list|panel)?"/
      refute main =~ ~r/<[^>]+\sdata-marketing-tab(?:list|s-scope|=)/
    end

    test "homepage Measure preview exposes bounded public ranges", %{conn: conn} do
      html = html_response(get(conn, ~p"/"), 200)

      assert html =~ ~s(id="home-measure-ranges")
      assert length(Regex.scan(~r/data-home-measure-range="(?:7d|14d|30d)"/, html)) == 3
      # By attribute rather than by adjacency, so the assertion does not
      # depend on the order the template happens to write attributes in.
      assert attributes(html, ~s(button[data-home-measure-range="7d"]), "aria-pressed") == [
               "true"
             ]

      assert pressed_count(html, "#home-measure-ranges") == 1
      refute html =~ ~s(text-interactive-strong">+12%</span>)
      refute html =~ "2,410"
    end

    test "every chart offers a screen-reader table and one exact signup CTA", %{conn: conn} do
      set_preview_flag(true)

      html = html_response(get(conn, ~p"/"), 200)

      data = HomepageData.load(%{})

      for caption <- [
            data.overview.chart.table_caption,
            "Pageviews and visitors by day for the last 7 days.",
            "Most viewed pages by pageviews for the last 7 days."
          ] do
        assert html =~ caption
      end

      assert html =~ ~s(<div class="sr-only">)

      assert length(Regex.scan(~r/Start your #{Package.trial_days()}-day free trial/, html)) == 2
      assert html =~ "#{Package.trial_days()} days free. No credit card."
    end

    test "homepage identity and section bands keep their semantic contracts",
         %{conn: conn} do
      html = html_response(get(conn, ~p"/"), 200)

      refute html =~ "Acme Dev Co"
      assert html =~ ~r/id="mcp"\s+class="[^"]*\bbg-canvas\b/
      assert html =~ ~r/id="measure"\s+class="[^"]*\bbg-canvas\b/
      assert html =~ ~r/id="console-preview"[^>]+class="[^"]*\bmin-w-0\b[^"]*\bmax-w-full\b/
      assert html =~ ~s(flex min-w-0 flex-wrap items-center gap-x-2.5 gap-y-2)
    end

    test "homepage metrics come from the public homepage projection", %{conn: conn} do
      data = HomepageData.load(%{})
      html = html_response(get(conn, ~p"/"), 200)

      assert data.state == :empty
      assert data.monitor.state == :empty
      assert data.measure.state == :empty
      assert data.observe.state == :empty
      assert data.status.state == :empty
      assert data.changelog.state == :empty
      assert Map.has_key?(data, :identity)
      assert Map.has_key?(data, :monitor)
      assert Map.has_key?(data, :measure)
      assert Map.has_key?(data, :observe)
      assert Map.has_key?(data, :status)
      assert Map.has_key?(data, :changelog)
      refute html =~ "AlplusWeb.Marketing.PreviewData"
      refute html =~ "Acme Dev Co"
      refute html =~ "186ms"
      refute html =~ "99.98%"
      refute html =~ "2,410"
    end

    test "the home page names no competitor", %{conn: conn} do
      [main] =
        Regex.run(~r{<main[^>]*>(.*)</main>}s, html_response(get(conn, ~p"/"), 200),
          capture: :all_but_first
        )

      # Comparisons belong on /alternatives/*, where every figure carries a
      # vendor-owned source in a code comment. The home page sells PostDeploy.
      for vendor <- [
            "UptimeRobot",
            "Better Stack",
            "Cronitor",
            "Healthchecks",
            "Plausible",
            "Fathom",
            "Google Analytics"
          ] do
        refute main =~ vendor
      end
    end

    test "the hero session names only actions the MCP catalog registers", %{conn: conn} do
      home = html_response(get(conn, ~p"/"), 200)

      [session] =
        home
        |> LazyHTML.from_document()
        |> LazyHTML.query("#home-setup-code")
        |> Enum.map(&LazyHTML.text/1)

      action_ids =
        ~r/✓\s+([a-z_]+\.[a-z_]+)/u
        |> Regex.scan(session, capture: :all_but_first)
        |> List.flatten()

      assert action_ids == [
               "monitor.create",
               "monitor.create",
               "monitor.create",
               "measure.create_source",
               "status.ensure_workspace"
             ]

      for id <- action_ids do
        assert {:ok, _adapter, _tool} = Alplus.Mcp.Catalog.get(id)
      end
    end

    test "the home page draws the mark inline and lazy-loads only product screenshots", %{
      conn: conn
    } do
      html = html_response(get(conn, ~p"/"), 200)

      img_tags = Regex.scan(~r{<img[^>]+src="/images/product/[^\"]+\.webp"[^>]*>}, html)
      img_tags = List.flatten(img_tags)

      assert img_tags != []

      for tag <- img_tags do
        assert tag =~ ~r/src="\/images\/product\/[^"]+\.webp"/
        assert tag =~ ~s(loading="lazy")
      end

      assert html =~ ~s(viewBox="0 0 512 512")
    end

    test "the objections render as a static list, with no accordion and no JavaScript hooks",
         %{conn: conn} do
      html = html_response(get(conn, ~p"/pricing"), 200)

      assert html =~ "What happens after the #{Package.trial_days()} days?"
      refute html =~ "<details"
      refute html =~ "phx-click="
    end
  end

  describe "pricing numbers" do
    test "the pricing page renders the package's numbers, not a literal", %{conn: conn} do
      html = conn |> get(~p"/pricing") |> html_response(200)
      plan = Package.get()
      document = LazyHTML.from_document(html)

      assert html =~ "#{Package.trial_days()}-day free trial"
      assert html =~ "No card required"

      offer = document |> LazyHTML.query("#package-offer") |> LazyHTML.text()

      assert offer =~ plan.name
      assert offer =~ "$#{div(plan.price.amount_usd_cents, 100)}"
      assert offer =~ "Billed monthly"
      assert offer =~ plan.eligibility
      assert offer =~ "#{plan.limits.uptime_monitors} uptime and API monitors"

      features = document |> LazyHTML.query("#package-features") |> LazyHTML.text()

      for feature <- plan.features, do: assert(features =~ feature.name)

      refute html =~ "/year"
      refute html =~ ~r{data-plan-id="trial"}
      refute html =~ ~r{>\s*\$0\s*<}
    end

    test "the included list visibly states every public canonical fact", %{conn: conn} do
      document =
        conn
        |> get(~p"/pricing")
        |> html_response(200)
        |> LazyHTML.from_document()

      included_text = document |> LazyHTML.query("#package-included") |> LazyHTML.text()
      limits = Package.get().limits

      assert included_text =~ "Public pages"
      assert included_text =~ "No page-count limit"
      assert included_text =~ "DNS"
      assert included_text =~ "#{limits.uptime_incident_rollup_months} months"
      assert included_text =~ "#{limits.measure_retention_days} days"

      refute included_text =~ "Goal tracking"
      refute included_text =~ "Logs"
    end

    test "the terms section states how limits behave and what is not included", %{conn: conn} do
      document =
        conn
        |> get(~p"/pricing")
        |> html_response(200)
        |> LazyHTML.from_document()

      terms = document |> LazyHTML.query("#pricing-terms") |> LazyHTML.text()
      package = Package.get()

      assert terms =~ "#{100 + package.event_grace_percent}% of the allowance"
      assert terms =~ "deleted #{package.inactive_retention_days} days later"
      for item <- package.not_included, do: assert(terms =~ item)
    end

    test "interior evidence contains no homepage preview stand-ins", %{conn: _conn} do
      for path <- ["/monitoring", "/error-tracking", "/analytics"] do
        html = html_response(get(build_conn(), path), 200)

        refute html =~ "Acme Dev Co", "homepage organization leaked into #{path}"
        refute html =~ "99.98%", "homepage uptime snapshot leaked into #{path}"
        refute html =~ "6,984", "homepage traffic snapshot leaked into #{path}"
        refute html =~ "v2.4.1", "homepage release snapshot leaked into #{path}"
      end
    end
  end

  describe "SEO plumbing" do
    test "every page emits a canonical URL and a meta description", %{conn: _conn} do
      for path <- [
            ~p"/",
            ~p"/pricing",
            ~p"/free-uptime-monitoring",
            ~p"/free-cron-job-monitoring",
            ~p"/alternatives",
            ~p"/alternatives/cronitor",
            ~p"/alternatives/plausible"
          ] do
        conn = get(build_conn(), path)
        html = html_response(conn, 200)
        assert html =~ ~s(rel="canonical"), "missing canonical on #{path}"
        assert html =~ ~s(name="description"), "missing meta description on #{path}"
      end
    end

    test "seed lastmod dates move changed rows without rewriting untouched content dates", %{
      conn: _conn
    } do
      assert {:ok, %{lastmod: ~D[2026-08-31]}} = Content.get_page_by_path("/pricing")
      assert {:ok, %{lastmod: ~D[2026-09-30]}} = Content.get_page_by_path("/guides")

      assert {:ok, %{lastmod: ~D[2026-09-15]}} = Content.get_page_by_path("/alternatives")

      for path <- [
            "/free-uptime-monitoring",
            "/free-cron-job-monitoring",
            "/privacy",
            "/about",
            "/terms"
          ] do
        assert {:ok, %{lastmod: ~D[2026-08-31]}} = Content.get_guide_by_path(path)
      end

      assert {:ok, %{lastmod: ~D[2026-09-10]}} = Content.get_guide_by_path("/analytics")

      assert {:ok, %{lastmod: ~D[2026-09-09]}} = Content.get_guide_by_path("/monitoring")
      assert {:ok, %{lastmod: ~D[2026-10-12]}} = Content.get_guide_by_path("/error-tracking")

      for slug <- ~w(cronitor uptimerobot healthchecks-io better-stack plausible fathom) do
        assert {:ok, %{lastmod: ~D[2026-08-31]}} = Content.get_comparison_by_slug(slug)
      end

      assert {:ok, %{lastmod: ~D[2026-09-09]}} =
               Content.get_comparison_by_slug("google-analytics")

      assert {:ok, %{lastmod: ~D[2026-08-31]}} = Content.get_page_by_path("/")
      assert {:ok, %{lastmod: ~D[2026-08-19]}} = Content.get_guide_by_path("/monitoring/uptime")
    end

    test "the home page omits empty FAQ structured data", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)
      assert html =~ "application/ld+json"
      assert html =~ "SoftwareApplication"
      refute html =~ "FAQPage"
    end

    test "the pricing JSON-LD parses and contains the one monthly offer", %{conn: conn} do
      html = html_response(get(conn, ~p"/pricing"), 200)

      graphs =
        Regex.scan(~r{<script type="application/ld\+json">\s*(.*?)\s*</script>}s, html,
          capture: :all_but_first
        )
        |> Enum.map(fn [json] -> Jason.decode!(json) end)

      software_application = Enum.find(graphs, &Map.has_key?(&1, "@graph"))
      assert software_application

      software_node =
        Enum.find(software_application["@graph"], &(&1["@type"] == "SoftwareApplication"))

      offers = software_node["offers"]

      assert [%{"name" => "PostDeploy monthly", "unitText" => "MONTH", "price" => price}] = offers
      assert price == "#{div(Package.price_usd_cents(), 100)}"
    end
  end

  describe "sitemap.xml" do
    test "lists every published page and no /dashboard/ URL", %{conn: conn} do
      conn = get(conn, ~p"/sitemap.xml")
      body = response(conn, 200)
      assert ["application/xml" <> _] = get_resp_header(conn, "content-type")

      assert body =~ "<loc>https://postdeploy.dev/</loc>"
      assert body =~ "<loc>https://postdeploy.dev/pricing</loc>"
      assert body =~ "<loc>https://postdeploy.dev/free-uptime-monitoring</loc>"
      assert body =~ "<loc>https://postdeploy.dev/alternatives/cronitor</loc>"
      refute body =~ "/dashboard"
    end

    test "includes the stable first-party changelog and emits XML-escaped locations", %{
      conn: conn
    } do
      slug = "xml-escaping-#{System.unique_integer([:positive])}"
      path = "/#{slug}/a&b"

      assert {:ok, _page} =
               Content.create_page(
                 %{
                   slug: slug,
                   path: path,
                   title: "XML escaping test page",
                   meta_description: "A test page for escaped sitemap locations.",
                   summary: "A test page for escaped sitemap locations.",
                   lastmod: ~D[2026-08-31],
                   group: "core",
                   priority: "0.8",
                   status: "published",
                   cluster: "other",
                   intent: "informational",
                   primary_query: "test xml escaping query #{slug}"
                 },
                 authorize?: false
               )

      body = conn |> get(~p"/sitemap.xml") |> response(200)

      assert body =~ "<loc>https://postdeploy.dev/changelog</loc>"
      assert body =~ "<loc>https://postdeploy.dev#{String.replace(path, "&", "&amp;")}</loc>"
      refute body =~ "<loc>https://postdeploy.dev#{path}</loc>"
      assert {_document, _rest} = :xmerl_scan.string(String.to_charlist(body))
    end
  end

  describe "robots.txt" do
    setup %{conn: conn} do
      %{body: response(get(conn, "/robots.txt"), 200)}
    end

    test "disallows /dashboard/", %{body: body} do
      assert body =~ "Disallow: /dashboard/"
      assert body =~ "Sitemap: https://postdeploy.dev/sitemap.xml"
    end

    test "keeps auth screens out of the index", %{body: body} do
      # They have no unique content to rank for, and a sign-in form
      # outranking a guide is a worse result for everyone.
      for path <- ["/sign-in", "/register", "/reset", "/auth/"] do
        assert body =~ "Disallow: #{path}"
      end
    end

    test "keeps private and token-bearing screens out of the index", %{body: body} do
      for path <- ["/dashboard", "/admin", "/oauth/authorize", "/share/", "/invitations/"] do
        assert body =~ "Disallow: #{path}"
      end
    end

    test "every agent block carries the same rules", %{body: body} do
      # The blocks are generated from one list precisely so a rule cannot be
      # added to `*` and silently missed for the AI crawlers.
      agent_count = body |> String.split("User-agent:") |> length() |> Kernel.-(1)

      assert agent_count == 11

      for rule <- [
            "/dashboard/",
            "/dashboard",
            "/sign-in",
            "/register",
            "/reset",
            "/auth/",
            "/admin",
            "/oauth/authorize",
            "/share/",
            "/invitations/"
          ] do
        occurrences =
          body |> String.split("Disallow: #{rule}\n") |> length() |> Kernel.-(1)

        assert occurrences == agent_count,
               "#{rule} appears #{occurrences} times, expected once per agent block"
      end
    end

    test "AI answer engines are still explicitly allowed", %{body: body} do
      for agent <- ["GPTBot", "OAI-SearchBot", "ClaudeBot", "PerplexityBot", "Google-Extended"] do
        assert body =~ "User-agent: #{agent}"
      end

      refute body =~ ~r/User-agent: GPTBot\nDisallow: \/$/m
    end
  end

  describe "llms.txt" do
    test "lists pages and states the package from the enforced package", %{conn: conn} do
      conn = get(conn, ~p"/llms.txt")
      body = response(conn, 200)
      assert body =~ "postdeploy.dev/"

      assert body =~ "PostDeploy is a project-based reliability toolkit"
      refute body =~ "for one project"

      plan = Package.get()
      assert body =~ "#{Package.trial_days()}-day free trial with no card"

      assert body =~
               "- #{plan.name}: $#{div(plan.price.amount_usd_cents, 100)}/month, billed monthly."

      assert body =~ "#{plan.limits.uptime_monitors} uptime monitors"

      refute body =~ "- Trial:"
    end

    test "states all three pillars are live, not 'in development'", %{conn: conn} do
      conn = get(conn, ~p"/llms.txt")
      body = response(conn, 200)
      refute body =~ "in development"
      assert body =~ "Monitor (uptime + heartbeats), Observe (error tracking) and Measure"
    end
  end

  describe "excluded features are never promised on public pages" do
    test "the pricing page states the public page allowance directly", %{conn: conn} do
      html = html_response(get(conn, ~p"/pricing"), 200)
      assert html =~ "Public pages"
      assert html =~ "No page-count limit"
    end

    test "the home page never claims Observe or Measure are unshipped", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)
      refute html =~ "in development"
    end

    test "the home page names the shipped public status page", %{conn: conn} do
      html = html_response(get(conn, ~p"/"), 200)
      [main] = Regex.run(~r{<main[^>]*>(.*)</main>}s, html, capture: :all_but_first)

      assert main =~ ~r/status page/i
    end

    test "the free-uptime-monitoring guide never mentions status pages", %{conn: conn} do
      conn = get(conn, ~p"/free-uptime-monitoring")
      refute html_response(conn, 200) =~ "status page"
    end

    test "the free-cron-job-monitoring guide never mentions status pages", %{conn: conn} do
      conn = get(conn, ~p"/free-cron-job-monitoring")
      refute html_response(conn, 200) =~ "status page"
    end

    test "no alternatives comparison claims PostDeploy offers status pages", %{conn: _conn} do
      for slug <-
            ~w(cronitor uptimerobot healthchecks-io better-stack plausible fathom google-analytics) do
        conn = get(build_conn(), ~p"/alternatives/#{slug}")
        html = html_response(conn, 200)

        refute html =~ "PostDeploy includes",
               "#{slug} page still claims PostDeploy includes a status page"
      end
    end
  end

  describe "product-language consistency" do
    test "the pricing page calls organization members 'Members', not 'team seats'", %{
      conn: conn
    } do
      conn = get(conn, ~p"/pricing")
      html = html_response(conn, 200)
      refute html =~ "team seat"
      assert html =~ "Members"
    end
  end

  describe "homepage switches" do
    test "the default render selects 24h, the Uptime tile and the 7d traffic range",
         %{conn: conn} do
      html = html_response(get(conn, ~p"/"), 200)

      assert current_label(html, "#console-preview-ranges") == "24h"
      assert current_label(html, "#home-metrics") =~ "Uptime"
      assert current_label(html, "#home-measure-ranges") == "7d"
    end

    test "a range or a metric in the query string moves the selection", %{conn: _conn} do
      html = html_response(get(build_conn(), "/?range=7d"), 200)

      assert current_label(html, "#console-preview-ranges") == "7d"
      assert current_label(html, "#home-metrics") =~ "Uptime"

      html = html_response(get(build_conn(), "/?metric=response"), 200)

      assert current_label(html, "#console-preview-ranges") == "24h"
      assert current_label(html, "#home-metrics") =~ "Response"
      refute current_label(html, "#home-metrics") =~ "Uptime"
    end

    test "the traffic range switches the Measure card on its own", %{conn: _conn} do
      html = html_response(get(build_conn(), "/?traffic=30d"), 200)

      assert current_label(html, "#home-measure-ranges") == "30d"
      assert current_label(html, "#console-preview-ranges") == "24h"
    end

    test "a switch changes one selection and leaves the other three alone",
         %{conn: _conn} do
      # The controls do not write to the URL, but the URL still seeds the
      # projection on mount, so a deep link into a selection keeps working.
      html =
        html_response(get(build_conn(), "/?range=30d&metric=traffic&monitor=0&traffic=30d"), 200)

      assert current_label(html, "#console-preview-ranges") == "30d"
      assert current_label(html, "#home-metrics") =~ "Traffic"
      assert current_label(html, "#home-measure-ranges") == "30d"

      # One pressed control per group. Two would leave a reader unable to tell
      # which selection the chart below is actually drawing.
      for group <- ["#console-preview-ranges", "#home-metrics", "#home-measure-ranges"] do
        assert pressed_count(html, group) == 1, "#{group} does not mark exactly one selection"
      end

      # Each group carries its own event, so moving the traffic range cannot
      # silently redraw the overview chart above it.
      for {group, event} <- [
            {"#console-preview-ranges", "select_overview_range"},
            {"#home-metrics", "select_metric"},
            {"#home-measure-ranges", "select_traffic_range"}
          ] do
        events = attributes(html, group <> " button", "phx-click")
        assert events != [], "no switch controls under #{group}"
        assert Enum.uniq(events) == [event]
      end
    end

    test "garbage switch parameters still render and fall back to the defaults",
         %{conn: _conn} do
      html =
        html_response(
          get(build_conn(), "/?range=999d&metric=../x&monitor=abc&traffic=7%20OR%201=1"),
          200
        )

      assert current_label(html, "#console-preview-ranges") == "24h"
      assert current_label(html, "#home-metrics") =~ "Uptime"
      assert current_label(html, "#home-measure-ranges") == "7d"
      refute html =~ "999d"
      refute html =~ "OR 1=1"
    end

    test "each metric draws its own chart kind and screen-reader table", %{conn: _conn} do
      set_preview_flag(true)

      for {metric, kind} <- [
            {"uptime", :ticks},
            {"response", :bars},
            {"traffic", :wave},
            {"errors", :bars}
          ] do
        chart = HomepageData.load(%{"metric" => metric}).overview.chart
        html = html_response(get(build_conn(), "/?metric=#{metric}"), 200)
        panel = fragment_html(html, "#console-preview-panel-monitor")

        assert chart.kind == kind, "#{metric} projected #{inspect(chart.kind)}"
        assert chart.points != [], "#{metric} projected no points"

        case kind do
          :ticks -> assert panel =~ "rounded-tick"
          :bars -> assert panel =~ "rounded-t-[4px]"
          :wave -> assert panel =~ "<svg"
        end

        assert panel =~ chart.table_caption
        assert panel =~ ~s(<th scope="col">#{chart.column_label}</th>)
      end
    end

    test "the switches are live controls with a real target size", %{conn: conn} do
      html = html_response(get(conn, ~p"/"), 200)
      [main] = Regex.run(~r{<main[^>]*>(.*)</main>}s, html, capture: :all_but_first)

      assert Regex.scan(~r{<h1\b}, main) |> length() == 1
      refute main =~ ~s(role="img")
      refute main =~ ~r/\b(?:bg|text|border|fill|stroke)-\[#/
      refute main =~ ~r/[\x{2014}\x{2013}\x{00B7}]/u

      for selector <- [
            "#console-preview-ranges",
            "#home-metrics",
            "#home-measure-ranges"
          ] do
        classes = attributes(html, selector <> " button", "class")
        assert classes != [], "no switch controls under #{selector}"

        for class <- classes do
          assert class =~ "min-h-target-min", "#{selector} control is under the target size"
        end

        # A control that redraws the page in place is a button, never a link.
        assert attributes(html, selector <> " button", "type") |> Enum.uniq() == ["button"]
        assert attributes(html, selector <> " a", "href") == []
      end
    end
  end

  # The homepage switches are LiveView controls, not links: `aec64640` moved
  # the selection off the URL deliberately. Selection is therefore expressed
  # with `aria-pressed` on a button, which is the correct role for a control
  # that changes the page in place rather than navigating.
  defp current_label(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector <> ~s( button[aria-pressed="true"]))
    |> LazyHTML.text()
    |> String.trim()
  end

  # Exactly one control in a group may report itself as pressed.
  defp pressed_count(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector <> ~s( button[aria-pressed="true"]))
    |> Enum.count()
  end

  defp attributes(html, selector, name) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
  end

  defp fragment_html(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.to_html()
  end

  defp set_preview_flag(value) do
    previous = Application.get_env(:alplus, :homepage_preview_when_unconfigured)
    Application.put_env(:alplus, :homepage_preview_when_unconfigured, value)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:alplus, :homepage_preview_when_unconfigured)
      else
        Application.put_env(:alplus, :homepage_preview_when_unconfigured, previous)
      end
    end)
  end
end
