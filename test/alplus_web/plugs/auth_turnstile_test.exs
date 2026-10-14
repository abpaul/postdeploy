defmodule AlplusWeb.Plugs.AuthTurnstileTest do
  use AlplusWeb.ConnCase, async: true

  alias AlplusWeb.Plugs.AuthTurnstile
  alias Alplus.Turnstile.Client

  test "rejects sign-in without a valid token, including a trailing slash", %{conn: conn} do
    Req.Test.stub(Client, fn request -> Req.Test.json(request, %{"success" => false}) end)

    conn =
      conn
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Plug.Conn.put_private(:phoenix_recycled, true)
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Plug.Conn.assign(:flash, %{})

    conn = Plug.Test.init_test_session(conn, %{})
    conn = Phoenix.Controller.fetch_flash(conn, [])
    conn = Plug.Conn.fetch_query_params(conn)
    conn = %{conn | method: "POST", path_info: ["auth", "user", "password", "sign_in", ""]}

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Phoenix.Controller.fetch_flash([])
      |> AuthTurnstile.call([])

    assert conn.halted
    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/sign-in"]
  end

  test "rejects a malformed user parameter without raising", %{conn: conn} do
    Req.Test.stub(Client, fn _request ->
      flunk("malformed user parameters must not reach Cloudflare")
    end)

    conn = %{
      conn
      | method: "POST",
        path_info: ["auth", "user", "password", "sign_in"],
        params: %{"user" => "invalid"}
    }

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Phoenix.Controller.fetch_flash([])
      |> AuthTurnstile.call([])

    assert conn.halted
    assert conn.status == 302
  end
end
