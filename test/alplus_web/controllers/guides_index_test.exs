defmodule AlplusWeb.GuidesIndexTest do
  @moduledoc """
  `/guides` (SITE-ARCHITECTURE.md §6, issue #50): the index that fixes the
  orphaned heartbeat guides. `Alplus.Seo.AuditTest` already enforces the
  shared SEO standard across every public route; these tests cover what is
  specific to this page: every published guide is read from the content
  store (never a hardcoded list), each shows its own platform failure mode,
  the required outbound links are present, and breadcrumbs route through
  the index instead of the old `/monitoring` workaround.
  """

  use AlplusWeb.ConnCase, async: true

  alias Alplus.Content

  setup do
    :ok = Content.Seeds.run()
    :ok
  end

  test "every seeded guide appears with its own failure-mode line", %{conn: conn} do
    html = html_response(get(conn, ~p"/guides"), 200)

    {:ok, github_actions} = Content.get_guide_by_path("/guides/github-actions-heartbeat")
    {:ok, kubernetes} = Content.get_guide_by_path("/guides/kubernetes-cronjob-heartbeat")

    assert html =~ github_actions.hero_heading
    assert html =~ github_actions.summary
    assert html =~ kubernetes.hero_heading
    assert html =~ kubernetes.summary
    assert html =~ ~s(href="/guides/github-actions-heartbeat")
    assert html =~ ~s(href="/guides/kubernetes-cronjob-heartbeat")
  end

  test "guide list schema follows the visible topic order", %{conn: conn} do
    document = conn |> get(~p"/guides") |> html_response(200) |> LazyHTML.from_document()

    visible_paths =
      document
      |> LazyHTML.query("section[id^='guides-'] ul a[href^='/guides/']")
      |> Enum.map(&(LazyHTML.attribute(&1, "href") |> List.first()))

    list_schema =
      document
      |> LazyHTML.query("script[type='application/ld+json']")
      |> Enum.map(&(&1 |> LazyHTML.text() |> Jason.decode!()))
      |> Enum.find(&(&1["@type"] == "ItemList"))

    assert Enum.map(list_schema["itemListElement"], &URI.parse(&1["url"]).path) == visible_paths
  end

  test "adding a guide row makes it appear on the index with no template change", %{conn: conn} do
    {:ok, _new_guide} =
      Content.create_guide(
        %{
          slug: "test-platform-heartbeat",
          path: "/guides/test-platform-heartbeat",
          title: "Monitor a Test Platform scheduled job | PostDeploy",
          meta_description:
            "Test Platform stops scheduled jobs silently. Here is how to detect it with a heartbeat.",
          nav_label: "Test Platform heartbeat",
          summary: "Test Platform silently retires a schedule after too many missed runs.",
          hero_badge: "Guide",
          hero_heading: "Monitor a Test Platform scheduled job",
          hero_description: "A heartbeat catches the silent failure.",
          lastmod: ~D[2026-08-19],
          status: "published",
          cluster: "cron",
          intent: "informational",
          primary_query: "test platform scheduled job not running"
        },
        authorize?: false
      )

    html = html_response(get(conn, ~p"/guides"), 200)

    assert html =~ "Monitor a Test Platform scheduled job"
    assert html =~ "Test Platform silently retires a schedule after too many missed runs."
    assert html =~ ~s(href="/guides/test-platform-heartbeat")
  end

  test "the index links cron job monitoring, free cron job monitoring and pricing", %{
    conn: conn
  } do
    html = html_response(get(conn, ~p"/guides"), 200)

    assert html =~ ~s(href="/monitoring/cron-jobs")
    assert html =~ ~s(href="/free-cron-job-monitoring")
    assert html =~ ~s(href="/pricing")
    assert html =~ ~s(href="/register")
    assert html =~ "Start your 14-day free trial"
  end

  test "renders the Home > Guides breadcrumb with BreadcrumbList JSON-LD", %{conn: conn} do
    html = html_response(get(conn, ~p"/guides"), 200)

    assert html =~ ~s("@type":"BreadcrumbList")
    assert html =~ ~s("name":"Guides")
    assert html =~ ~s("item":"https://postdeploy.dev/guides")
  end

  test "guide breadcrumbs render Home > Guides > guide title, not through /monitoring", %{
    conn: conn
  } do
    html = html_response(get(conn, ~p"/guides/github-actions-heartbeat"), 200)

    assert html =~ ~s("@type":"BreadcrumbList")
    assert html =~ ~s("name":"Guides")
    assert html =~ ~s("item":"https://postdeploy.dev/guides")
    assert html =~ ~s("name":"GitHub Actions heartbeat")
    refute html =~ ~s("name":"Monitoring")
    assert html =~ ~s(id="guide-breadcrumbs")
    assert html =~ ~s(aria-label="Breadcrumb")
    assert html =~ ~s(href="/")
    assert html =~ ~s(href="/guides")
    assert html =~ ~s(aria-current="page")
  end

  test "guide breadcrumb trails match the requested route in DOM and JSON-LD", %{conn: conn} do
    paths = [
      {"/monitoring", [{"Home", "/"}]},
      {"/error-tracking", [{"Home", "/"}]},
      {"/analytics", [{"Home", "/"}]},
      {"/about", [{"Home", "/"}]},
      {"/terms", [{"Home", "/"}]},
      {"/monitoring/uptime", [{"Home", "/"}, {"Monitoring", "/monitoring"}]},
      {"/guides/github-actions-heartbeat", [{"Home", "/"}, {"Guides", "/guides"}]}
    ]

    for {path, parent_paths} <- paths do
      {:ok, guide} = Content.get_guide_by_path(path)
      html = html_response(get(conn, path), 200)
      document = LazyHTML.from_document(html)
      breadcrumbs = LazyHTML.query(document, "#guide-breadcrumbs")

      assert breadcrumbs |> LazyHTML.query("[aria-current='page']") |> LazyHTML.text() ==
               guide.nav_label

      assert breadcrumbs
             |> LazyHTML.query("a")
             |> Enum.map(fn link ->
               {LazyHTML.text(link) |> String.trim(),
                LazyHTML.attribute(link, "href") |> List.first()}
             end) ==
               parent_paths

      graphs =
        document
        |> LazyHTML.query("script[type='application/ld+json']")
        |> Enum.map(&LazyHTML.text/1)
        |> Enum.map(&Jason.decode!/1)

      breadcrumb_graph = Enum.find(graphs, &(&1["@type"] == "BreadcrumbList"))
      assert breadcrumb_graph

      expected_trail = parent_paths ++ [{guide.nav_label, path}]

      assert Enum.map(breadcrumb_graph["itemListElement"], & &1["name"]) ==
               Enum.map(expected_trail, &elem(&1, 0))

      assert Enum.map(breadcrumb_graph["itemListElement"], & &1["item"]) ==
               Enum.map(expected_trail, &("https://postdeploy.dev" <> elem(&1, 1)))
    end
  end

  test "is listed in the sitemap with the production canonical", %{conn: conn} do
    xml = conn |> get(~p"/sitemap.xml") |> response(200)

    assert xml =~ "https://postdeploy.dev/guides</loc>"
  end

  test "emits a canonical URL pinned to the production origin", %{conn: conn} do
    html = html_response(get(conn, ~p"/guides"), 200)

    assert html =~ ~s(<link rel="canonical" href="https://postdeploy.dev/guides")
  end

  test "avoids the banned marketing wording", %{conn: conn} do
    html = html_response(get(conn, ~p"/guides"), 200)

    banned = [
      ~r/\bobservability platform\b/,
      ~r/\bAPM\b/,
      ~r/\bfull-stack\b/,
      ~r/\benterprise-grade\b/,
      ~r/\bworld-class\b/,
      ~r/\bglobal network\b/,
      ~r/\bedge\b/,
      ~r/\bunlimited\b/,
      ~r/\boverage\b/,
      ~r/\bgoal conversions\b/,
      ~r/\bSLA\b/,
      ~r/\bactually\b/,
      ~r/\breally\b/,
      ~r/\bvery\b/
    ]

    for pattern <- banned do
      refute html =~ pattern, "found banned wording: #{inspect(pattern)}"
    end
  end
end
