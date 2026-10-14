defmodule AlplusWeb.EndpointHostTest do
  @moduledoc """
  Marketing URLs and the Measure beacon must use the production hostname.

  `Seo.origin/0` produces canonicals, `og:url` and the sitemap. The served
  `m.js` must post to whichever host served it.
  """

  use AlplusWeb.ConnCase, async: true

  alias Alplus.Content.Seeds

  setup do
    :ok = Seeds.run()
    :ok
  end

  test "canonical URLs use the production origin" do
    assert AlplusWeb.Marketing.Seo.origin() == "https://postdeploy.dev"
  end

  test "the sitemap advertises production URLs", %{conn: conn} do
    body = conn |> get("/sitemap.xml") |> response(200)

    assert body =~ "<loc>https://postdeploy.dev/"
  end

  test "a canonical link points at the production origin", %{conn: conn} do
    body = conn |> get("/pricing") |> html_response(200)

    assert body =~ ~s|rel="canonical" href="https://postdeploy.dev/pricing"|
  end

  test "the served beacon derives its endpoint from its own script origin", %{conn: conn} do
    js = conn |> get("/m.js") |> response(200)

    # A relative path would post to the host page's origin, not ours.
    assert js =~ "currentScript"
    assert js =~ "new URL(C.src).origin"
  end
end
