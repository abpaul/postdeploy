defmodule AlplusWeb.Plugs.CanonicalPathTest do
  @moduledoc """
  One page must be served from one URL (PRD §5).

  Before this plug, `/monitoring` and `/monitoring/` both returned 200 with
  the same content: two URLs for one page, splitting crawl budget and any
  accumulated links. `rel=canonical` is a hint that does not stop the
  duplicate being fetched.
  """

  use AlplusWeb.ConnCase, async: true

  alias AlplusWeb.Plugs.CanonicalPath

  setup do
    Alplus.Content.Seeds.run()
    :ok
  end

  describe "redirects duplicate URL variants" do
    test "a trailing slash redirects permanently to the bare path", %{conn: conn} do
      conn = get(conn, "/monitoring/")

      # 301, not 302: a temporary redirect leaves both URLs indexable.
      assert conn.status == 301
      assert redirected_to(conn, 301) == "/monitoring"
    end

    test "applies to nested content routes", %{conn: conn} do
      for path <- [
            "/pricing/",
            "/monitoring/cron-jobs/",
            "/guides/kubernetes-cronjob-heartbeat/",
            "/alternatives/cronitor/",
            "/privacy/"
          ] do
        conn = get(conn, path)

        assert conn.status == 301, "#{path} did not redirect"
        assert redirected_to(conn, 301) == String.trim_trailing(path, "/")
      end
    end

    test "preserves the query string, so campaign attribution survives", %{conn: conn} do
      conn = get(conn, "/monitoring/?utm_source=reddit&utm_medium=social")

      assert redirected_to(conn, 301) == "/monitoring?utm_source=reddit&utm_medium=social"
    end

    test "the redirect target itself serves a 200, so there is no chain", %{conn: conn} do
      target = conn |> get("/monitoring/") |> redirected_to(301)

      # A redirect that lands on another redirect wastes crawl budget and
      # loses signal at each hop.
      assert html_response(get(build_conn(), target), 200) =~ "<h1"
    end
  end

  describe "leaves canonical and non-marketing URLs alone" do
    test "the homepage is not redirected", %{conn: conn} do
      # `/` is the one path where a trailing slash is the canonical form.
      assert html_response(get(conn, "/"), 200) =~ "<h1"
    end

    test "an already-canonical path is served directly", %{conn: conn} do
      assert html_response(get(conn, "/monitoring"), 200) =~ "<h1"
    end

    test "ingest paths are never redirected", %{conn: conn} do
      # A cron job is not a browser following redirects. A surprise 301 here
      # would silently break a working heartbeat.
      conn = get(conn, "/h/hb_unknown/")

      refute conn.status == 301
    end
  end

  describe "canonical_path/1" do
    test "collapses trailing slashes and keeps the root" do
      assert CanonicalPath.canonical_path("/") == "/"
      assert CanonicalPath.canonical_path("/monitoring") == "/monitoring"
      assert CanonicalPath.canonical_path("/monitoring/") == "/monitoring"
      assert CanonicalPath.canonical_path("/a/b/") == "/a/b"
      # Degenerate input must resolve to the root rather than an empty path.
      assert CanonicalPath.canonical_path("///") == "/"
    end
  end
end
