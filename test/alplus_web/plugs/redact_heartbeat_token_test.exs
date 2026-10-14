defmodule AlplusWeb.Plugs.RedactHeartbeatTokenTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias AlplusWeb.Plugs.RedactHeartbeatToken

  test "redacts the heartbeat bearer while preserving the route segments" do
    token = "hb_private_bearer"

    conn =
      :get
      |> conn("/h/#{token}/1?state=fail")
      |> RedactHeartbeatToken.call([])

    assert conn.path_info == ["h", token, "1"]
    assert conn.request_path == "/h/[FILTERED]/1"
    assert conn.query_string == "state=fail"
  end
end
