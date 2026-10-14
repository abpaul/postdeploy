defmodule AlplusWeb.MarketingPayloadTest do
  @moduledoc """
  Marketing pages must not ship the LiveView bundle (PRD §8).

  `app.js` bundles Phoenix, LiveView and the colocated hooks: roughly 147 KB
  minified, 46 KB gzipped. The console genuinely needs it. The marketing
  pages are server-rendered controllers with no `phx-*` bindings, so for a
  visitor arriving from search it is pure download and parse cost on the
  critical path, buying nothing.

  Two marketing routes are stated exceptions (ARCHITECTURE.md §9), and both
  need the bundle: `AlplusWeb.HomeLive`, whose four overview switches change
  one frame in place, and `AlplusWeb.WebsiteHealthCheckLive`, which runs a
  live HTTP check of up to ten seconds over the socket. `@marketing_paths`
  below is the list that must stay static, so neither path is in it, and the
  describes further down assert the opposite for both. That keeps each
  exception a stated one rather than a silent gap.

  The dangerous half of this change is the console, so it is tested here
  too: shipping a marketing optimisation that silently breaks the dashboard
  would be a far worse outcome than a slow landing page.
  """

  use AlplusWeb.ConnCase, async: true

  import Alplus.OrgsFixtures

  # `/` is deliberately absent: it is a LiveView and must ship the bundle.
  @marketing_paths [
    "/pricing",
    "/monitoring",
    "/monitoring/uptime",
    "/monitoring/cron-jobs",
    "/monitoring/api",
    "/guides/github-actions-heartbeat",
    "/guides/kubernetes-cronjob-heartbeat",
    "/privacy",
    "/alternatives",
    "/alternatives/cronitor",
    "/free-uptime-monitoring",
    "/free-cron-job-monitoring"
  ]

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  setup do
    Alplus.Content.Seeds.run()
    :ok
  end

  describe "marketing pages" do
    test "do not load the LiveView bundle", %{conn: conn} do
      for path <- @marketing_paths do
        html = html_response(get(conn, path), 200)

        refute html =~ "/assets/js/app.js",
               "#{path} still loads the LiveView bundle"
      end
    end

    test "still load the stylesheet and the inline theme script", %{conn: conn} do
      # Dropping the bundle must not drop styling, and the theme script is
      # inline so it survives independently.
      html = html_response(get(conn, "/monitoring"), 200)

      assert html =~ "/assets/css/app.css"
      assert html =~ "phx:theme"
    end

    test "use no phx-* bindings, which is why the bundle is unnecessary", %{conn: conn} do
      # If a marketing page ever needs LiveView behaviour, this fails and the
      # opt-out has to be reconsidered rather than silently breaking the page.
      for path <- @marketing_paths do
        html = html_response(get(conn, path), 200)

        refute html =~ ~r/phx-(click|submit|change|keyup|keydown|hook)=/,
               "#{path} uses a phx-* binding but ships no LiveView bundle"
      end
    end
  end

  describe "the homepage" do
    test "ships the LiveView bundle, because it is a LiveView", %{conn: conn} do
      html = html_response(get(conn, ~p"/"), 200)

      assert html =~ "/assets/js/app.js"
    end

    test "keeps the stylesheet, the inline theme script and the public shell",
         %{conn: conn} do
      html = html_response(get(conn, ~p"/"), 200)

      assert html =~ "/assets/css/app.css"
      assert html =~ "phx:theme"
      assert html =~ ~s(data-public-shell)
    end
  end

  describe "the website health check" do
    test "ships the LiveView bundle, because it is a LiveView", %{conn: conn} do
      html = html_response(get(conn, ~p"/tools/website-health-check"), 200)

      assert html =~ "/assets/js/app.js"
      assert html =~ ~s(phx-submit="check")
    end
  end

  describe "our own Measure snippet" do
    setup do
      previous = Application.get_env(:alplus, :measure_self_token)
      Application.put_env(:alplus, :measure_self_token, "self-token")

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:alplus, :measure_self_token)
        else
          Application.put_env(:alplus, :measure_self_token, previous)
        end
      end)
    end

    # The root layout used to key this off `:static_page`, which the homepage
    # LiveView cannot set (it needs the bundle). Both surfaces now set
    # `:marketing_page`, so this covers one of each.
    test "loads on the homepage LiveView and on a controller page", %{conn: conn} do
      for path <- ["/", "/pricing"] do
        html = html_response(get(conn, path), 200)

        assert html =~ ~s(src="/m.js?token=self-token"), "#{path} lost the Measure snippet"
      end
    end

    test "never loads inside the console", %{conn: conn} do
      user = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(user.id))
      project_fixture(owner_scope, org)

      html = conn |> log_in(user) |> get("/dashboard") |> html_response(200)

      refute html =~ "/m.js"
    end
  end

  describe "the console and auth screens" do
    test "an authenticated dashboard still loads the bundle", %{conn: conn} do
      user = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(user.id))
      project_fixture(owner_scope, org)

      html = conn |> log_in(user) |> get("/dashboard") |> html_response(200)

      assert html =~ "/assets/js/app.js"

      assert html =~
               ~s(<body class="bg-surface-page font-sans text-body text-text-primary antialiased">)
    end

    test "auth LiveViews still load the bundle", %{conn: conn} do
      for path <- ["/sign-in", "/register", "/reset"] do
        html = html_response(get(conn, path), 200)

        assert html =~ "/assets/js/app.js", "#{path} lost the LiveView bundle"
      end
    end
  end
end
