defmodule AlplusWeb.ProductFactsControllerTest do
  use AlplusWeb.ConnCase, async: true

  alias AlplusWeb.Marketing.ProductFacts

  test "serves the public product facts contract without authentication" do
    conn = get(build_conn(), "/product-facts.json")

    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    assert get_resp_header(conn, "set-cookie") == []
    assert json_response(conn, 200) == ProductFacts.facts()
  end
end
