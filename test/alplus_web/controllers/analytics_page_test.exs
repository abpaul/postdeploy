defmodule AlplusWeb.AnalyticsPageTest do
  @moduledoc """
  The Measure pillar hub, `/analytics` (SITE-ARCHITECTURE.md §6, W1, issue
  #52). Mirrors `AlplusWeb.ErrorTrackingPageTest`'s shape for the Observe
  pillar: routing, sitemap presence, breadcrumb/canonical plumbing, and the
  specific claims the page must make or must not make.
  """

  use AlplusWeb.ConnCase, async: true

  alias Alplus.Billing.Package
  alias AlplusWeb.Marketing.PackagePresenter

  @copy_runtime_fixture Path.expand("../../fixtures/static_copy_runtime.mjs", __DIR__)
  @external_resource @copy_runtime_fixture

  setup do
    Alplus.Content.Seeds.run()
    :ok
  end

  test "renders 200 with a title, meta description and heading", %{conn: conn} do
    conn = get(conn, "/analytics")
    html = html_response(conn, 200)

    assert html =~ "<h1"
    assert html =~ ~s(name="description")
    assert html =~ "Privacy-first analytics for small software teams"
  end

  test "covers pageviews and custom events", %{conn: conn} do
    html = html_response(get(conn, "/analytics"), 200)

    assert html =~ "pageviews"
    assert html =~ "custom events"
  end

  test "renders copyable installation and named-event examples through the public page", %{
    conn: conn
  } do
    document =
      conn
      |> get("/analytics")
      |> html_response(200)
      |> LazyHTML.from_document()

    install = LazyHTML.query(document, "#marketing-code-install-measure-on-your-site")
    event = LazyHTML.query(document, "#marketing-code-count-a-named-action")

    assert install
           |> LazyHTML.query("code")
           |> LazyHTML.text() =~ "window.postdeployMeasure = window.postdeployMeasure || []"

    assert install
           |> LazyHTML.query("code")
           |> LazyHTML.text() =~ "/m.js?token=YOUR_MEASURE_TOKEN&v=20260910"

    assert event
           |> LazyHTML.query("code")
           |> LazyHTML.text() ==
             ~s|window.postdeployMeasure.push(["event", "clicked_checkout"]);|

    assert LazyHTML.attribute(LazyHTML.query(install, "button[data-target]"), "data-target") ==
             ["marketing-code-install-measure-on-your-site-code"]

    assert LazyHTML.attribute(LazyHTML.query(event, "button[data-target]"), "data-target") ==
             ["marketing-code-count-a-named-action-code"]
  end

  test "the static page copies code and reports copy outcomes", %{conn: conn} do
    node =
      System.find_executable("node") ||
        flunk("node is required for the static copy runtime fixture")

    html = html_response(get(conn, "/analytics"), 200)

    {output, 0} =
      System.cmd(node, [@copy_runtime_fixture, Base.encode64(html)], stderr_to_stdout: true)

    assert Jason.decode!(output) == %{
             "copied" => ["window.postdeployMeasure.push(['event', 'saved']);"],
             "copiedLabel" => "Copied",
             "failedLabel" => "Copy failed",
             "liveViewLabel" => "Copy",
             "missingLabel" => "Copy"
           }
  end

  test "describes the privacy claims: no cookies, no raw IP, no persistent identifier, daily-rotating salted HMAC",
       %{conn: conn} do
    html = html_response(get(conn, "/analytics"), 200)

    assert html =~ "no cookies"
    assert html =~ "no raw IP address"
    assert html =~ "no persistent visitor identifier"
    assert html =~ "salt"
    assert html =~ "rotates every day"
  end

  test "the Indie analytics allowance is read from the plan registry", %{conn: conn} do
    html = html_response(get(conn, "/analytics"), 200)

    expected = PackagePresenter.thousands(Package.limit(:analytics_events_per_month))

    assert html =~ expected
  end

  test "states plainly that goals are not offered", %{conn: conn} do
    html = html_response(get(conn, "/analytics"), 200)

    assert html =~ "goals are not evaluated or displayed"
  end

  test "names no competitor and uses no banned wording", %{conn: conn} do
    html = html_response(get(conn, "/analytics"), 200)

    refute html =~ ~r/fathom/i
    refute html =~ ~r/plausible/i
    refute html =~ ~r/google analytics/i
    refute html =~ ~r/status page/i

    for banned <- [
          "observability platform",
          "APM",
          "full-stack",
          "enterprise-grade",
          "world-class",
          "global network",
          "edge",
          "unlimited",
          "overage",
          "goal conversions",
          "SLA"
        ] do
      refute html =~ banned, "found banned wording: #{banned}"
    end
  end

  test "the body links pricing and privacy once and shows one trial action near the title",
       %{conn: conn} do
    html = html_response(get(conn, "/analytics"), 200)
    [main] = Regex.run(~r{<main[^>]*>(.*)</main>}s, html, capture: :all_but_first)

    assert Regex.scan(~r{href="/pricing"}, main) |> length() == 1
    assert Regex.scan(~r{href="/privacy"}, main) |> length() == 1
    assert Regex.scan(~r{href="/register"}, main) |> length() == 1
    assert Regex.scan(~r{>\s*Start your 14-day free trial\s*<}, main) |> length() == 1
  end

  test "is listed in the sitemap with the production canonical", %{conn: conn} do
    sitemap = response(get(conn, "/sitemap.xml"), 200)

    assert sitemap =~ "<loc>https://postdeploy.dev/analytics</loc>"
  end

  test "emits a canonical URL pinned to the production origin", %{conn: conn} do
    html = html_response(get(conn, "/analytics"), 200)

    assert html =~ ~s(rel="canonical" href="https://postdeploy.dev/analytics")
  end

  test "renders the Home > Analytics breadcrumb with BreadcrumbList JSON-LD", %{conn: conn} do
    html = html_response(get(conn, "/analytics"), 200)

    assert html =~ ~s("@type":"BreadcrumbList")
    assert html =~ ~s("name":"Analytics")
    assert html =~ ~s("item":"https://postdeploy.dev/analytics")
  end

  test "the header lists Product and the Product footer column still links Analytics" do
    assert {"Product", "/#product"} in AlplusWeb.MarketingComponents.header_links()

    {"Product", product_links} =
      Enum.find(AlplusWeb.MarketingComponents.footer_columns(), fn {title, _} ->
        title == "Product"
      end)

    assert {"Analytics", "/analytics"} in product_links
  end
end
