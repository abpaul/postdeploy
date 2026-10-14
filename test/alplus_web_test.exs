defmodule AlplusWebTest do
  use ExUnit.Case, async: true

  test "quoted helpers and static paths" do
    assert is_list(AlplusWeb.static_paths())
    assert is_tuple(AlplusWeb.router())
    assert is_tuple(AlplusWeb.channel())
    assert is_tuple(AlplusWeb.controller())
    assert is_tuple(AlplusWeb.live_view())
    assert is_tuple(AlplusWeb.live_component())
    assert is_tuple(AlplusWeb.html())
    assert is_tuple(AlplusWeb.verified_routes())
  end
end
