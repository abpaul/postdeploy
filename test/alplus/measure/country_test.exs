defmodule Alplus.Measure.CountryTest do
  use ExUnit.Case, async: true

  alias Alplus.Measure.Country

  test "normalizes a valid two-letter code, upcased" do
    assert Country.normalize("us") == "US"
    assert Country.normalize("DE") == "DE"
  end

  test "an absent header has no country dimension" do
    assert Country.normalize(nil) == nil
  end

  test "Cloudflare's unresolvable and Tor markers are not fabricated as countries" do
    assert Country.normalize("XX") == nil
    assert Country.normalize("T1") == nil
  end

  test "a malformed value has no country dimension" do
    assert Country.normalize("United States") == nil
    assert Country.normalize("1.2.3.4") == nil
  end
end
