defmodule Alplus.Measure.OriginAllowlistTest do
  use ExUnit.Case, async: true

  alias Alplus.Measure.OriginAllowlist

  test "normalizes exact and wildcard hostnames but rejects a broad wildcard" do
    assert {:ok, "*.example.com"} = OriginAllowlist.normalize(" HTTPS://*.Example.com/path ")
    assert {:error, :invalid_hostname} = OriginAllowlist.normalize("*")
  end

  test "wildcards match subdomains but not the apex or lookalikes" do
    domains = ["*.example.com"]
    assert OriginAllowlist.allowed?("app.example.com", domains)
    refute OriginAllowlist.allowed?("example.com", domains)
    refute OriginAllowlist.allowed?("notexample.com", domains)
  end
end
