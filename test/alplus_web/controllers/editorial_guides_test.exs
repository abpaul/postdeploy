defmodule AlplusWeb.EditorialGuidesTest do
  use AlplusWeb.ConnCase, async: true

  alias Alplus.Content

  @paths [
    "/guides/backup-heartbeat",
    "/guides/why-analytics-tools-disagree",
    "/guides/investigate-errors-after-release",
    "/guides/ssl-certificate-expiry"
  ]

  setup do
    :ok = Content.Seeds.run()
    :ok
  end

  test "editorial guides render canonical TechArticle routes", %{conn: conn} do
    for path <- @paths do
      html = html_response(get(conn, path), 200)

      assert html =~ ~s(<link rel="canonical" href="https://postdeploy.dev#{path}")
      assert html =~ ~s("@type":"TechArticle")
    end
  end

  test "editorial guides appear on the guides index and sitemap", %{conn: conn} do
    index = html_response(get(conn, "/guides"), 200)
    sitemap = response(get(conn, "/sitemap.xml"), 200)

    for path <- @paths do
      assert index =~ ~s(href="#{path}")
      assert sitemap =~ "<loc>https://postdeploy.dev#{path}</loc>"
    end
  end

  test "editorial guide seeding remains idempotent" do
    :ok = Content.Seeds.run()
    {:ok, guides} = Content.list_guides()

    seeded_paths = guides |> Enum.map(& &1.path) |> Enum.filter(&(&1 in @paths))

    assert Enum.sort(seeded_paths) == Enum.sort(@paths)
  end
end
