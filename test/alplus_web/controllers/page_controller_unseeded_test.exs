defmodule AlplusWeb.PageControllerUnseededTest do
  @moduledoc """
  `AlplusWeb.PageController` on a database with no `Alplus.Content` rows —
  the state of a fresh clone migrated with `mix ecto.migrate` but never
  `priv/repo/seeds.exs` (BUILD.md §7). Every route here used to hit a hard
  `{:ok, page} = Content.get_page_by_path(...)` match and 500.

  Deliberately does not call `Alplus.Content.Seeds.run/0` in setup, unlike
  `AlplusWeb.PageControllerTest`.
  """

  use AlplusWeb.ConnCase, async: true

  describe "content-backed routes without seeded content" do
    test "GET / returns 200 with the built-in fallback home, never 500", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)
      assert html =~ "PostDeploy"
      assert html =~ ~s(href="/register")
    end

    test "GET /pricing returns a clean 404, never 500", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, ~p"/pricing") end
    end

    test "GET /free-uptime-monitoring returns a clean 404, never 500", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, ~p"/free-uptime-monitoring") end
    end

    test "GET /alternatives returns a clean 404, never 500", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, ~p"/alternatives") end
    end

    test "GET /alternatives/:slug returns a clean 404, never 500", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, ~p"/alternatives/cronitor") end
    end
  end
end
