defmodule AlplusWeb.Plugs.ParseBodyTest do
  use ExUnit.Case, async: true

  alias AlplusWeb.Plugs.ParseBody

  test "skips parsing on the MCP route before bearer authentication" do
    conn =
      :get
      |> Plug.Test.conn("/mcp", ~s({"value":))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    opts = ParseBody.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason)
    conn = ParseBody.call(conn, opts)

    assert %Plug.Conn.Unfetched{aspect: :body_params} = conn.body_params
    refute conn.halted
  end
end
