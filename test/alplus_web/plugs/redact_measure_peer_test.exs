defmodule AlplusWeb.Plugs.RedactMeasurePeerTest do
  use ExUnit.Case, async: true

  import Plug.Test

  test "clears remote_ip logger metadata and leaves conn.remote_ip for hashing" do
    Logger.metadata(remote_ip: {1, 2, 3, 4})

    conn =
      :post
      |> conn("/m")
      |> Map.put(:remote_ip, {203, 0, 113, 99})
      |> AlplusWeb.Plugs.RedactMeasurePeer.call([])

    assert conn.remote_ip == {203, 0, 113, 99}
    assert Logger.metadata()[:remote_ip] == nil
  end
end
