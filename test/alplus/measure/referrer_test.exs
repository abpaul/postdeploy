defmodule Alplus.Measure.ReferrerTest do
  use ExUnit.Case, async: true

  alias Alplus.Measure.Referrer

  test "returns the referrer's host only, never the full URL" do
    assert Referrer.host("https://google.com/search?q=al+plus", ["app.example.test"]) ==
             "google.com"
  end

  test "accepts the minimized hostname or direct marker sent by the tracker" do
    assert Referrer.host("google.com", ["app.example.test"]) == "google.com"
    assert Referrer.host("app.example.test", ["app.example.test"]) == "direct"
    assert Referrer.host("direct", ["app.example.test"]) == "direct"
  end

  test "a missing referrer is direct" do
    assert Referrer.host(nil, ["app.example.test"]) == "direct"
  end

  test "a referrer on one of the project's allow-listed domains is direct" do
    assert Referrer.host("https://app.example.test/pricing", ["app.example.test"]) == "direct"
  end

  test "a referrer matching a wildcard-allow-listed domain is direct" do
    assert Referrer.host("https://blog.example.test/post", ["*.example.test"]) == "direct"
  end

  test "a referrer host not in the allowlist is external, even if it looks related" do
    # No public-suffix-list comparison: only an explicit allowlist entry
    # counts as "this site" now, matching origin auth exactly.
    assert Referrer.host("https://other.example.test/", ["app.example.test"]) ==
             "other.example.test"
  end

  test "an empty allowlist means every referrer is external" do
    assert Referrer.host("https://app.example.test/", []) == "app.example.test"
  end

  test "an unparsable referrer falls back to direct rather than raising" do
    assert Referrer.host("not a url", ["app.example.test"]) == "direct"
    assert Referrer.host("", ["app.example.test"]) == "direct"
  end
end
