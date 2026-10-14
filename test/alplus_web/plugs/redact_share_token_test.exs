defmodule AlplusWeb.Plugs.RedactShareTokenTest do
  use ExUnit.Case, async: true

  import Plug.Test

  test "redacts the route bearer while preserving its parsed parameter" do
    token = "shr_public_bearer"

    conn =
      :get
      |> conn("/share/#{token}?window=24h")
      |> Map.put(:path_params, %{"token" => token})
      |> AlplusWeb.Plugs.RedactShareToken.call([])

    assert conn.path_params["token"] == token
    assert conn.request_path == "/share/[FILTERED]"
    assert conn.query_string == "window=24h"
  end
end
