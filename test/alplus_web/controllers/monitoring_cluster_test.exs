defmodule AlplusWeb.MonitoringClusterTest do
  @moduledoc """
  The monitoring search cluster and the high-intent heartbeat guides.

  `Alplus.Seo.AuditTest` already enforces the shared SEO standard across
  every public route, so these tests cover what is specific to this cluster:
  the routes resolve, the technical content a reader came for is actually
  present, the pages link to each other, and the contextual CTA is used.
  """

  use AlplusWeb.ConnCase, async: true

  alias Alplus.Billing.Package
  alias Alplus.Content
  alias AlplusWeb.Marketing.PackagePresenter

  @heartbeat_guide_paths [
    "/guides/github-actions-heartbeat",
    "/guides/kubernetes-cronjob-heartbeat",
    "/guides/heroku-scheduler-heartbeat",
    "/guides/systemd-timer-heartbeat",
    "/guides/laravel-scheduler-heartbeat",
    "/guides/airflow-heartbeat",
    "/guides/gitlab-ci-schedule-heartbeat"
  ]

  @cluster_paths [
    "/monitoring",
    "/monitoring/uptime",
    "/monitoring/cron-jobs",
    "/monitoring/api"
    | @heartbeat_guide_paths
  ]

  setup do
    Alplus.Content.Seeds.run()
    :ok
  end

  describe "routing" do
    test "every cluster page renders", %{conn: conn} do
      for path <- @cluster_paths do
        assert html_response(get(conn, path), 200) =~ "<h1"
      end
    end

    test "the heartbeat guide seed is idempotent" do
      :ok = Content.Seeds.run()
      {:ok, guides} = Content.list_guides()

      seeded_paths =
        guides
        |> Enum.map(& &1.path)
        |> Enum.filter(&(&1 in @heartbeat_guide_paths))

      assert Enum.sort(seeded_paths) == Enum.sort(@heartbeat_guide_paths)
      assert length(Enum.uniq(seeded_paths)) == length(@heartbeat_guide_paths)
    end

    test "an unknown slug 404s rather than rendering an empty page", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, "/monitoring/does-not-exist") end
      assert_error_sent 404, fn -> get(conn, "/guides/does-not-exist") end
    end

    test "every cluster page is in the sitemap", %{conn: conn} do
      sitemap = response(get(conn, "/sitemap.xml"), 200)

      for path <- @cluster_paths do
        assert sitemap =~ "<loc>https://postdeploy.dev#{path}</loc>"
      end
    end
  end

  describe "content usefulness" do
    # A guide has to solve the reader's problem even if they never sign up.
    # These assert the specific, checkable details that make that true.

    test "the GitHub Actions guide names the real failure modes and shows workflow YAML", %{
      conn: conn
    } do
      html = html_response(get(conn, "/guides/github-actions-heartbeat"), 200)

      # GitHub disables schedules in public repos after 60 days of inactivity.
      assert html =~ "60 days"
      assert html =~ "workflow_dispatch"
      assert html =~ "if: failure()"
      assert html =~ "secrets.POSTDEPLOY_HEARTBEAT_TOKEN"
      # A verification step, not just configuration.
      assert html =~ "202"
    end

    test "the Kubernetes guide names the missed-schedule limit and shows a manifest", %{
      conn: conn
    } do
      html = html_response(get(conn, "/guides/kubernetes-cronjob-heartbeat"), 200)

      # The controller stops scheduling after 100 missed start times.
      assert html =~ "100 missed start times"
      assert html =~ "startingDeadlineSeconds"
      assert html =~ "concurrencyPolicy"
      assert html =~ "kind: CronJob"
      assert html =~ "kubectl"
    end

    test "heartbeat examples point at the real ingest endpoint", %{conn: conn} do
      for path <- ["/monitoring/cron-jobs" | @heartbeat_guide_paths] do
        assert html_response(get(conn, path), 200) =~ "ingest.postdeploy.dev/h/"
      end
    end

    # SITE-ARCHITECTURE.md §8: a guide that carries a citation and a stated
    # non-capability must show both to a reader, not just store them.
    test "each heartbeat guide renders its source and stated product boundary", %{
      conn: conn
    } do
      for path <- @heartbeat_guide_paths do
        {:ok, guide} = Content.get_guide_by_path(path)
        html = html_response(get(conn, path), 200)

        assert guide.not_offered != []
        rendered_text = html |> LazyHTML.from_document() |> LazyHTML.text()

        for limit <- guide.not_offered do
          assert rendered_text =~ limit
        end

        for source <- guide.sources do
          assert html =~ ~s(href="#{source["url"]}")
          assert html =~ ~s(datetime="#{source["retrieved"]}")
        end
      end
    end

    test "the hub states what PostDeploy does not monitor", %{conn: conn} do
      html = html_response(get(conn, "/monitoring"), 200)

      # Publishing the gaps is what makes the rest of the page credible.
      assert html =~ "ICMP"
      refute html =~ ~r/status page/i
    end

    test "the hub derives trial limits from the Pro plan", %{conn: conn} do
      uptime_monitors = Package.limit(:uptime_monitors)
      cron_jobs = Package.limit(:cron_jobs)

      interval =
        PackagePresenter.interval_label(Package.limit(:min_check_interval_seconds))

      retention_days = Package.limit(:detailed_uptime_retention_days)

      html = html_response(get(conn, "/monitoring"), 200)

      assert html =~
               "#{uptime_monitors} uptime and API monitors and #{cron_jobs} cron and heartbeat jobs"

      assert html =~
               "with a #{interval} minimum check interval and #{retention_days} days of detailed check samples"
    end
  end

  describe "internal linking and conversion" do
    test "the hub links to every page in its cluster", %{conn: conn} do
      html = html_response(get(conn, "/monitoring"), 200)

      for path <- @cluster_paths -- ["/monitoring"] do
        assert html =~ ~s(href="#{path}"), "the hub does not link to #{path}"
      end
    end

    test "each cluster page links back into the cluster", %{conn: conn} do
      for path <- @cluster_paths -- ["/monitoring"] do
        assert html_response(get(conn, path), 200) =~ ~s(href="/monitoring)
      end
    end

    test "cluster pages expose one contextual trial action", %{conn: conn} do
      for path <- @cluster_paths do
        html = html_response(get(conn, path), 200)
        document = LazyHTML.from_document(html)

        close_selector =
          if String.starts_with?(path, "/guides/"), do: "#final-cta", else: "#guide-leadspace"

        close = LazyHTML.query(document, close_selector)
        assert LazyHTML.to_html(close) != "", "#{path} must keep its contextual close"

        trial_action = LazyHTML.query(close, ~s(a[href="/register"]))
        assert LazyHTML.attribute(trial_action, "href") == ["/register"]
      end
    end

    test "guides carry breadcrumbs through the guides index", %{conn: conn} do
      html = html_response(get(conn, "/guides/kubernetes-cronjob-heartbeat"), 200)

      assert html =~ ~s("name":"Guides")
      assert html =~ ~s("item":"https://postdeploy.dev/guides")
    end
  end

  describe "authorship and dating" do
    # PRD §16/§34. Guides make claims about third-party software, so a reader
    # needs to know who wrote it and when the external facts were checked.

    test "guides show a byline with published and verified dates", %{conn: conn} do
      for path <- @heartbeat_guide_paths do
        html = html_response(get(conn, path), 200)

        assert html =~ "By Paul"
        assert html =~ "last verified"
        # Machine-readable as well as visible.
        assert html =~ ~r/<time[^>]*datetime="\d{4}-\d{2}-\d{2}"/
      end
    end

    test "authored guides emit TechArticle schema matching the visible byline", %{conn: conn} do
      html = html_response(get(conn, "/guides/kubernetes-cronjob-heartbeat"), 200)

      assert html =~ ~s("@type":"TechArticle")
      assert html =~ ~s("name":"Paul")
      assert html =~ ~s("datePublished")
      assert html =~ ~s("dateModified")
    end

    test "commercial pages carry no byline and no Article schema", %{conn: conn} do
      # Inventing an author to satisfy a schema is the deceptive markup
      # Google's structured-data policies prohibit.
      for path <- ["/monitoring", "/monitoring/uptime", "/monitoring/api"] do
        html = html_response(get(conn, path), 200)

        refute html =~ "By Paul"
        refute html =~ "TechArticle"
      end
    end
  end

  describe "social preview metadata" do
    test "every cluster page carries an absolute og:image and a Twitter card", %{conn: conn} do
      for path <- @cluster_paths do
        html = html_response(get(conn, path), 200)

        assert html =~
                 ~s(<meta property="og:image" content="https://postdeploy.dev/images/og-default.png")

        assert html =~ ~s(<meta name="twitter:card" content="summary_large_image")
      end
    end
  end
end
