defmodule Alplus.PublicTokenTest do
  use ExUnit.Case, async: true

  test "generates a 16-character Base62 token" do
    token = Alplus.PublicToken.generate()

    assert String.length(token) == 16
    assert token =~ ~r/\A[0-9A-Za-z]{16}\z/
  end
end
