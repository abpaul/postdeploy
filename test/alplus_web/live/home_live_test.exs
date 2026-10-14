defmodule AlplusWeb.HomeLiveTest do
  @moduledoc """
  The marketing homepage as a LiveView (ARCHITECTURE.md §9).

  Two contracts are tested together here, because the page has to keep both:
  the connected view switches the project overview in place without changing
  the URL, and the dead render still carries a complete, indexable page for a
  crawler that never opens a socket.

  `async: false`, and the preview flag plus `Alplus.Measure.PublicCache` are
  reset per test: both are process-wide, and the interaction tests need the
  deterministic preview projection so a click has a known before and after.
  """

  use AlplusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Alplus.Content.Seeds
  alias Alplus.Measure.PublicCache
  alias AlplusWeb.Marketing.HomepageData

  setup do
    :ok = Seeds.run()
    PublicCache.clear()
    :ok
  end

  defp use_preview_data do
    previous = Application.get_env(:alplus, :homepage_preview_when_unconfigured)
    Application.put_env(:alplus, :homepage_preview_when_unconfigured, true)
    PublicCache.clear()

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:alplus, :homepage_preview_when_unconfigured)
      else
        Application.put_env(:alplus, :homepage_preview_when_unconfigured, previous)
      end

      PublicCache.clear()
    end)
  end

  defp current_label(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector <> ~s( button[aria-pressed="true"]))
    |> LazyHTML.text()
    |> String.trim()
  end

  defp refute_query_hrefs(view) do
    refute has_element?(view, ~s(#console-preview-ranges a[href*="?"]))
    refute has_element?(view, ~s(#home-metrics a[href*="?"]))
    refute has_element?(view, ~s(nav[aria-label="Published monitor"] a[href*="?"]))
    refute has_element?(view, ~s(#home-measure-ranges a[href*="?"]))
  end

  describe "mount" do
    test "an anonymous visitor mounts with the default selection", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      assert current_label(html, "#console-preview-ranges") == "24h"
      assert current_label(html, "#home-metrics") =~ "Uptime"
      assert current_label(html, "#home-measure-ranges") == "7d"

      # No session, no user: the hero and the final CTA point at registration.
      assert has_element?(view, ~s(#home-hero-cta[href="/register"]))
    end

    test "a signed-in visitor mounts with their user over the socket", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> AshAuthentication.Plug.Helpers.store_in_session(Alplus.OrgsFixtures.user_fixture())

      {:ok, view, _html} = live(conn, "/")

      # `on_mount {AlplusWeb.LiveUserAuth, :current_user}` reads the session
      # signed into the connect token, so the connected mount sees the same
      # user the dead render did and every CTA still aims at the console.
      assert has_element?(view, ~s(#home-hero-cta[href="/dashboard"]))
      refute has_element?(view, ~s(a[href="/register"]))
    end

    test "hostile switch parameters mount cleanly on the default selection", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, "/?range=999d&metric=../x&monitor=abc&traffic=7+OR+1%3D1")

      assert current_label(html, "#console-preview-ranges") == "24h"
      assert current_label(html, "#home-metrics") =~ "Uptime"
      assert current_label(html, "#home-measure-ranges") == "7d"
      refute html =~ "999d"
      refute html =~ "OR 1=1"
    end

    test "the supplied URL selects errors once without becoming control hrefs", %{conn: conn} do
      {:ok, view, html} =
        live(conn, "/?range=24h&metric=errors&monitor=0&traffic=7d")

      assert current_label(html, "#console-preview-ranges") == "24h"
      assert current_label(html, "#home-metrics") =~ "Errors"
      assert current_label(html, "#home-measure-ranges") == "7d"

      updated = view |> element("#console-preview-ranges button", "7d") |> render_click()

      refute_patched(view)
      assert current_label(updated, "#console-preview-ranges") == "7d"
      assert current_label(updated, "#home-metrics") =~ "Errors"
      refute_query_hrefs(view)
    end
  end

  describe "switching in place" do
    setup do
      use_preview_data()
      :ok
    end

    test "a range pill redraws the chart without patching the URL", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      assert current_label(html, "#console-preview-ranges") == "24h"
      assert html =~ "1,440 checks, every one passed"

      updated = view |> element("#console-preview-ranges button", "7d") |> render_click()

      refute_patched(view)
      assert current_label(updated, "#console-preview-ranges") == "7d"
      assert updated =~ "Every day reported full uptime"
      refute updated =~ "1,440 checks, every one passed"
      refute_query_hrefs(view)
    end

    test "a metric tile switches the chart kind", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      # Uptime draws ticks; traffic draws the wave.
      assert html =~ "rounded-tick"
      refute html =~ ~s(viewBox="0 0 100 40")

      updated = view |> element("#home-metrics button", "Traffic") |> render_click()

      refute_patched(view)
      assert current_label(updated, "#home-metrics") =~ "Traffic"
      assert updated =~ ~s(viewBox="0 0 100 40")
      assert updated =~ "Pageviews per hour"
      refute_query_hrefs(view)
    end

    test "a monitor row switches the detail card", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      assert html =~ "Average response for Example API, milliseconds for each hour"

      patched =
        view
        |> element(~s(nav[aria-label="Published monitor"] button), "Example site")
        |> render_click()

      refute_patched(view)
      assert patched =~ "Average response for Example site, milliseconds for each hour"
      refute patched =~ "Recent checks for Example API, oldest first."
      refute_query_hrefs(view)
    end

    test "a Measure range changes the traffic figures", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      seven_day = HomepageData.load(%{"traffic" => "7d"}).metrics.measure.value
      fortnight = HomepageData.load(%{"traffic" => "14d"}).metrics.measure.value
      refute seven_day == fortnight

      assert current_label(html, "#home-measure-ranges") == "7d"
      assert html =~ seven_day
      assert html =~ "Pageviews and visitors by day for the last 7 days."

      updated = view |> element("#home-measure-ranges button", "14d") |> render_click()

      refute_patched(view)
      assert current_label(updated, "#home-measure-ranges") == "14d"
      assert updated =~ fortnight
      assert updated =~ "Pageviews and visitors by day for the last 14 days."
      refute_query_hrefs(view)
    end
  end

  describe "the dead render" do
    test "carries the JSON-LD graph, the canonical link and the meta description",
         %{conn: conn} do
      html = html_response(get(conn, ~p"/"), 200)

      assert length(Regex.scan(~r|<script type="application/ld\+json">|, html)) == 1

      [json] =
        Regex.run(~r|<script type="application/ld\+json">\s*(.*?)\s*</script>|s, html,
          capture: :all_but_first
        )

      graph = Jason.decode!(json)
      assert graph["@context"] == "https://schema.org"

      organization = Enum.find(graph["@graph"], &(&1["@type"] == "Organization"))
      website = Enum.find(graph["@graph"], &(&1["@type"] == "WebSite"))
      software = Enum.find(graph["@graph"], &(&1["@type"] == "SoftwareApplication"))

      assert organization["@id"] == "https://postdeploy.dev/#organization"
      refute Map.has_key?(organization, "sameAs")

      assert website["@id"] == "https://postdeploy.dev/#website"
      assert website["name"] == "PostDeploy"
      assert website["url"] == "https://postdeploy.dev/"
      assert website["publisher"] == %{"@id" => "https://postdeploy.dev/#organization"}

      assert software["@id"] == "https://postdeploy.dev/#software"
      assert software["url"] == "https://postdeploy.dev/"
      refute Map.has_key?(software, "offers")

      refute html =~ ~s("@type":"FAQPage")
      assert html =~ ~s(<link rel="canonical" href="https://postdeploy.dev/">)

      assert html =~
               ~s(<meta name="description" content="Uptime checks, cron heartbeats, error tracking and cookieless analytics in one project.)

      # The whole page, not a socket-shaped shell.
      assert html =~ "<h1"
      assert html =~ ~s(id="console-preview")
      assert html =~ ~s(id="measure")
      assert html =~ ~s(id="home-final-cta")
    end

    test "places the founder letter once in the hero with its profile links", %{conn: conn} do
      document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

      assert document |> LazyHTML.query("#founder-letter") |> Enum.count() == 1

      hrefs =
        document
        |> LazyHTML.query("#leadspace #founder-letter a")
        |> LazyHTML.attribute("href")

      for href <- [
            "https://crabgate.com",
            "https://keysend.app",
            "https://www.linkedin.com/in/paulbpa/",
            "https://github.com/abpaul",
            "https://badarau.net"
          ] do
        assert href in hrefs
      end
    end

    test "switches render as buttons without query-string hrefs", %{conn: conn} do
      html = html_response(get(conn, "/?range=30d&metric=traffic&monitor=0&traffic=30d"), 200)

      document = LazyHTML.from_document(html)

      assert document
             |> LazyHTML.query(
               "#console-preview-ranges button, #home-metrics button, #home-measure-ranges button"
             )
             |> Enum.count() == 10

      assert document
             |> LazyHTML.query(
               "#console-preview-ranges a[href*='?'], #home-metrics a[href*='?'], #home-measure-ranges a[href*='?']"
             )
             |> Enum.empty?()
    end
  end

  describe "chart colour" do
    setup do
      Alplus.Measure.PublicCache.clear()
      on_exit(&Alplus.Measure.PublicCache.clear/0)
      :ok
    end

    test "uptime uses the operational palette and response uses the brand", %{conn: conn} do
      uptime = html_response(get(conn, ~p"/?metric=uptime"), 200)
      response = html_response(get(conn, ~p"/?metric=response"), 200)
      errors = html_response(get(conn, ~p"/?metric=errors"), 200)

      uptime_chart = chart_markup(uptime)
      response_chart = chart_markup(response)
      errors_chart = chart_markup(errors)

      refute uptime_chart =~ "bg-interactive-primary",
             "uptime is operational state, so it never carries the brand colour"

      refute response_chart =~ "bg-status-live",
             "response time is a measurement, so it never carries the operational colour"

      refute errors_chart =~ "bg-status-live"
      refute errors_chart =~ "bg-interactive-primary"
    end
  end

  defp chart_markup(html) do
    [markup] =
      Regex.run(~r/id="console-preview-panel-monitor".*?<\/div>\s*<div class="flex/s, html)

    markup
  end
end
