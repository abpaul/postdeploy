defmodule AlplusWeb.SiteVerificationTest do
  @moduledoc """
  Search Console and Bing verification meta tags.

  Rendered only when configured: an empty verification tag fails
  verification more confusingly than a missing one.
  """

  use AlplusWeb.ConnCase, async: false

  setup do
    Alplus.Content.Seeds.run()

    on_exit(fn ->
      Application.delete_env(:alplus, :google_site_verification)
      Application.delete_env(:alplus, :bing_site_verification)
    end)

    :ok
  end

  test "no verification tag is rendered when unconfigured", %{conn: conn} do
    Application.delete_env(:alplus, :google_site_verification)
    Application.delete_env(:alplus, :bing_site_verification)

    html = html_response(get(conn, ~p"/"), 200)

    refute html =~ "google-site-verification"
    refute html =~ "msvalidate.01"
  end

  test "renders each verification tag when configured", %{conn: conn} do
    Application.put_env(:alplus, :google_site_verification, "google-token-abc")
    Application.put_env(:alplus, :bing_site_verification, "bing-token-xyz")

    html = html_response(get(conn, ~p"/"), 200)

    assert html =~ ~s(<meta name="google-site-verification" content="google-token-abc")
    assert html =~ ~s(<meta name="msvalidate.01" content="bing-token-xyz")
  end

  test "always renders the Orynth verification tag", %{conn: conn} do
    html = html_response(get(conn, ~p"/"), 200)

    assert html =~ ~s(<meta name="ory-verify" content="orynth-a27e4df5908a4f06b3ec567fd193d84a")
  end
end
