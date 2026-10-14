defmodule AlplusWeb.FormatTest do
  use ExUnit.Case, async: true

  alias AlplusWeb.Format

  test "format_utc/1 prints minute precision in UTC" do
    assert Format.format_utc(~U[2026-01-02 03:04:05Z]) == "2026-01-02 03:04 UTC"
  end

  test "format_utc_seconds/1 prints second precision in UTC" do
    assert Format.format_utc_seconds(~U[2026-01-02 03:04:05Z]) == "2026-01-02 03:04:05 UTC"
  end

  test "format_utc_seconds/1 reports a missing timestamp" do
    assert Format.format_utc_seconds(nil) == "Unavailable"
  end
end
