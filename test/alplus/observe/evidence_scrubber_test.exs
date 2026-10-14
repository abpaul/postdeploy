defmodule Alplus.Observe.EvidenceScrubberTest do
  use ExUnit.Case, async: true

  alias Alplus.Observe.EvidenceScrubber

  test "redacts sensitive keys at any nesting depth" do
    input = %{
      "authorization" => "Bearer abc",
      "Cookie" => "session=1",
      "password" => "hunter2",
      "api_key" => "sk_live_x",
      "api-key" => "sk_live_y",
      "user_email" => "person@example.com",
      "nested" => %{
        "secret" => "shh",
        "deeper" => %{"token" => "tok"}
      },
      "list" => [%{"password" => "in-a-list"}]
    }

    scrubbed = EvidenceScrubber.scrub(input)

    assert scrubbed["authorization"] == "[REDACTED]"
    assert scrubbed["Cookie"] == "[REDACTED]"
    assert scrubbed["password"] == "[REDACTED]"
    assert scrubbed["api_key"] == "[REDACTED]"
    assert scrubbed["api-key"] == "[REDACTED]"
    assert scrubbed["user_email"] == "[REDACTED]"
    assert scrubbed["nested"]["secret"] == "[REDACTED]"
    assert scrubbed["nested"]["deeper"]["token"] == "[REDACTED]"
    assert [%{"password" => "[REDACTED]"}] = scrubbed["list"]
  end

  test "preserves ordinary keys unchanged" do
    input = %{"method" => "GET", "status_code" => 200, "path" => "/checkout"}

    assert EvidenceScrubber.scrub(input) == input
  end

  test "truncates past the max nesting depth" do
    deeply_nested =
      Enum.reduce(1..8, "leaf", fn _, acc -> %{"level" => acc} end)

    scrubbed = EvidenceScrubber.scrub(deeply_nested)

    assert scrubbed["level"]["level"]["level"]["level"]["level"]["level"] == "[TRUNCATED]"
  end

  test "bounds list length, string length, and map size" do
    long_string = String.duplicate("a", 3_000)
    long_list = Enum.to_list(1..150)
    big_map = Map.new(1..150, fn i -> {"key#{i}", i} end)

    assert String.length(EvidenceScrubber.scrub(long_string)) == 2_000
    assert length(EvidenceScrubber.scrub(long_list)) == 100
    assert map_size(EvidenceScrubber.scrub(big_map)) == 100
  end

  test "passes non-string, non-map, non-list values through" do
    assert EvidenceScrubber.scrub(42) == 42
    assert EvidenceScrubber.scrub(true) == true
    assert EvidenceScrubber.scrub(nil) == nil
  end
end
