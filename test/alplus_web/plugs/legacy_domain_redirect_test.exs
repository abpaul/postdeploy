defmodule AlplusWeb.Plugs.LegacyDomainRedirectTest do
  use ExUnit.Case, async: true

  alias AlplusWeb.Plugs.LegacyDomainRedirect

  test "redirects the old root host and preserves the path and query" do
    conn =
      Plug.Test.conn(:get, "https://alplus.dev/pricing?ref=foo")
      |> LegacyDomainRedirect.call([])

    assert conn.status == 301

    assert Plug.Conn.get_resp_header(conn, "location") ==
             ["https://postdeploy.dev/pricing?ref=foo"]
  end

  test "redirects the old ingest host to the new ingest host" do
    conn =
      Plug.Test.conn(:post, "https://ingest.alplus.dev/e/errors?source=sdk")
      |> LegacyDomainRedirect.call([])

    assert conn.status == 308

    assert Plug.Conn.get_resp_header(conn, "location") ==
             ["https://ingest.postdeploy.dev/e/errors?source=sdk"]
  end

  test "redirects alternate browser hosts to the canonical host" do
    for host <- ["www.postdeploy.dev", "aws.alplus.dev"] do
      conn =
        Plug.Test.conn(:get, "https://#{host}/pricing?ref=alternate-host")
        |> LegacyDomainRedirect.call([])

      assert conn.status == 301

      assert Plug.Conn.get_resp_header(conn, "location") ==
               ["https://postdeploy.dev/pricing?ref=alternate-host"]
    end
  end

  test "redirects ingest browser documents but leaves ingest API requests alone" do
    document_conn =
      Plug.Test.conn(:get, "https://ingest.postdeploy.dev/pricing?ref=browser")
      |> Plug.Conn.put_req_header("accept", "text/html,application/xhtml+xml")
      |> LegacyDomainRedirect.call([])

    assert document_conn.status == 301

    assert Plug.Conn.get_resp_header(document_conn, "location") ==
             ["https://postdeploy.dev/pricing?ref=browser"]

    api_conn =
      Plug.Test.conn(:post, "https://ingest.postdeploy.dev/e/errors")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> LegacyDomainRedirect.call([])

    refute api_conn.halted
    refute api_conn.status
  end

  test "does not redirect the canonical host" do
    conn =
      Plug.Test.conn(:get, "https://postdeploy.dev/pricing")
      |> LegacyDomainRedirect.call([])

    refute conn.halted
    refute conn.status
  end

  test "the endpoint runs the redirect before routing" do
    conn =
      Plug.Test.conn(:head, "https://www.alplus.dev/pricing?ref=endpoint")
      |> AlplusWeb.Endpoint.call([])

    assert conn.status == 301

    assert Plug.Conn.get_resp_header(conn, "location") ==
             ["https://postdeploy.dev/pricing?ref=endpoint"]
  end
end
