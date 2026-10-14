defmodule AlplusWeb.NotFoundPageTest do
  @moduledoc """
  The 404 page (PRD §36).

  A 404 has two jobs: return the right status so search engines drop the
  URL, and give a lost visitor somewhere to go. A soft 404 (a 200 that says
  "not found") is the failure mode worth guarding against, because it keeps
  a dead URL in the index indefinitely.
  """

  use AlplusWeb.ConnCase, async: true

  setup do
    Alplus.Content.Seeds.run()
    :ok
  end

  test "an unknown path returns a real 404 status, not a soft 404", %{conn: conn} do
    # `AlplusWeb.NotFoundError` is rendered by the error handler, so the
    # response is a genuine 404 rather than an exception escaping. A soft
    # 404 (200 with "not found" text) would keep the URL in the index.
    conn = get(conn, "/no-such-page")

    assert conn.status == 404
    assert conn.resp_body =~ "This page took a detour"
  end

  describe "the rendered 404 body" do
    setup %{conn: conn} do
      # `assert_error_sent` gives the status but discards the body, so
      # render the template directly to inspect what a visitor sees.
      html =
        Phoenix.Template.render_to_string(AlplusWeb.ErrorHTML, "404", "html",
          conn: conn,
          csp_nonce: "test-nonce"
        )

      %{html: html}
    end

    test "is noindex, so a dead URL leaves the index", %{html: html} do
      assert html =~ ~s(<meta name="robots" content="noindex")
    end

    test "offers a route onward rather than a dead end", %{html: html} do
      assert html =~ ~s(href="/")
      assert html =~ ~s(href="/pricing")
      assert html =~ ~s(href="/docs")
    end

    test "explains what happened in plain language", %{html: html} do
      assert html =~ "This page took a detour"
      assert html =~ "The link may be broken"
    end

    test "meets the same accessibility bar as every other page", %{html: html} do
      # The 404 is rendered outside the normal layout, so the audit's
      # route-based checks never see it. These mirror them. The `lang`
      # attribute is matched loosely because LiveView injects `phx-r` into
      # the same tag.
      assert html =~ ~r/<html[^>]*\slang="en"/
      assert html =~ "<main"
      assert html =~ ~s(aria-label=)
      refute html =~ ~r/<h[23456][\s>]/
    end
  end

  test "every navigation link on the 404 page actually resolves", %{conn: conn} do
    # A 404 that links to another 404 is worse than no links at all.
    for {_label, path} <- AlplusWeb.MarketingComponents.header_links() do
      assert conn |> get(path) |> html_response(200)
    end
  end
end
