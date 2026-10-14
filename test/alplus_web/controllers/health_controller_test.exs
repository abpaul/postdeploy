defmodule AlplusWeb.HealthControllerTest do
  use AlplusWeb.ConnCase, async: true

  test "GET /health verifies the application and database", %{conn: conn} do
    conn = get(conn, "/health")

    assert response(conn, 200) == "ok"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end
end
