defmodule AlplusWeb.ErrorTrackingPageTest do
  @moduledoc """
  The Observe pillar hub, `/error-tracking` (SITE-ARCHITECTURE.md §6, W1,
  issue #49). Mirrors `AlplusWeb.MonitoringClusterTest`'s shape for the
  monitoring cluster: routing, sitemap presence, breadcrumb/canonical
  plumbing, and the specific claims the page must make or must not make.
  """

  use AlplusWeb.ConnCase, async: true

  alias Alplus.Billing.Package
  alias AlplusWeb.Marketing.PackagePresenter

  setup do
    Alplus.Content.Seeds.run()
    :ok
  end

  test "renders 200 with a title, meta description and heading", %{conn: conn} do
    conn = get(conn, "/error-tracking")
    html = html_response(conn, 200)

    assert html =~ "<h1"
    assert html =~ ~s(name="description")
    assert html =~ "Error tracking for small software teams"
  end

  test "covers grouping and triage, releases, and sourcemap symbolication", %{conn: conn} do
    html = html_response(get(conn, "/error-tracking"), 200)

    assert html =~ "Grouping and triage"
    assert html =~ "Releases"
    assert html =~ "Sourcemap symbolication"
  end

  test "the Indie error allowance is read from the plan registry", %{conn: conn} do
    html = html_response(get(conn, "/error-tracking"), 200)

    expected = PackagePresenter.thousands(Package.limit(:error_events_per_month))

    assert html =~ expected
  end

  test "states the four capabilities Observe does not offer", %{conn: conn} do
    html = html_response(get(conn, "/error-tracking"), 200)

    assert html =~ "does not ingest logs"
    assert html =~ "does not collect traces"
    assert html =~ "does not compute metrics"
    assert html =~ "does not record session replay"
  end

  test "claims no status page", %{conn: conn} do
    html = html_response(get(conn, "/error-tracking"), 200)

    refute html =~ ~r/status page/i
  end

  test "avoids the banned marketing wording", %{conn: conn} do
    html = html_response(get(conn, "/error-tracking"), 200)

    for banned <- [
          "observability platform",
          "APM",
          "full-stack",
          "enterprise-grade",
          "world-class",
          "global network",
          "unlimited",
          "overage",
          "goal conversions",
          "SLA"
        ] do
      refute html =~ banned, "found banned wording: #{banned}"
    end
  end

  test "the body links pricing once and shows one trial action near the title",
       %{
         conn: conn
       } do
    html = html_response(get(conn, "/error-tracking"), 200)
    [main] = Regex.run(~r{<main[^>]*>(.*)</main>}s, html, capture: :all_but_first)

    assert Regex.scan(~r{href="/pricing"}, main) |> length() == 1
    assert Regex.scan(~r{href="/register"}, main) |> length() == 1
    assert Regex.scan(~r{>\s*Start your 14-day free trial\s*<}, main) |> length() == 1
  end

  test "is listed in the sitemap with the production canonical", %{conn: conn} do
    sitemap = response(get(conn, "/sitemap.xml"), 200)

    assert sitemap =~ "<loc>https://postdeploy.dev/error-tracking</loc>"
  end

  test "emits a canonical URL pinned to the production origin", %{conn: conn} do
    html = html_response(get(conn, "/error-tracking"), 200)

    assert html =~ ~s(rel="canonical" href="https://postdeploy.dev/error-tracking")
  end

  test "renders the Home > Error tracking breadcrumb with BreadcrumbList JSON-LD", %{conn: conn} do
    html = html_response(get(conn, "/error-tracking"), 200)

    assert html =~ ~s("@type":"BreadcrumbList")
    assert html =~ ~s("name":"Error tracking")
    assert html =~ ~s("item":"https://postdeploy.dev/error-tracking")
  end

  test "the header lists Product and the Product footer column still links Error tracking" do
    assert {"Product", "/#product"} in AlplusWeb.MarketingComponents.header_links()

    {"Product", product_links} =
      Enum.find(AlplusWeb.MarketingComponents.footer_columns(), fn {title, _} ->
        title == "Product"
      end)

    assert {"Error tracking", "/error-tracking"} in product_links
  end
end
