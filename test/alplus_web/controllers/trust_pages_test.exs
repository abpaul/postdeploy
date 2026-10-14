defmodule AlplusWeb.TrustPagesTest do
  @moduledoc """
  `/about` and `/terms` (SITE-ARCHITECTURE.md §6, W1, issue #51). Both are
  `Content.Guide` rows rendered by `PageController.about/2` and
  `PageController.terms/2`, mirroring `/privacy`'s shape. Footer Company
  column only, never the header.
  """

  use AlplusWeb.ConnCase, async: true

  alias Alplus.Billing.Package

  setup do
    Alplus.Content.Seeds.run()
    :ok
  end

  describe "/about" do
    test "renders 200 with a title, meta description and heading", %{conn: conn} do
      html = html_response(get(conn, "/about"), 200)

      assert html =~ "<h1"
      assert html =~ ~s(name="description")
    end

    test "links /alternatives as the comparison path, with no removed endpoint", %{conn: conn} do
      html = html_response(get(conn, "/about"), 200)

      assert html =~ ~s(href="/alternatives")
      refute html =~ "product-facts.json"
    end

    test "ends with one trial call to action to /register", %{conn: conn} do
      html = html_response(get(conn, "/about"), 200)
      [main] = Regex.run(~r{<main[^>]*>(.*)</main>}s, html, capture: :all_but_first)
      cta = "Start your #{Package.trial_days()}-day free trial"

      assert Regex.scan(~r{href="/register"}, main) |> length() == 1
      assert main =~ ~r{>\s*#{Regex.escape(cta)}\s*<}
    end

    test "uses no banned wording and no hedging adverbs", %{conn: conn} do
      html = html_response(get(conn, "/about"), 200)

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

      [main] = Regex.run(~r{<main[^>]*>(.*)</main>}s, html, capture: :all_but_first)

      for adverb <- ["actually", "really", "very"] do
        refute main =~ ~r/\b#{adverb}\b/i, "found hedging adverb: #{adverb}"
      end
    end
  end

  describe "/terms" do
    test "renders 200 with a title, meta description and heading", %{conn: conn} do
      html = html_response(get(conn, "/terms"), 200)

      assert html =~ "<h1"
      assert html =~ ~s(name="description")
      assert html =~ "Terms of service"
    end

    test "names the provider, its registration number, contact and governing law", %{conn: conn} do
      html = html_response(get(conn, "/terms"), 200)
      [main] = Regex.run(~r{<main[^>]*>(.*)</main>}s, html, capture: :all_but_first)

      # A page that takes payment must say who is taking it. These four facts
      # are the ones a reader cannot look up anywhere else on the site.
      assert main =~ "ALPLUS TECHNOLOGIES SRL"
      assert main =~ "55013997"
      assert main =~ "hello@alplustech.com"
      assert main =~ "Romanian law governs these terms"
    end

    test "promises no service level and states the trial retention lifecycle", %{conn: conn} do
      html = html_response(get(conn, "/terms"), 200)
      [main] = Regex.run(~r{<main[^>]*>(.*)</main>}s, html, capture: :all_but_first)

      assert main =~ "does not promise a guaranteed level of uptime"
      refute main =~ "SLA"
      assert main =~ "#{Alplus.Billing.Package.trial_days()}-day free trial"
      assert main =~ "needs no credit card"
      assert main =~ "becomes read-only"

      assert main =~
               "Data is kept for #{Alplus.Billing.Package.inactive_retention_days()} more days and then purged"

      assert main =~
               "#{AlplusWeb.Marketing.PackagePresenter.price()} a month per organisation"

      assert main =~ "blocks the next create"
      refute main =~ "overage"
      assert main =~ "You can delete your account"
    end

    test "invents no legal entity, jurisdiction or registered address", %{conn: conn} do
      html = html_response(get(conn, "/terms"), 200)
      [main] = Regex.run(~r{<main[^>]*>(.*)</main>}s, html, capture: :all_but_first)

      refute main =~ ~r/\b(Inc\.|LLC|Ltd\.|GmbH)\b/
      refute main =~ ~r/governed by the laws of/i
      refute main =~ ~r/registered (office|address)/i
    end
  end

  describe "sitemap, canonicals and breadcrumbs" do
    test "both pages are listed in the sitemap with the production canonical", %{conn: conn} do
      sitemap = response(get(conn, "/sitemap.xml"), 200)

      assert sitemap =~ "<loc>https://postdeploy.dev/about</loc>"
      assert sitemap =~ "<loc>https://postdeploy.dev/terms</loc>"
    end

    test "both canonicals are pinned to the production origin", %{conn: conn} do
      about_html = html_response(get(conn, "/about"), 200)
      terms_html = html_response(get(conn, "/terms"), 200)

      assert about_html =~ ~s(rel="canonical" href="https://postdeploy.dev/about")
      assert terms_html =~ ~s(rel="canonical" href="https://postdeploy.dev/terms")
    end

    test "renders Home > About and Home > Terms with BreadcrumbList JSON-LD", %{conn: conn} do
      about_html = html_response(get(conn, "/about"), 200)
      terms_html = html_response(get(conn, "/terms"), 200)

      assert about_html =~ ~s("@type":"BreadcrumbList")
      assert about_html =~ ~s("name":"About")
      assert about_html =~ ~s("item":"https://postdeploy.dev/about")

      assert terms_html =~ ~s("@type":"BreadcrumbList")
      assert terms_html =~ ~s("name":"Terms")
      assert terms_html =~ ~s("item":"https://postdeploy.dev/terms")
    end
  end

  describe "navigation" do
    test "neither page appears in the header", %{conn: conn} do
      html = html_response(get(conn, "/"), 200)

      refute Enum.any?(AlplusWeb.MarketingComponents.header_links(), fn {_label, path} ->
               path in ["/about", "/terms"]
             end)

      [header] = Regex.run(~r{<header[^>]*>(.*?)</header>}s, html, capture: :all_but_first)
      refute header =~ ~s(href="/about")
      refute header =~ ~s(href="/terms")
    end

    test "the Company footer column reads About, Privacy, Terms, then the X profile" do
      {"Company", company_links} =
        Enum.find(AlplusWeb.MarketingComponents.footer_columns(), fn {title, _} ->
          title == "Company"
        end)

      assert company_links == [
               {"About", "/about"},
               {"Privacy", "/privacy"},
               {"Terms", "/terms"},
               {"@hasieratik on X", "https://x.com/hasieratik"}
             ]
    end

    test "both pages appear in the rendered Company footer column", %{conn: conn} do
      html = html_response(get(conn, "/"), 200)

      assert html =~ ~s(href="/about")
      assert html =~ ~s(href="/terms")
    end
  end
end
